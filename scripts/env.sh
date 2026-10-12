#!/bin/bash
# =============================================================================
# Environment Variables — source this before running any script
# Usage: source scripts/env.sh
# =============================================================================

# GCP Project
export PROJECT_ID="skilled-text-468416-g3"
export BILLING_ACCOUNT=""   # Optional, fill if needed

# Cluster 1 — Mumbai (Primary / ArgoCD Hub)
export CLUSTER1_NAME="gke-mumbai"
export CLUSTER1_REGION="asia-south1"
export CLUSTER1_ZONE="asia-south1-a"
export CLUSTER1_CONTEXT="gke-mumbai"

# Cluster 2 — Singapore (Secondary)
export CLUSTER2_NAME="gke-singapore"
export CLUSTER2_REGION="asia-southeast1"
export CLUSTER2_ZONE="asia-southeast1-a"
export CLUSTER2_CONTEXT="gke-singapore"

# GKE Node Config
export NODE_COUNT=2
export MACHINE_TYPE="e2-medium"
export DISK_SIZE="50"
export K8S_VERSION="latest"
export RELEASE_CHANNEL="regular"

# Namespaces
export NS_APPS="microservices"
export NS_ARGOCD="argocd"
export NS_MONITORING="monitoring"

# ArgoCD
export ARGOCD_VERSION="stable"
export ARGOCD_NAMESPACE="argocd"

# Microservices
export SERVICES=("order-svc" "product-svc" "user-svc")
export APP_IMAGE="hashicorp/http-echo:latest"
export APP_PORT="8080"

# Load Balancer
export GLB_IP_NAME="multi-region-lb-ip"
export GLB_LB_NAME="multi-region-http-lb"
export HEALTH_CHECK_NAME="microservices-health-check"

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Helper functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "================================================"
echo " Multi-Region Demo Environment Loaded"
echo "================================================"
echo " Project  : $PROJECT_ID"
echo " Cluster1 : $CLUSTER1_NAME ($CLUSTER1_REGION)"
echo " Cluster2 : $CLUSTER2_NAME ($CLUSTER2_REGION)"
echo "================================================"
echo ""
