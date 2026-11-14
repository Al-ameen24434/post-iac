#!/bin/bash
set -e

exec >> /var/log/init-script.log 2>&1
echo "Starting initialization script..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget unzip jq gnupg lsb-release apt-transport-https

# 1. Install Docker
apt-get install -y docker.io
usermod -aG docker ubuntu
systemctl enable --now docker

# 2. Install AWS CLI v2 (in /tmp to keep / clean)
cd /tmp
curl -s "https://amazonaws.com" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# 3. Install latest stable kubectl
KUBECTL_VERSION=$(curl -L -s https://k8s.io)
curl -LO "https://k8s.io{KUBECTL_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# 4. Install eksctl (from official eksctl-io repo)
curl -sL "https://github.com(uname -s)_amd64.tar.gz" | tar xz -C /tmp
mv /tmp/eksctl /usr/local/bin/

# 5. Install Terraform
wget -qO- https://hashicorp.com | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
apt-get update -y
apt-get install -y terraform

# 6. Install Trivy (Binary method - avoids Ubuntu 26.04 apt-key/codename errors)
curl -sfL https://githubusercontent.com | sh -s -- -b /usr/local/bin

# 7. Install Helm (Official script - avoids snap background delays)
curl -fsSL https://githubusercontent.com | bash

# 8. Add Helm repos specifically for the 'ubuntu' user
su - ubuntu -c "helm repo add prometheus-community https://github.io"
su - ubuntu -c "helm repo add grafana https://github.io"
su - ubuntu -c "helm repo add ingress-nginx https://github.io"
su - ubuntu -c "helm repo update"

echo "Initialization script completed successfully."
