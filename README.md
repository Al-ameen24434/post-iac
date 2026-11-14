# iac-master

Infrastructure-as-Code (IaC) for a self-service **DevOps jumphost** on AWS, provisioned with **Terraform** and deployed automatically through a **GitHub Actions** pipeline.

The stack builds a single, internet-facing EC2 instance inside a dedicated VPC and bootstraps it with the tooling needed to run a CI/CD and observability platform: Docker, kubectl, eksctl, Terraform, Helm, Trivy and the AWS CLI. Because the instance is exposed with Jenkins (8080), SonarQube (9000), Prometheus (9090) and HTTP (80) ports open, it doubles as a lightweight application host for a DevOps demo environment.

---

## Table of contents

- [Architecture](#architecture)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
  - [1. Configure the Terraform backend](#1-configure-the-terraform-backend)
  - [2. Configure GitHub Actions secrets](#2-configure-github-actions-secrets)
  - [3. Deploy with the CI/CD pipeline](#3-deploy-with-the-cicd-pipeline)
  - [4. Deploy locally (optional)](#4-deploy-locally-optional)
- [Configuration reference](#configuration-reference)
- [Outputs](#outputs)
- [Provisioned resources](#provisioned-resources)
- [Post-deployment: bootstrap tools](#post-deployment-bootstrap-tools)
- [How the pipeline works](#how-the-pipeline-works)
- [Tearing everything down](#tearing-everything-down)
- [Security considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Cost notes](#cost-notes)

---

## Architecture

```
                                GitHub Repository
                                        |
                                        |  push / PR to main (paths: terraform/**)
                                        v
                          +---------------------------------+
                          |      GitHub Actions Runner      |
                          |  init -> fmt -> validate ->     |
                          |  plan -> apply (main only)      |
                          +---------------------------------+
                                        |
                          remote state  |  AWS credentials
                                        v
        ┌─────────────────────────────────────────────────────────────┐
        │                        AWS (us-east-1)                      │
        │                                                             │
        │   ┌──────────────────────── VPC 10.0.0.0/16 ──────────────┐ │
        │   │                                                       │ │
        │   │   ┌─────────────── Public Subnet 10.0.1.0/24 ───────┐ │ │
        │   │   │              (us-east-1a, auto public IP)       │ │ │
        │   │   │                                                 │ │ │
        │   │   │   ┌──────────────────────────────────────────┐  │ │ │
        │   │   │   │   EC2 jumphost (t3.micro, 30 GB root)    │  │ │ │
        │   │   │   │   user_data: install-tools.sh            │  │ │ │
        │   │   │   │   - Docker, kubectl, eksctl, Terraform   │  │ │ │
        │   │   │   │   - Helm, Trivy, AWS CLI v2              │  │ │ │
        │   │   │   └──────────────────────────────────────────┘  │ │ │
        │   │   │                                                 │ │ │
        │   │   └─────────────────────────────────────────────────┘ │ │
        │   │                                                       │ │
        │   │   Internet Gateway ◄── Route Table (0.0.0.0/0 → IGW)  │ │
        │   └───────────────────────────────────────────────────────┘ │
        │                                                             │
        │   Security Group: inbound 22, 80, 8080, 9000, 9090         │
        │   IAM Role + Instance Profile: AdministratorAccess ⚠        │
        │                                                             │
        │   S3 bucket: remote Terraform state                        │
        └─────────────────────────────────────────────────────────────┘
```

**Design decisions**

| Decision | Rationale |
|---|---|
| Single public subnet + IGW | The jumphost must be reachable over the internet for SSH and web UIs; no NAT gateway keeps cost low. |
| `map_public_ip_on_launch = true` | Guarantees a public IPv4 without an extra EIP resource. |
| Security group uses a `for` expression | Keeps the five allowed ports declarative and easy to extend. |
| S3 backend for state | Enables remote state sharing and drift detection across a team; the bucket name is overridden at `init` time by CI. |
| `user_data_replace_on_change = true` | Forces instance replacement when the bootstrap script changes, so tool upgrades actually take effect. |
| `-parallelism=1` on apply | Serialises resource creation to avoid rate-limit races on a fresh account. |

---

## Repository structure

```
iac-master/
├── README.md                          # This file
├── .github/
│   └── workflows/
│       └── terraform.yml              # CI/CD pipeline: fmt, validate, plan, apply
└── terraform/
    ├── terraform.tf                   # Required providers, S3 backend, version constraints
    ├── variables.tf                   # All input variables and defaults
    ├── outputs.tf                     # Region and jumphost public IP
    ├── vpc.tf                         # VPC, IGW, subnet, route table, security group
    ├── jumphost.tf                    # EC2 instance + user_data bootstrap
    ├── iam-role.tf                    # IAM role assumable by EC2
    ├── iam-policy.tf                  # Policy attachment (AdministratorAccess - see security notes)
    ├── iam-instance-profile.tf        # Instance profile attaching the role to the instance
    ├── install-tools.sh               # User-data script that installs the DevOps toolchain
    ├── .gitignore                     # Excludes .terraform/ working directory
    └── .terraform.lock.hcl            # Provider version lockfile (commit this)
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.6.3 | Local plan/apply (optional — CI provides its own) |
| AWS account | — | Target cloud account |
| AWS CLI | v2 | Optional, for local credential setup |
| An EC2 key pair | — | Must exist in `us-east-1` for SSH access |
| GitHub repository | — | For the Actions pipeline and secrets |

**Required AWS permissions** for whoever runs Terraform (human or CI role):
`ec2:*`, `vpc:*`, `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:CreateInstanceProfile`, `iam:PassRole`, `s3:*` on the state bucket.

---

## Quick start

### 1. Configure the Terraform backend

The backend is declared in `terraform/terraform.tf`:

```hcl
backend "s3" {
  bucket = "ts-acad-state-file"
  key    = "terraform.tfstate"
  region = "us-east-1"
}
```

Create the bucket once (state buckets should have versioning and server-side encryption enabled):

```bash
aws s3api create-bucket \
  --bucket ts-acad-state-file \
  --region us-east-1 \
  --create-bucket-configuration LocationConstraint=us-east-1

aws s3api put-bucket-versioning \
  --bucket ts-acad-state-file \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket ts-acad-state-file \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

> The pipeline overrides this bucket name via `terraform init -backend-config "bucket=$BUCKET_TF_STATE"`, so you can point CI at a different state bucket without editing code.

### 2. Configure GitHub Actions secrets

Repository → **Settings → Secrets and variables → Actions**, add:

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user/access key with permissions listed in [Prerequisites](#prerequisites) |
| `AWS_SECRET_ACCESS_KEY` | Matching secret key |
| `BUCKET_TF` | Name of the S3 bucket holding Terraform state (e.g. `ts-acad-state-file`) |

> Use a dedicated CI IAM user with a scoped policy — not a root account key.

### 3. Deploy with the CI/CD pipeline

```bash
git checkout main
git add terraform/
git commit -m "feat: provision jumphost stack"
git push origin main
```

Watch the run under the **Actions** tab. On a successful apply, grab the public IP from the job log (or run `terraform output` locally after a `terraform init` + `refresh`).

### 4. Deploy locally (optional)

```bash
cd terraform

terraform init
terraform fmt -check
terraform validate
terraform plan  -out planfile
terraform apply planfile

# Retrieve the address
terraform output -raw jumphost_public_ip
```

---

## Configuration reference

All variables are defined in [`terraform/variables.tf`](terraform/variables.tf). Override any of them on the command line with `-var='name=value'` or in a `terraform.tfvars` file.

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | `string` | `us-east-1` | AWS region deployed into. |
| `vpc-name` | `string` | `Jumphost-vpc` | Name tag for the VPC. |
| `igw-name` | `string` | `Jumphost-igw` | Name tag for the internet gateway. |
| `subnet-name` | `string` | `Jumphost-subnet` | Name tag for the public subnet. |
| `rt-name` | `string` | `Jumphost-rt` | Name tag for the route table. |
| `sg-name` | `string` | `Jumphost-sg` | Name tag for the security group. |
| `iam-role` | `string` | `Jumphost-iam-role` | Name of the IAM role for the instance. |
| `ami_id` | `string` | `ami-0547ecbf0e9b4aeb5` | AMI ID — **must be an Ubuntu image valid for your region**, or the `ubuntu` user referenced in `install-tools.sh` will not exist. |
| `instance_type` | `string` | `t3.micro` | EC2 instance size. |
| `key_name` | `string` | `aws-samp-key` | Name of an existing EC2 key pair in the region. |
| `instance_name` | `string` | `Jumphost-server` | Name tag for the EC2 instance. |

**Hard-coded values you may want to change** (edit the resource files directly):

| Value | Location | Current |
|---|---|---|
| VPC CIDR | `vpc.tf` | `10.0.0.0/16` |
| Subnet CIDR | `vpc.tf` | `10.0.1.0/24` |
| Availability zone | `vpc.tf` | `us-east-1a` |
| Open ingress ports | `vpc.tf` | `22, 8080, 9000, 9090, 80` |
| Root volume size | `jumphost.tf` | `30` GB |
| State bucket / key | `terraform.tf` | `ts-acad-state-file` / `terraform.tfstate` |

---

## Outputs

Defined in [`terraform/outputs.tf`](terraform/outputs.tf):

| Output | Description |
|---|---|
| `region` | The AWS region the stack was deployed to. |
| `jumphost_public_ip` | Public IPv4 address of the jumphost — use this for SSH and web UIs. |

```bash
terraform output -raw jumphost_public_ip
```

---

## Provisioned resources

| Resource | Type | Notes |
|---|---|---|
| `aws_vpc.vpc` | VPC | `10.0.0.0/16`, tagged from `vpc-name`. |
| `aws_internet_gateway.igw` | Internet gateway | Enables outbound/inbound internet access. |
| `aws_subnet.public-subnet` | Public subnet | `10.0.1.0/24` in `us-east-1a`, auto-assign public IP. |
| `aws_route_table.rt` | Route table | Default route `0.0.0.0/0 → IGW`. |
| `aws_route_table_association.rt-association` | Association | Binds the route table to the subnet. |
| `aws_security_group.security-group` | Security group | Ingress TCP `22, 8080, 9000, 9090, 80` from `0.0.0.0/0`; unrestricted egress. |
| `aws_instance.ec2` | EC2 instance | `t3.micro`, 30 GB root volume, bootstrapped via `install-tools.sh`. |
| `aws_iam_role.iam-role` | IAM role | Trust policy allows `ec2.amazonaws.com`. |
| `aws_iam_role_policy_attachment.iam-policy` | Attachment | Attaches `AdministratorAccess` — see [Security considerations](#security-considerations). |
| `aws_iam_instance_profile.instance-profile` | Instance profile | `Jumphost-instance-profile`, grants the role to the instance. |

---

## Post-deployment: bootstrap tools

On first boot, `install-tools.sh` runs as user data and logs to **`/var/log/init-script.log`** on the instance. It installs:

| Tool | Install method |
|---|---|
| Docker (`docker.io`) | apt, enabled at boot, `ubuntu` added to the `docker` group |
| AWS CLI v2 | Official zip installer |
| kubectl | Official release binary |
| eksctl | Official GitHub release tarball |
| Terraform | HashiCorp apt repository |
| Trivy | Official install script (binary to `/usr/local/bin`) |
| Helm | Official install script |
| Helm repos | `prometheus-community`, `grafana`, `ingress-nginx` (added for the `ubuntu` user) |

Verify over SSH once the instance is up:

```bash
ssh -i <your-key>.pem ubuntu@$(terraform output -raw jumphost_public_ip)

docker --version && kubectl version --client && eksctl version \
  && terraform version && helm version && trivy --version && aws --version
tail -f /var/log/init-script.log   # watch bootstrap progress
```

> Bootstrap can take several minutes. If `user_data_replace_on_change = true` triggers a replacement, the instance is recreated rather than modified in place.

---

## How the pipeline works

Workflow: [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml) — *al-ameen terraform pipeline*

| Trigger | Behaviour |
|---|---|
| `push` to `main` touching `terraform/**` | Full run **including apply** |
| `pull_request` targeting `main` touching `terraform/**` | Plan only (apply is gated to `refs/heads/main` + `push`) |

**Steps**

1. **Checkout** the repository.
2. **Setup Terraform** via `hashicorp/setup-terraform@v4`.
3. **`terraform init -backend-config "bucket=$BUCKET_TF_STATE"`** — initialises the S3 backend using the `BUCKET_TF` secret.
4. **`terraform fmt -check`** — style check (`continue-on-error: true`, informational only).
5. **`terraform validate`** — configuration correctness.
6. **`terraform plan -no-color -input=false -out planfile`** — computes the change set; the run **fails** if planning fails (`Plan Status` step exits `1`).
7. **`terraform apply -auto-approve -input=false -parallelism=1 planfile`** — executes the saved plan **only on push to `main`**.

**Environment variables injected into the job**

| Variable | Source |
|---|---|
| `AWS_ACCESS_KEY_ID` | Secret `AWS_ACCESS_KEY_ID` |
| `AWS_SECRET_ACCESS_KEY` | Secret `AWS_SECRET_ACCESS_KEY` |
| `BUCKET_TF_STATE` | Secret `BUCKET_TF` |
| `AWS_REGION` | Hard-coded `us-east-1` |

All steps run with `working-directory: ./terraform`.

---

## Tearing everything down

**Via CI:** push a change that removes the resources, or delete the repository files and push.

**Locally:**

```bash
cd terraform
terraform init
terraform destroy -auto-approve
```

Manual leftovers to check afterwards:

```bash
# Key pair (Terraform does not create or delete it)
aws ec2 delete-key-pair --key-name aws-samp-key --region us-east-1

# State bucket (only if you no longer need any state history)
aws s3 rb s3://ts-acad-state-file --force
```

---

## Security considerations

Read these before using this stack anywhere beyond a lab/demo:

1. **`AdministratorAccess` on the instance role** — `iam-policy.tf` attaches the full AWS administrator policy to the jumphost role. This is explicitly marked in the code as *for testing purposes only*. In production, replace it with a least-privilege policy scoped to the actions the workload actually needs.
2. **Wide-open security group** — ports `22`, `80`, `8080`, `9000` and `9090` are open to `0.0.0.0/0`. At minimum, restrict SSH to your own IP (`<your-ip>/32`) and front web services with an ALB or Cloudflare Access.
3. **CI credentials** — the pipeline stores long-lived AWS keys as GitHub secrets. Prefer OIDC (`aws-actions/configure-aws-credentials` with `role-to-assume`) so no static keys exist in GitHub at all.
4. **Key pair management** — the instance references `aws-samp-key`, which Terraform does not manage. Keep the private key offline and never commit it.
5. **State file contents** — the S3 state file contains resource attributes (and potentially sensitive data). Enable bucket versioning, encryption and block public access.
6. **Bootstrap script integrity** — `install-tools.sh` downloads and executes third-party installers. Pin versions and verify checksums before running it in a sensitive environment.
7. **No SSH key is injected by Terraform** — access relies entirely on the pre-existing key pair and the AMI's default `ubuntu` user.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | Another apply (or a crashed run) holds the DynamoDB/S3 lock | `terraform force-unlock <LOCK_ID>` or clear the stale lock object. |
| `Backend initialization required` / bucket not found | State bucket missing or `BUCKET_TF` secret wrong | Create the bucket (step 1) or correct the secret; re-run `terraform init`. |
| `InvalidAMIID.NotFound` | `ami_id` default is region-specific | Look up a current Ubuntu AMI in `us-east-1` (`aws ec2 describe-images ...`) and pass it as `ami_id`. |
| Instance boots but tools missing | `install-tools.sh` failed mid-way | SSH in and inspect `/var/log/init-script.log`; fix and re-apply (`user_data_replace_on_change` will replace the instance). |
| `Error: Your query returned no results` for AMI / key pair | Key pair `aws-samp-key` does not exist in the region | Create it (`aws ec2 create-key-pair`) or change `key_name`. |
| `terraform fmt -check` fails in CI | Files not formatted | Run `terraform fmt -recursive` locally and commit. |
| Apply fails with `UnauthorizedOperation` | CI IAM user lacks permissions | Attach the permissions listed under [Prerequisites](#prerequisites). |
| SSH connection refused | Security group or instance not ready | Confirm port 22 is open in the SG and wait for cloud-init to finish. |
| `403 AccessDenied` reading state | State bucket policy / SSE-KMS key policy | Verify the CI user can `s3:GetObject` on the state key. |

---

## Cost notes

Roughly **$0.01–$0.02/hour** (~**$10–$15/month**) for a `t3.micro` with a 30 GB gp2/gp3 root volume in `us-east-1`, plus negligible S3 state storage. No NAT gateway, load balancer or Elastic IP is created, so there are no surprise data-processing charges.

**Destroy the stack when you are done** to avoid paying for an idle instance.

---

## License

Provided as-is for educational and internal use. Review the [Security considerations](#security-considerations) before adapting it to production.
