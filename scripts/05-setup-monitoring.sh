#!/bin/bash
# =============================================================================
# Phase 6: Install Prometheus + Grafana on Both Clusters
# Uses kube-prometheus-stack Helm chart via ArgoCD
# Usage: ./scripts/05-setup-monitoring.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

SCRIPT_DIR="$(dirname "$0")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log_info "Phase 6: Setting up monitoring (Prometheus + Grafana)..."

# ─── Step 1: Add Prometheus Helm Repo ─────────────────────────────────────────
log_info "Adding Prometheus Community Helm repo..."
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts --force-update
helm repo update
log_success "Helm repo added"

# ─── Step 2: Create Prometheus values for Mumbai (primary) ────────────────────
log_info "Creating Helm values for Mumbai (primary with Grafana)..."

mkdir -p "$PROJECT_ROOT/gitops/monitoring"

cat > "$PROJECT_ROOT/gitops/monitoring/values-mumbai.yaml" <<EOF
# kube-prometheus-stack values for gke-mumbai (primary cluster)
# Has Grafana enabled

fullnameOverride: kube-prometheus-stack

# ── Grafana ─────────────────────────────────────────────────────────────────
grafana:
  enabled: true
  adminPassword: "demo-password-123"
  service:
    type: LoadBalancer
  grafana.ini:
    server:
      root_url: http://localhost:3000
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus-Mumbai
          type: prometheus
          url: http://kube-prometheus-stack-prometheus:9090
          isDefault: true
          jsonData:
            timeInterval: "15s"
            customQueryParameters: "cluster=gke-mumbai"
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: 'default'
          orgId: 1
          folder: ''
          type: file
          options:
            path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      kubernetes-cluster:
        gnetId: 7249
        revision: 1
        datasource: Prometheus-Mumbai
      node-exporter:
        gnetId: 1860
        revision: 37
        datasource: Prometheus-Mumbai

# ── Prometheus ───────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    externalLabels:
      cluster: gke-mumbai
      region: asia-south1
    retention: 24h
    resources:
      requests:
        memory: 400Mi
        cpu: 200m
      limits:
        memory: 800Mi
        cpu: 500m
    # Accept remote_write from Singapore
    enableRemoteWriteReceiver: true

# ── AlertManager ─────────────────────────────────────────────────────────────
alertmanager:
  enabled: true

# ── kube-state-metrics ───────────────────────────────────────────────────────
kube-state-metrics:
  enabled: true
  metricLabelsAllowlist:
    - pods=[app,region,cluster,version]
    - deployments=[app,region,cluster]

# ── node-exporter ────────────────────────────────────────────────────────────
prometheus-node-exporter:
  enabled: true
EOF

log_success "Mumbai values created"

# ─── Step 3: Create Prometheus values for Singapore (secondary) ───────────────
log_info "Creating Helm values for Singapore (remote_write only)..."

# Get Mumbai Prometheus service (will be set after install)
# Placeholder — update after Mumbai Prometheus LB IP is known
MUMBAI_PROM_IP="REPLACE_WITH_MUMBAI_PROMETHEUS_LB_IP"

cat > "$PROJECT_ROOT/gitops/monitoring/values-singapore.yaml" <<EOF
# kube-prometheus-stack values for gke-singapore (secondary cluster)
# NO Grafana — metrics are remote_written to Mumbai

fullnameOverride: kube-prometheus-stack

# ── Grafana (disabled on secondary) ─────────────────────────────────────────
grafana:
  enabled: false

# ── Prometheus ───────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    externalLabels:
      cluster: gke-singapore
      region: asia-southeast1
    retention: 6h
    resources:
      requests:
        memory: 256Mi
        cpu: 100m
      limits:
        memory: 512Mi
        cpu: 300m
    # Remote write to Mumbai Prometheus
    remoteWrite:
      - url: "http://${MUMBAI_PROM_IP}:9090/api/v1/write"
        remoteTimeout: 30s
        writeRelabelConfigs:
          - sourceLabels: [__name__]
            regex: ".*"
            action: keep
        queueConfig:
          capacity: 10000
          maxSamplesPerSend: 5000

# ── kube-state-metrics ───────────────────────────────────────────────────────
kube-state-metrics:
  enabled: true
  metricLabelsAllowlist:
    - pods=[app,region,cluster,version]
    - deployments=[app,region,cluster]

# ── node-exporter ────────────────────────────────────────────────────────────
prometheus-node-exporter:
  enabled: true

# ── AlertManager (disabled on secondary) ────────────────────────────────────
alertmanager:
  enabled: false
EOF

log_success "Singapore values created"

