#!/bin/bash
# =============================================================================
# Phase 2: Create GKE Clusters
# Creates two GKE clusters in parallel — Mumbai and Singapore
# Usage: ./scripts/01-create-clusters.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

log_info "Phase 2: Creating GKE clusters..."

# ─── Step 1: Enable Required APIs ─────────────────────────────────────────────
log_info "Enabling required GCP APIs..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID" --quiet

log_success "APIs enabled"

# ─── Step 2: Create Cluster 1 (Mumbai) ────────────────────────────────────────
log_info "Creating cluster 1: $CLUSTER1_NAME in $CLUSTER1_ZONE ..."

gcloud container clusters create "$CLUSTER1_NAME" \
  --project="$PROJECT_ID" \
  --zone="$CLUSTER1_ZONE" \
  --num-nodes="$NODE_COUNT" \
  --machine-type="$MACHINE_TYPE" \
  --disk-size="$DISK_SIZE" \
  --release-channel="$RELEASE_CHANNEL" \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --enable-ip-alias \
  --enable-network-policy \
  --labels="env=demo,region=${CLUSTER1_REGION},managed-by=gcloud" \
  --async \
  --quiet

log_success "Cluster 1 creation started (async)"

# ─── Step 3: Create Cluster 2 (Singapore) ─────────────────────────────────────
log_info "Creating cluster 2: $CLUSTER2_NAME in $CLUSTER2_ZONE ..."

gcloud container clusters create "$CLUSTER2_NAME" \
  --project="$PROJECT_ID" \
  --zone="$CLUSTER2_ZONE" \
  --num-nodes="$NODE_COUNT" \
  --machine-type="$MACHINE_TYPE" \
  --disk-size="$DISK_SIZE" \
  --release-channel="$RELEASE_CHANNEL" \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --enable-ip-alias \
  --enable-network-policy \
  --labels="env=demo,region=${CLUSTER2_REGION},managed-by=gcloud" \
  --async \
  --quiet

log_success "Cluster 2 creation started (async)"

# ─── Step 4: Wait for Both Clusters ───────────────────────────────────────────
log_info "Waiting for both clusters to be RUNNING (this takes 5-8 minutes)..."

wait_for_cluster() {
  local cluster_name=$1
  local zone=$2
  log_info "  Waiting for $cluster_name..."
  while true; do
    STATUS=$(gcloud container clusters describe "$cluster_name" \
      --zone="$zone" --project="$PROJECT_ID" \
      --format="value(status)" 2>/dev/null || echo "PENDING")
    if [ "$STATUS" = "RUNNING" ]; then
      log_success "  $cluster_name is RUNNING"
      break
    fi
    echo "    Status: $STATUS — retrying in 20s..."
    sleep 20
  done
}

wait_for_cluster "$CLUSTER1_NAME" "$CLUSTER1_ZONE"
wait_for_cluster "$CLUSTER2_NAME" "$CLUSTER2_ZONE"

# ─── Step 5: Fetch kubeconfigs ─────────────────────────────────────────────────
log_info "Fetching kubeconfigs..."

gcloud container clusters get-credentials "$CLUSTER1_NAME" \
  --zone="$CLUSTER1_ZONE" --project="$PROJECT_ID"

gcloud container clusters get-credentials "$CLUSTER2_NAME" \
  --zone="$CLUSTER2_ZONE" --project="$PROJECT_ID"

# ─── Step 6: Rename contexts ───────────────────────────────────────────────────
log_info "Renaming kubectl contexts to friendly names..."

CONTEXT1_FULL="gke_${PROJECT_ID}_${CLUSTER1_ZONE}_${CLUSTER1_NAME}"
CONTEXT2_FULL="gke_${PROJECT_ID}_${CLUSTER2_ZONE}_${CLUSTER2_NAME}"

kubectl config rename-context "$CONTEXT1_FULL" "$CLUSTER1_CONTEXT" 2>/dev/null || true
kubectl config rename-context "$CONTEXT2_FULL" "$CLUSTER2_CONTEXT" 2>/dev/null || true

log_success "Contexts renamed: $CLUSTER1_CONTEXT, $CLUSTER2_CONTEXT"

# ─── Step 7: Create Namespaces ─────────────────────────────────────────────────
log_info "Creating namespaces on both clusters..."

for ctx in "$CLUSTER1_CONTEXT" "$CLUSTER2_CONTEXT"; do
  kubectl --context="$ctx" create namespace "$NS_APPS" --dry-run=client -o yaml | \
    kubectl --context="$ctx" apply -f -
  kubectl --context="$ctx" create namespace "$NS_MONITORING" --dry-run=client -o yaml | \
    kubectl --context="$ctx" apply -f -
done

kubectl --context="$CLUSTER1_CONTEXT" create namespace "$NS_ARGOCD" --dry-run=client -o yaml | \
  kubectl --context="$CLUSTER1_CONTEXT" apply -f -

log_success "Namespaces created"

# ─── Step 8: Verify ───────────────────────────────────────────────────────────
log_info "Verifying clusters..."

echo ""
echo "=== Cluster 1: $CLUSTER1_NAME (Mumbai) ==="
kubectl get nodes --context="$CLUSTER1_CONTEXT" -o wide

echo ""
echo "=== Cluster 2: $CLUSTER2_NAME (Singapore) ==="
kubectl get nodes --context="$CLUSTER2_CONTEXT" -o wide

echo ""
kubectl config get-contexts

echo ""
log_success "Phase 2 complete! Both clusters are ready."
echo ""
echo "  Next: Run ./scripts/02-install-argocd.sh"
