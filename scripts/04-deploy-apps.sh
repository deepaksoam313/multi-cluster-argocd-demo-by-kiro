#!/bin/bash
# =============================================================================
# Phase 4 & 5: Deploy Microservices via ArgoCD ApplicationSet
# Creates K8s manifests and deploys to both clusters
# Usage: ./scripts/04-deploy-apps.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/env.sh"

SCRIPT_DIR="$(dirname "$0")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log_info "Phase 4 & 5: Deploying microservices via ArgoCD ApplicationSet..."

# ─── Step 1: Create Base Manifests ────────────────────────────────────────────
log_info "Creating base K8s manifests for all services..."

for SVC in order-svc product-svc user-svc; do
  BASE_DIR="$PROJECT_ROOT/manifests/base/$SVC"
  mkdir -p "$BASE_DIR"

  # Extract service display name
  SVC_NAME="${SVC%-svc}"  # order, product, user

  # Deployment
  cat > "$BASE_DIR/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC}
  namespace: microservices
  labels:
    app: ${SVC}
    version: v1
    managed-by: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${SVC}
  template:
    metadata:
      labels:
        app: ${SVC}
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: ${SVC}
          image: hashicorp/http-echo:latest
          args:
            - "-text=REGION_PLACEHOLDER"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "64Mi"
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
EOF

  # Service
  cat > "$BASE_DIR/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: microservices
  labels:
    app: ${SVC}
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
    argocd.argoproj.io/sync-wave: "3"
spec:
  selector:
    app: ${SVC}
  ports:
    - name: http
      port: 80
      targetPort: 8080
  type: ClusterIP
EOF

  # HPA
  cat > "$BASE_DIR/hpa.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${SVC}
  namespace: microservices
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${SVC}
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF

  # Kustomization
  cat > "$BASE_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
EOF

  log_success "  Base manifests created: $SVC"
done

# ─── Step 2: Create Kustomize Overlays ────────────────────────────────────────
log_info "Creating kustomize overlays for Mumbai and Singapore..."

for SVC in order-svc product-svc user-svc; do
  SVC_NAME="${SVC%-svc}"  # order, product, user

  # Mumbai overlay
  MUMBAI_DIR="$PROJECT_ROOT/gitops/apps/$SVC/overlays/mumbai"
  mkdir -p "$MUMBAI_DIR"

  cat > "$MUMBAI_DIR/patch-region.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC}
  namespace: microservices
spec:
  template:
    metadata:
      labels:
        region: asia-south1
        cluster: gke-mumbai
    spec:
      containers:
        - name: ${SVC}
          args:
            - "-text={\"service\":\"${SVC_NAME}\",\"region\":\"asia-south1\",\"cluster\":\"gke-mumbai\",\"status\":\"ok\"}"
            - "-listen=:8080"
EOF

  cat > "$MUMBAI_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: microservices
resources:
  - ../../../../manifests/base/${SVC}
patches:
  - path: patch-region.yaml
commonLabels:
  region: asia-south1
  cluster: gke-mumbai
EOF

  # Singapore overlay
  SINGAPORE_DIR="$PROJECT_ROOT/gitops/apps/$SVC/overlays/singapore"
  mkdir -p "$SINGAPORE_DIR"

  cat > "$SINGAPORE_DIR/patch-region.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC}
  namespace: microservices
spec:
  template:
    metadata:
      labels:
        region: asia-southeast1
        cluster: gke-singapore
    spec:
      containers:
        - name: ${SVC}
          args:
            - "-text={\"service\":\"${SVC_NAME}\",\"region\":\"asia-southeast1\",\"cluster\":\"gke-singapore\",\"status\":\"ok\"}"
            - "-listen=:8080"
EOF

  cat > "$SINGAPORE_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: microservices
resources:
  - ../../../../manifests/base/${SVC}
patches:
  - path: patch-region.yaml
commonLabels:
  region: asia-southeast1
  cluster: gke-singapore
EOF

  log_success "  Overlays created: $SVC (mumbai + singapore)"
done