# ─── Step 4: Install on Mumbai ────────────────────────────────────────────────
log_info "Installing Prometheus stack on Mumbai ($CLUSTER1_CONTEXT)..."

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "$NS_MONITORING" \
  --create-namespace \
  --values "$PROJECT_ROOT/gitops/monitoring/values-mumbai.yaml" \
  --kube-context "$CLUSTER1_CONTEXT" \
  --wait \
  --timeout 10m

log_success "Prometheus stack installed on Mumbai"

# ─── Step 5: Install on Singapore ─────────────────────────────────────────────
log_info "Installing Prometheus stack on Singapore ($CLUSTER2_CONTEXT)..."

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "$NS_MONITORING" \
  --create-namespace \
  --values "$PROJECT_ROOT/gitops/monitoring/values-singapore.yaml" \
  --kube-context "$CLUSTER2_CONTEXT" \
  --wait \
  --timeout 10m

log_success "Prometheus stack installed on Singapore"

# ─── Step 6: Get Grafana IP ───────────────────────────────────────────────────
log_info "Waiting for Grafana LoadBalancer IP..."

while true; do
  GRAFANA_IP=$(kubectl get svc kube-prometheus-stack-grafana \
    -n "$NS_MONITORING" --context="$CLUSTER1_CONTEXT" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "$GRAFANA_IP" ]; then break; fi
  echo "  Waiting for Grafana IP..."
  sleep 10
done

# ─── Step 7: Update Singapore remote_write with Mumbai Prometheus IP ───────────
log_info "Getting Mumbai Prometheus internal IP..."

MUMBAI_PROM_IP=$(kubectl get svc kube-prometheus-stack-prometheus \
  -n "$NS_MONITORING" --context="$CLUSTER1_CONTEXT" \
  -o jsonpath='{.spec.clusterIP}')

log_info "Updating Singapore remote_write URL: http://${MUMBAI_PROM_IP}:9090/api/v1/write"

sed -i "s|REPLACE_WITH_MUMBAI_PROMETHEUS_LB_IP|${MUMBAI_PROM_IP}|g" \
  "$PROJECT_ROOT/gitops/monitoring/values-singapore.yaml"

# Re-upgrade Singapore with correct URL
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "$NS_MONITORING" \
  --values "$PROJECT_ROOT/gitops/monitoring/values-singapore.yaml" \
  --kube-context "$CLUSTER2_CONTEXT" \
  --wait \
  --timeout 5m

log_success "Singapore remote_write configured"

# ─── Step 8: Import custom multi-region dashboard ─────────────────────────────
log_info "Creating custom multi-region Grafana dashboard..."

cat > /tmp/multi-region-dashboard.json <<'DASHBOARD'
{
  "title": "Multi-Region Active-Active Overview",
  "uid": "multi-region-001",
  "tags": ["multi-region", "kubernetes"],
  "panels": [
    {
      "title": "Pods Running - Mumbai",
      "type": "stat",
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
      "targets": [{
        "expr": "sum(kube_pod_status_phase{phase='Running',namespace='microservices',cluster='gke-mumbai'})",
        "legendFormat": "Mumbai Pods"
      }]
    },
    {
      "title": "Pods Running - Singapore",
      "type": "stat",
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
      "targets": [{
        "expr": "sum(kube_pod_status_phase{phase='Running',namespace='microservices',cluster='gke-singapore'})",
        "legendFormat": "Singapore Pods"
      }]
    },
    {
      "title": "Node CPU Usage by Cluster",
      "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
      "targets": [{
        "expr": "avg by (cluster) (100 - (rate(node_cpu_seconds_total{mode='idle'}[5m]) * 100))",
        "legendFormat": "{{cluster}}"
      }]
    }
  ],
  "time": {"from": "now-30m", "to": "now"},
  "refresh": "15s"
}
DASHBOARD

log_success "Dashboard JSON created at /tmp/multi-region-dashboard.json"
log_info "Import it via Grafana UI: Dashboards → Import → Upload JSON"

# ─── Step 9: Print Summary ────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Monitoring Setup Complete"
echo "============================================================"
echo " Grafana URL      : http://${GRAFANA_IP}:80"
echo " Grafana Username : admin"
echo " Grafana Password : demo-password-123"
echo ""
echo " Mumbai Prometheus  : port-forward port 9090 on ${CLUSTER1_CONTEXT}"
echo " Singapore Prometheus: port-forward port 9090 on ${CLUSTER2_CONTEXT}"
echo "============================================================"
echo ""
echo " Verify remote_write:"
echo "   kubectl port-forward svc/kube-prometheus-stack-prometheus \\"
echo "     9090:9090 -n monitoring --context=$CLUSTER1_CONTEXT"
echo "   # Open http://localhost:9090/targets"
echo "   # Look for 'remote_write' targets from Singapore"
echo ""
echo "  Next: Run ./scripts/06-setup-glb.sh"
