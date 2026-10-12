#!/bin/bash
# =============================================================================
# Phase 7: Set up GCP Global HTTP Load Balancer
# Creates NEGs, backend services, URL map, and forwarding rule
# Usage: ./scripts/06-setup-glb.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

log_info "Phase 7: Setting up GCP Global HTTP Load Balancer..."

# ─── Step 1: Reserve Global Static IP ─────────────────────────────────────────
log_info "Reserving global static IP: $GLB_IP_NAME ..."

gcloud compute addresses create "$GLB_IP_NAME" \
  --global \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || log_warn "IP already exists, continuing..."

GLOBAL_IP=$(gcloud compute addresses describe "$GLB_IP_NAME" \
  --global --project="$PROJECT_ID" \
  --format="value(address)")

log_success "Global IP: $GLOBAL_IP"

# ─── Step 2: Create Health Checks ─────────────────────────────────────────────
log_info "Creating health checks..."

for SVC in order-svc product-svc user-svc; do
  HC_NAME="${SVC}-health-check"
  gcloud compute health-checks create http "$HC_NAME" \
    --project="$PROJECT_ID" \
    --port=8080 \
    --request-path="/" \
    --check-interval=5 \
    --timeout=5 \
    --healthy-threshold=2 \
    --unhealthy-threshold=3 \
    --quiet 2>/dev/null || log_warn "  Health check $HC_NAME already exists"
  log_success "  Health check created: $HC_NAME"
done

# ─── Step 3: Get NEG Names ─────────────────────────────────────────────────────
# NEGs are auto-created by GKE when annotation cloud.google.com/neg is set
# We need to wait for them to appear

log_info "Waiting for NEGs to be created by GKE (annotation-triggered)..."

get_neg_name() {
  local svc=$1
  local zone=$2
  # NEG name format: k8s1-<cluster-hash>-<namespace>-<service>-<port>
  gcloud compute network-endpoint-groups list \
    --project="$PROJECT_ID" \
    --zones="$zone" \
    --filter="name~${svc}" \
    --format="value(name)" 2>/dev/null | head -1
}

# Wait up to 3 minutes for NEGs
for SVC in order-svc product-svc user-svc; do
  for ATTEMPT in {1..18}; do
    NEG1=$(get_neg_name "$SVC" "$CLUSTER1_ZONE")
    NEG2=$(get_neg_name "$SVC" "$CLUSTER2_ZONE")
    if [ -n "$NEG1" ] && [ -n "$NEG2" ]; then
      log_success "  NEGs found for $SVC: $NEG1, $NEG2"
      break
    fi
    echo "  Waiting for $SVC NEGs... attempt $ATTEMPT/18"
    sleep 10
  done
done

# ─── Step 4: Create Backend Services ──────────────────────────────────────────
log_info "Creating backend services..."

for SVC in order-svc product-svc user-svc; do
  BS_NAME="${SVC}-backend"
  HC_NAME="${SVC}-health-check"

  gcloud compute backend-services create "$BS_NAME" \
    --project="$PROJECT_ID" \
    --global \
    --protocol=HTTP \
    --port-name=http \
    --health-checks="$HC_NAME" \
    --load-balancing-scheme=EXTERNAL \
    --quiet 2>/dev/null || log_warn "  Backend service $BS_NAME already exists"

  # Add Mumbai NEG backend
  NEG1=$(get_neg_name "$SVC" "$CLUSTER1_ZONE")
  if [ -n "$NEG1" ]; then
    gcloud compute backend-services add-backend "$BS_NAME" \
      --project="$PROJECT_ID" \
      --global \
      --network-endpoint-group="$NEG1" \
      --network-endpoint-group-zone="$CLUSTER1_ZONE" \
      --balancing-mode=RATE \
      --max-rate-per-endpoint=100 \
      --quiet 2>/dev/null || log_warn "  Mumbai backend already added"
    log_success "  Added Mumbai NEG to $BS_NAME"
  fi

  # Add Singapore NEG backend
  NEG2=$(get_neg_name "$SVC" "$CLUSTER2_ZONE")
  if [ -n "$NEG2" ]; then
    gcloud compute backend-services add-backend "$BS_NAME" \
      --project="$PROJECT_ID" \
      --global \
      --network-endpoint-group="$NEG2" \
      --network-endpoint-group-zone="$CLUSTER2_ZONE" \
      --balancing-mode=RATE \
      --max-rate-per-endpoint=100 \
      --quiet 2>/dev/null || log_warn "  Singapore backend already added"
    log_success "  Added Singapore NEG to $BS_NAME"
  fi
done

# ─── Step 5: Create URL Map ────────────────────────────────────────────────────
log_info "Creating URL map with path-based routing..."

gcloud compute url-maps create "$GLB_LB_NAME" \
  --project="$PROJECT_ID" \
  --default-service=order-svc-backend \
  --quiet 2>/dev/null || log_warn "URL map already exists"

# Add path rules
gcloud compute url-maps import "$GLB_LB_NAME" \
  --project="$PROJECT_ID" \
  --global \
  --quiet <<EOF
kind: compute#urlMap
name: ${GLB_LB_NAME}
defaultService: https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/backendServices/order-svc-backend
hostRules:
  - hosts:
      - '*'
    pathMatcher: path-matcher
pathMatchers:
  - name: path-matcher
    defaultService: https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/backendServices/order-svc-backend
    pathRules:
      - paths:
          - /orders
          - /orders/*
        service: https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/backendServices/order-svc-backend
      - paths:
          - /products
          - /products/*
        service: https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/backendServices/product-svc-backend
      - paths:
          - /users
          - /users/*
        service: https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/backendServices/user-svc-backend
EOF

log_success "URL map configured with path routing"

# ─── Step 6: Create Target HTTP Proxy ─────────────────────────────────────────
log_info "Creating target HTTP proxy..."

gcloud compute target-http-proxies create "${GLB_LB_NAME}-proxy" \
  --project="$PROJECT_ID" \
  --url-map="$GLB_LB_NAME" \
  --quiet 2>/dev/null || log_warn "HTTP proxy already exists"

log_success "Target HTTP proxy created"

# ─── Step 7: Create Forwarding Rule ───────────────────────────────────────────
log_info "Creating global forwarding rule..."

gcloud compute forwarding-rules create "${GLB_LB_NAME}-rule" \
  --project="$PROJECT_ID" \
  --global \
  --target-http-proxy="${GLB_LB_NAME}-proxy" \
  --address="$GLB_IP_NAME" \
  --ports=80 \
  --quiet 2>/dev/null || log_warn "Forwarding rule already exists"

log_success "Forwarding rule created"

# ─── Step 8: Verify ───────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Global Load Balancer Setup Complete"
echo "============================================================"
echo " Global IP    : $GLOBAL_IP"
echo " Order svc    : http://$GLOBAL_IP/orders"
echo " Product svc  : http://$GLOBAL_IP/products"
echo " User svc     : http://$GLOBAL_IP/users"
echo "============================================================"
echo ""
echo " Note: GLB propagation takes 5-10 minutes."
echo " Test with:"
echo "   curl http://$GLOBAL_IP/orders"
echo ""

# Wait for GLB to be ready
log_info "Testing GLB (may need a few minutes to propagate)..."
for i in {1..12}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://$GLOBAL_IP/orders" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    RESPONSE=$(curl -s "http://$GLOBAL_IP/orders")
    log_success "GLB is responding! Response: $RESPONSE"
    break
  fi
  echo "  HTTP $HTTP_CODE — waiting for GLB... ($i/12)"
  sleep 30
done

echo ""
echo "  Next: Run ./scripts/07-simulate-failover.sh"
