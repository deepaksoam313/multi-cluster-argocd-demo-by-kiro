#!/bin/bash
# =============================================================================
# Phase 3a: Install ArgoCD on Cluster 1 (Mumbai Hub)
# Usage: ./scripts/02-install-argocd.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

log_info "Phase 3a: Installing ArgoCD on $CLUSTER1_NAME..."

# ─── Step 1: Switch to Cluster 1 ──────────────────────────────────────────────
kubectl config use-context "$CLUSTER1_CONTEXT"
log_success "Context switched to $CLUSTER1_CONTEXT"

# ─── Step 2: Install ArgoCD ───────────────────────────────────────────────────
log_info "Installing ArgoCD (namespace: $NS_ARGOCD)..."

kubectl apply -n "$NS_ARGOCD" \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

log_success "ArgoCD manifests applied"

# ─── Step 3: Wait for ArgoCD pods ─────────────────────────────────────────────
log_info "Waiting for ArgoCD pods to be Running..."

kubectl wait --for=condition=available \
  deployment/argocd-server \
  deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller \
  -n "$NS_ARGOCD" \
  --timeout=300s

log_success "ArgoCD pods are ready"

# ─── Step 4: Expose ArgoCD Server ─────────────────────────────────────────────
log_info "Exposing ArgoCD server as LoadBalancer..."

kubectl patch svc argocd-server -n "$NS_ARGOCD" \
  -p '{"spec": {"type": "LoadBalancer"}}'

# Wait for external IP
log_info "Waiting for LoadBalancer IP (may take 2-3 minutes)..."
while true; do
  ARGOCD_IP=$(kubectl get svc argocd-server -n "$NS_ARGOCD" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "$ARGOCD_IP" ]; then
    break
  fi
  echo "  Waiting for IP..."
  sleep 10
done

log_success "ArgoCD Server IP: $ARGOCD_IP"

# ─── Step 5: Get Admin Password ───────────────────────────────────────────────
log_info "Getting ArgoCD initial admin password..."

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "$NS_ARGOCD" \
  -o jsonpath="{.data.password}" | base64 -d)

# ─── Step 6: Install ArgoCD CLI ───────────────────────────────────────────────
if ! command -v argocd &>/dev/null; then
  log_info "Installing ArgoCD CLI..."
  curl -sSL -o /tmp/argocd \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo mv /tmp/argocd /usr/local/bin/argocd
  sudo chmod +x /usr/local/bin/argocd
  log_success "ArgoCD CLI installed: $(argocd version --client --short)"
else
  log_success "ArgoCD CLI already installed: $(argocd version --client --short)"
fi

# ─── Step 7: Login to ArgoCD ──────────────────────────────────────────────────
log_info "Logging in to ArgoCD..."

argocd login "$ARGOCD_IP" \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --insecure

log_success "Logged in to ArgoCD"

# ─── Step 8: Save credentials ─────────────────────────────────────────────────
cat > /tmp/argocd-credentials.txt <<EOF
ArgoCD Server: http://${ARGOCD_IP}
Username: admin
Password: ${ARGOCD_PASSWORD}
EOF

echo ""
echo "============================================================"
echo " ArgoCD Installation Complete"
echo "============================================================"
echo " UI URL  : http://${ARGOCD_IP}"
echo " Username: admin"
echo " Password: ${ARGOCD_PASSWORD}"
echo " Saved to: /tmp/argocd-credentials.txt"
echo "============================================================"
echo ""
echo "  Next: Run ./scripts/03-register-clusters.sh"
