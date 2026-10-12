#!/bin/bash
# =============================================================================
# CLEANUP — Delete all GCP resources created during the lab
# Run this when done to avoid unexpected charges
# Usage: ./scripts/cleanup.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ⚠️   CLEANUP — This will delete all lab resources       ║"
echo "║  GKE clusters, Load Balancer, IPs, NEGs                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
read -r -p "Are you sure? Type YES to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 0
fi

# Stop traffic generator if running
if [ -f /tmp/traffic-gen.pid ]; then
  kill "$(cat /tmp/traffic-gen.pid)" 2>/dev/null || true
  rm -f /tmp/traffic-gen.pid
fi

# ─── Delete Load Balancer Resources ───────────────────────────────────────────
log_info "Deleting Load Balancer resources..."

gcloud compute forwarding-rules delete "${GLB_LB_NAME}-rule" \
  --global --project="$PROJECT_ID" --quiet 2>/dev/null || true

gcloud compute target-http-proxies delete "${GLB_LB_NAME}-proxy" \
  --project="$PROJECT_ID" --quiet 2>/dev/null || true

gcloud compute url-maps delete "$GLB_LB_NAME" \
  --project="$PROJECT_ID" --quiet 2>/dev/null || true

for SVC in order-svc product-svc user-svc; do
  gcloud compute backend-services delete "${SVC}-backend" \
    --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
  gcloud compute health-checks delete "${SVC}-health-check" \
    --project="$PROJECT_ID" --quiet 2>/dev/null || true
done

gcloud compute addresses delete "$GLB_IP_NAME" \
  --global --project="$PROJECT_ID" --quiet 2>/dev/null || true

log_success "Load balancer resources deleted"

# ─── Delete GKE Clusters ───────────────────────────────────────────────────────
log_info "Deleting GKE cluster: $CLUSTER1_NAME ..."
gcloud container clusters delete "$CLUSTER1_NAME" \
  --zone="$CLUSTER1_ZONE" --project="$PROJECT_ID" \
  --quiet --async 2>/dev/null || true

log_info "Deleting GKE cluster: $CLUSTER2_NAME ..."
gcloud container clusters delete "$CLUSTER2_NAME" \
  --zone="$CLUSTER2_ZONE" --project="$PROJECT_ID" \
  --quiet --async 2>/dev/null || true

log_success "Cluster deletion started (async)"

# ─── Clean kubeconfig ─────────────────────────────────────────────────────────
log_info "Cleaning up kubeconfig contexts..."
kubectl config delete-context "$CLUSTER1_CONTEXT" 2>/dev/null || true
kubectl config delete-context "$CLUSTER2_CONTEXT" 2>/dev/null || true
log_success "kubeconfig cleaned"

echo ""
log_success "Cleanup initiated. Clusters are being deleted in background."
echo ""
echo "  Verify deletion:"
echo "   gcloud container clusters list --project=$PROJECT_ID"
echo "   gcloud compute forwarding-rules list --global --project=$PROJECT_ID"
