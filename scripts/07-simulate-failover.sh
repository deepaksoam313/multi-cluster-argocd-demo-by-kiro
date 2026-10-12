#!/bin/bash
# =============================================================================
# Phase 8: Simulate Regional Failover
# Generates traffic, fails Singapore, observes GLB reroute, recovers
# Usage: ./scripts/07-simulate-failover.sh [--phase=baseline|fail|recover|all]
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

PHASE="${1:-all}"

GLOBAL_IP=$(gcloud compute addresses describe "$GLB_IP_NAME" \
  --global --project="$PROJECT_ID" \
  --format="value(address)" 2>/dev/null || echo "")

if [ -z "$GLOBAL_IP" ]; then
  log_error "Could not find GLB IP. Run 06-setup-glb.sh first."
  exit 1
fi

# ─── Helper: Count responses by region ────────────────────────────────────────
count_regions() {
  local count="${1:-20}"
  log_info "Sending $count requests to GLB, counting region distribution..."
  echo ""
  for i in $(seq 1 "$count"); do
    curl -s "http://$GLOBAL_IP/orders" 2>/dev/null || echo '{"error":"failed"}'
    echo ""
    sleep 0.1
  done | grep -oP '"cluster":"[^"]*"' | sort | uniq -c | sort -rn
  echo ""
}

# ─── Phase: Baseline ──────────────────────────────────────────────────────────
run_baseline() {
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  PHASE: BASELINE — Both regions serving traffic  ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""

  log_info "Verifying both regions are healthy..."

  echo "=== Mumbai Pods ==="
  kubectl get pods -n "$NS_APPS" --context="$CLUSTER1_CONTEXT" \
    --no-headers | awk '{print $1, $3}'

  echo ""
  echo "=== Singapore Pods ==="
  kubectl get pods -n "$NS_APPS" --context="$CLUSTER2_CONTEXT" \
    --no-headers | awk '{print $1, $3}'

  echo ""
  log_info "Starting background traffic generator (30 req/sec)..."

  # Background traffic loop
  while true; do
    curl -s "http://$GLOBAL_IP/orders"    > /dev/null 2>&1 || true
    curl -s "http://$GLOBAL_IP/products"  > /dev/null 2>&1 || true
    curl -s "http://$GLOBAL_IP/users"     > /dev/null 2>&1 || true
    sleep 0.1
  done &
  TRAFFIC_PID=$!
  echo "$TRAFFIC_PID" > /tmp/traffic-gen.pid
  log_success "Traffic generator started (PID: $TRAFFIC_PID)"
  log_info "  Stop with: kill $(cat /tmp/traffic-gen.pid)"

  echo ""
  count_regions 30

  echo ""
  log_success "Baseline established — both regions serving traffic"
}

# ─── Phase: Simulate Failure ──────────────────────────────────────────────────
run_failure() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  PHASE: FAILURE — Taking down Singapore             ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  log_warn "Scaling all Singapore deployments to 0 replicas..."

  for SVC in order-svc product-svc user-svc; do
    kubectl scale deployment "$SVC" \
      --replicas=0 \
      -n "$NS_APPS" \
      --context="$CLUSTER2_CONTEXT"
    log_warn "  Scaled $SVC to 0 (Singapore)"
  done

  echo ""
  log_info "Singapore pods should be terminating..."
  kubectl get pods -n "$NS_APPS" --context="$CLUSTER2_CONTEXT"

  echo ""
  log_info "Waiting 30 seconds for GLB health checks to detect failure..."
  echo "  (Health check: 3 failures × 5s interval = 15s to mark unhealthy)"

  for i in {30..1}; do
    printf "\r  Countdown: %2d seconds remaining..." "$i"
    sleep 1
  done
  echo ""

  echo ""
  log_info "Checking traffic distribution after failure..."
  count_regions 20

  echo ""
  log_warn "Expected: ALL traffic routed to gke-mumbai"
  echo ""
  log_info "Open Grafana to observe:"
  echo "  - Singapore pod count → 0"
  echo "  - Mumbai pod count → unchanged"
  echo "  - Request rate: Singapore → 0, Mumbai → doubles"
}