# ─── Step 3: Create ApplicationSet ────────────────────────────────────────────
log_info "Creating ArgoCD ApplicationSet..."

SINGAPORE_SERVER=$(argocd cluster list -o json | \
  python3 -c "import json,sys; clusters=json.load(sys.stdin); \
  [print(c['server']) for c in clusters if c.get('name','') == '${CLUSTER2_NAME}']" \
  2>/dev/null || echo "")

if [ -z "$SINGAPORE_SERVER" ]; then
  log_warn "Could not auto-detect Singapore server URL. Using placeholder."
  SINGAPORE_SERVER="https://SINGAPORE_API_ENDPOINT"
fi

cat > "$PROJECT_ROOT/gitops/appsets/microservices-appset.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: ${NS_ARGOCD}
spec:
  generators:
    - list:
        elements:
          - cluster: gke-mumbai
            url: https://kubernetes.default.svc
            overlay: mumbai
          - cluster: gke-singapore
            url: ${SINGAPORE_SERVER}
            overlay: singapore
  template:
    metadata:
      name: '{{app}}-{{cluster}}'
      annotations:
        notifications.argoproj.io/subscribe.on-sync-failed.slack: demo-alerts
    spec:
      project: multi-region-demo
      source:
        repoURL: https://github.com/YOUR_ORG/multi-region-demo
        targetRevision: HEAD
        path: 'gitops/apps/{{app}}/overlays/{{overlay}}'
      destination:
        server: '{{url}}'
        namespace: microservices
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true
EOF

log_success "ApplicationSet manifest created"

# ─── Step 4: Apply ApplicationSet ─────────────────────────────────────────────
# Note: For a real setup you'd push to git and let ArgoCD sync.
# For lab purposes we apply per-app directly.

log_info "Deploying services directly to both clusters (lab mode - no git repo)..."

for SVC in order-svc product-svc user-svc; do
  log_info "  Deploying $SVC to Mumbai..."
  kubectl apply -k "$PROJECT_ROOT/gitops/apps/$SVC/overlays/mumbai" \
    --context="$CLUSTER1_CONTEXT"

  log_info "  Deploying $SVC to Singapore..."
  kubectl apply -k "$PROJECT_ROOT/gitops/apps/$SVC/overlays/singapore" \
    --context="$CLUSTER2_CONTEXT"
done

# ─── Step 5: Wait for pods ────────────────────────────────────────────────────
log_info "Waiting for pods to be Running..."

for ctx in "$CLUSTER1_CONTEXT" "$CLUSTER2_CONTEXT"; do
  log_info "  Waiting on context: $ctx"
  kubectl wait --for=condition=available \
    deployment/order-svc deployment/product-svc deployment/user-svc \
    -n "$NS_APPS" \
    --context="$ctx" \
    --timeout=120s
done

# ─── Step 6: Verify ───────────────────────────────────────────────────────────
echo ""
echo "=== Pods on Mumbai ==="
kubectl get pods -n "$NS_APPS" --context="$CLUSTER1_CONTEXT" -o wide

echo ""
echo "=== Pods on Singapore ==="
kubectl get pods -n "$NS_APPS" --context="$CLUSTER2_CONTEXT" -o wide

echo ""
echo "=== Services on Mumbai ==="
kubectl get svc -n "$NS_APPS" --context="$CLUSTER1_CONTEXT"

# ─── Step 7: Quick Functional Test ────────────────────────────────────────────
log_info "Quick functional test via port-forward..."

kubectl port-forward svc/order-svc 18080:80 \
  -n "$NS_APPS" --context="$CLUSTER1_CONTEXT" &
PF_PID=$!
sleep 3

RESPONSE=$(curl -s http://localhost:18080 2>/dev/null || echo "failed")
kill $PF_PID 2>/dev/null || true

echo ""
log_success "Mumbai order-svc response: $RESPONSE"

echo ""
log_success "Phase 4 & 5 complete! All services deployed to both clusters."
echo ""
echo "  Next: Run ./scripts/05-setup-monitoring.sh"
