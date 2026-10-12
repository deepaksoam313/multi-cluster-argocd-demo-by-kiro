#!/bin/bash
# =============================================================================
# Phase 3b: Register Cluster 2 (Singapore) with ArgoCD
# Usage: ./scripts/03-register-clusters.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

log_info "Phase 3b: Registering $CLUSTER2_NAME with ArgoCD..."

# ─── Step 1: Verify ArgoCD is accessible ──────────────────────────────────────
if ! argocd cluster list &>/dev/null; then
  log_error "Not logged in to ArgoCD. Run 02-install-argocd.sh first."
  exit 1
fi

log_success "ArgoCD connection verified"

# ─── Step 2: Register Cluster 2 ───────────────────────────────────────────────
log_info "Adding $CLUSTER2_NAME to ArgoCD..."

# argocd cluster add reads from your local kubeconfig
argocd cluster add "$CLUSTER2_CONTEXT" \
  --name "$CLUSTER2_NAME" \
  --yes

log_success "$CLUSTER2_NAME registered with ArgoCD"

# ─── Step 3: Verify both clusters ─────────────────────────────────────────────
log_info "Listing all registered clusters..."
echo ""
argocd cluster list
echo ""

# ─── Step 4: Label clusters in ArgoCD for ApplicationSet routing ───────────────
log_info "Adding region labels to ArgoCD cluster secrets..."

# Get the ArgoCD cluster secret for singapore and add region label
SINGAPORE_SECRET=$(kubectl get secret -n "$NS_ARGOCD" \
  --context="$CLUSTER1_CONTEXT" \
  -l "argocd.argoproj.io/secret-type=cluster" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.data.name}{"\n"}{end}' | \
  grep "$(echo -n $CLUSTER2_NAME | base64)" | awk '{print $1}')

if [ -n "$SINGAPORE_SECRET" ]; then
  kubectl label secret "$SINGAPORE_SECRET" \
    -n "$NS_ARGOCD" \
    --context="$CLUSTER1_CONTEXT" \
    region="$CLUSTER2_REGION" \
    cluster-name="$CLUSTER2_NAME" \
    --overwrite
  log_success "Labels added to Singapore cluster secret"
fi

# Label the in-cluster (Mumbai) secret
MUMBAI_SECRET=$(kubectl get secret -n "$NS_ARGOCD" \
  --context="$CLUSTER1_CONTEXT" \
  -l "argocd.argoproj.io/secret-type=cluster" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -1)

# Note: in-cluster uses a special endpoint, label it separately
kubectl get secret -n "$NS_ARGOCD" \
  --context="$CLUSTER1_CONTEXT" \
  -l "argocd.argoproj.io/secret-type=cluster" \
  -o name | while read secret; do
    NAME=$(kubectl get -n "$NS_ARGOCD" --context="$CLUSTER1_CONTEXT" \
      "$secret" -o jsonpath='{.data.name}' | base64 -d 2>/dev/null || echo "")
    if [ "$NAME" = "$CLUSTER2_NAME" ]; then
      kubectl label "$secret" -n "$NS_ARGOCD" \
        --context="$CLUSTER1_CONTEXT" \
        region="$CLUSTER2_REGION" \
        cluster-name="$CLUSTER2_NAME" \
        --overwrite
    fi
  done

# ─── Step 5: Create ArgoCD Project ────────────────────────────────────────────
log_info "Creating ArgoCD project: multi-region-demo..."

kubectl apply --context="$CLUSTER1_CONTEXT" -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: multi-region-demo
  namespace: ${NS_ARGOCD}
spec:
  description: "Multi-region active-active demo project"
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

log_success "ArgoCD project created: multi-region-demo"

echo ""
echo "============================================================"
echo " Cluster Registration Complete"
echo "============================================================"
argocd cluster list
echo "============================================================"
echo ""
echo "  Next: Run ./scripts/04-deploy-apps.sh"
