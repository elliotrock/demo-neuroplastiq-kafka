#!/usr/bin/env bash
set -e

echo "=============================================="
echo " 🔧 Installing Bookibet / Confluent prerequisites"
echo "=============================================="

OS=$(uname -s)

#########################################
# Homebrew (macOS only)
#########################################
if [[ "$OS" == "Darwin" ]]; then
  if ! command -v brew > /dev/null 2>&1; then
    echo "🍺 Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    echo "🍺 Homebrew already installed"
  fi
fi

#########################################
# Install Make
#########################################
if ! command -v make > /dev/null 2>&1; then
  echo "Installing make..."
  if [[ "$OS" == "Darwin" ]]; then brew install make; else sudo apt install -y make; fi
fi

#########################################
# Install jq
#########################################
if ! command -v jq > /dev/null 2>&1; then
  echo "Installing jq..."
  if [[ "$OS" == "Darwin" ]]; then brew install jq; else sudo apt install -y jq; fi
fi

#########################################
# Python venv
#########################################
if ! command -v python3 > /dev/null 2>&1; then
  echo "Installing Python3..."
  if [[ "$OS" == "Darwin" ]]; then brew install python; else sudo apt install -y python3 python3-venv; fi
fi

#########################################
# Docker (macOS only – Linux should use native or WSL2)
#########################################
if [[ "$OS" == "Darwin" ]]; then
  if ! command -v docker > /dev/null 2>&1; then
    echo "🐳 Installing Docker Desktop..."
    brew install --cask docker
  fi
fi

#########################################
# kubectl
#########################################
if ! command -v kubectl > /dev/null 2>&1; then
  echo "📦 Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/${OS,,}/amd64/kubectl"
  sudo install -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
fi

#########################################
# kubectx / kubens
#########################################
if [[ "$OS" == "Darwin" ]]; then
  if ! command -v kubectx > /dev/null 2>&1; then brew install kubectx; fi
fi

#########################################
# Helm
#########################################
if ! command -v helm > /dev/null 2>&1; then
  echo "📦 Installing Helm..."
  if [[ "$OS" == "Darwin" ]]; then brew install helm; else sudo snap install helm --classic || true; fi
fi

#########################################
# AWS CLI v2
#########################################
if ! command -v aws > /dev/null 2>&1; then
  echo "🌩 Installing AWS CLI v2..."
  if [[ "$OS" == "Darwin" ]]; then
    brew install awscli
  else
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
  fi
fi

#########################################
# aws-iam-authenticator (needed for EKS auth)
#########################################
if ! command -v aws-iam-authenticator > /dev/null 2>&1; then
  echo "🔐 Installing aws-iam-authenticator..."
  if [[ "$OS" == "Darwin" ]]; then
    brew install aws-iam-authenticator
  else
    curl -Lo aws-iam-authenticator \
      https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/latest/download/aws-iam-authenticator_${OS}_amd64
    chmod +x aws-iam-authenticator
    sudo mv aws-iam-authenticator /usr/local/bin/
  fi
fi

#########################################
# eksctl 
#########################################
if ! command -v eksctl > /dev/null 2>&1; then
  echo "📦 Installing eksctl..."
  if [[ "$OS" == "Darwin" ]]; then
    brew tap weaveworks/tap
    brew install weaveworks/tap/eksctl
  else
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
  fi
fi

#########################################
# kind (local Kubernetes cluster testing)
#########################################
if ! command -v kind > /dev/null 2>&1; then
  echo "📦 Installing kind..."
  if [[ "$OS" == "Darwin" ]]; then brew install kind; else
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-$(uname)-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
  fi
fi

#########################################
# Terraform, in case 
#########################################
if ! command -v terraform > /dev/null 2>&1; then
  echo "📦 Installing Terraform..."
  if [[ "$OS" == "Darwin" ]]; then brew tap hashicorp/tap && brew install hashicorp/tap/terraform
  else
    sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
      https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
      sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update && sudo apt install terraform -y
  fi
fi

echo "✨ All prerequisites installed!"