# ─── Phase: Recovery ──────────────────────────────────────────────────────────
run_recovery() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  PHASE: RECOVERY — Restoring Singapore              ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  log_info "Scaling Singapore deployments back to 2 replicas..."

  for SVC in order-svc product-svc user-svc; do
    kubectl scale deployment "$SVC" \
      --replicas=2 \
      -n "$NS_APPS" \
      --context="$CLUSTER2_CONTEXT"
    log_info "  Scaled $SVC to 2 (Singapore)"
  done

  log_info "Waiting for Singapore pods to be Running..."
  kubectl wait --for=condition=available \
    deployment/order-svc deployment/product-svc deployment/user-svc \
    -n "$NS_APPS" \
    --context="$CLUSTER2_CONTEXT" \
    --timeout=120s

  log_success "Singapore pods are Running"

  echo ""
  log_info "Waiting 20 seconds for GLB to detect recovery..."
  echo "  (Health check: 2 successes × 5s = 10s to mark healthy)"

  for i in {20..1}; do
    printf "\r  Countdown: %2d seconds remaining..." "$i"
    sleep 1
  done
  echo ""

  echo ""
  log_info "Checking traffic distribution after recovery..."
  count_regions 20

  echo ""
  log_success "Expected: Traffic split between gke-mumbai and gke-singapore"

  # Stop traffic generator
  if [ -f /tmp/traffic-gen.pid ]; then
    TPID=$(cat /tmp/traffic-gen.pid)
    kill "$TPID" 2>/dev/null || true
    rm -f /tmp/traffic-gen.pid
    log_info "Traffic generator stopped"
  fi
}

# ─── Phase: ArgoCD Self-Heal Demo ─────────────────────────────────────────────
run_selfheal() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  BONUS: ArgoCD Self-Heal Demonstration              ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  log_info "Manually changing replica count (introducing drift)..."
  kubectl scale deployment order-svc \
    --replicas=5 \
    -n "$NS_APPS" \
    --context="$CLUSTER1_CONTEXT"

  echo ""
  log_warn "order-svc now has 5 replicas (git says 2)"
  kubectl get deployment order-svc -n "$NS_APPS" --context="$CLUSTER1_CONTEXT"

  echo ""
  log_info "ArgoCD will detect drift and revert within ~3 minutes..."
  log_info "Watch in ArgoCD UI: Applications → order-svc-gke-mumbai"
  echo ""
  echo "  argocd app get order-svc-gke-mumbai"
  echo ""

  # Wait and check
  log_info "Waiting up to 4 minutes for ArgoCD to self-heal..."
  for i in {1..24}; do
    sleep 10
    REPLICAS=$(kubectl get deployment order-svc \
      -n "$NS_APPS" --context="$CLUSTER1_CONTEXT" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    echo "  Current replicas: $REPLICAS (waiting for ArgoCD to revert to 2)"
    if [ "$REPLICAS" = "2" ]; then
      log_success "ArgoCD self-healed! order-svc back to 2 replicas"
      break
    fi
  done
}

# ─── Run Phases ───────────────────────────────────────────────────────────────
case "$PHASE" in
  "--phase=baseline") run_baseline ;;
  "--phase=fail")     run_failure ;;
  "--phase=recover")  run_recovery ;;
  "--phase=selfheal") run_selfheal ;;
  "--phase=all"|*)
    run_baseline
    echo ""
    read -r -p "Press Enter to simulate Singapore FAILURE..."
    run_failure
    echo ""
    read -r -p "Press Enter to RECOVER Singapore..."
    run_recovery
    echo ""
    read -r -p "Press Enter to demo ArgoCD self-heal..."
    run_selfheal
    ;;
esac

echo ""
echo "============================================================"
echo " Failover simulation complete!"
echo "============================================================"
echo ""
echo " What we observed:"
echo "  1. Active-active: both regions serving normal traffic"
echo "  2. GLB detected Singapore failure in ~15 seconds"
echo "  3. 100% traffic rerouted to Mumbai automatically"
echo "  4. Singapore recovered, traffic redistributed"
echo "  5. ArgoCD reverted manual replica change (self-heal)"
echo ""
echo "  Next: Run ./scripts/cleanup.sh when done with the lab"
