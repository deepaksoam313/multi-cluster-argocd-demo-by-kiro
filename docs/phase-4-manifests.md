# Phase 4: Kubernetes Manifests for the Microservices

## What Are We Doing in This Phase?

We are writing the **Kubernetes manifests** — the YAML files that describe
our three microservices — and structuring them using **Kustomize overlays**
so the same base definition can be deployed differently to each region.

By the end of this phase:
- Base manifests exist for `order-svc`, `product-svc`, `user-svc`
- Each service has a Mumbai overlay and a Singapore overlay
- The overlays patch region-specific values (response text, labels)
- All files are in the `gitops/` and `manifests/` directories
- ArgoCD can read these files and apply them to clusters

---

## Why hashicorp/http-echo?

Our goal in this lab is NOT to learn application development.
Our goal is to learn **multi-cluster infrastructure, GitOps, and monitoring**.

`hashicorp/http-echo` is perfect for this because:
- It is a **single-binary** HTTP server (~3MB container image)
- Zero dependencies — no database, no config files, no secrets
- Responds to every GET request with a string you configure at startup
- Healthy by default — responds 200 OK to `/`
- Exposes metrics-compatible endpoint for Prometheus scraping simulation

```
Without http-echo approach:          With http-echo approach:
──────────────────────────           ────────────────────────
Write app in Go/Python/Node          Zero app code
Write Dockerfile                     Use public image
Build image                          Skip build step
Push to registry                     Skip push step
Debug app bugs                       No app bugs possible
                                     
Focus: app code bugs                 Focus: infrastructure ✅
```

### How it works:

```bash
# Start http-echo responding with a JSON string
docker run -p 8080:8080 hashicorp/http-echo \
  -text='{"service":"order","region":"asia-south1"}' \
  -listen=:8080

# Every GET request returns:
curl http://localhost:8080
{"service":"order","region":"asia-south1"}
```

In Kubernetes, we pass these as `args` in the container spec — one arg
changes per region via a Kustomize patch.

---

## What is Kustomize?

Kustomize is a **template-free** configuration customization tool for Kubernetes.
It is built into `kubectl` (since v1.14) — no extra install needed.

### The Problem it Solves

Imagine you have 3 services and 2 environments (regions).
Without a tool, you'd maintain:

```
Mumbai:
  order-svc-mumbai-deployment.yaml
  product-svc-mumbai-deployment.yaml
  user-svc-mumbai-deployment.yaml

Singapore:
  order-svc-singapore-deployment.yaml
  product-svc-singapore-deployment.yaml
  user-svc-singapore-deployment.yaml
```

6 files that are 90% identical. When you change the image version,
you edit 6 files. When you add a new label, 6 files. Error-prone.

### Kustomize's Solution: Base + Overlays

```
manifests/base/order-svc/         ← shared definition (one file)
gitops/apps/order-svc/overlays/
  mumbai/                         ← only what differs for Mumbai
  singapore/                      ← only what differs for Singapore
```

Kustomize **merges** the overlay into the base at apply time:

```
Base deployment.yaml              +  Mumbai patch.yaml
──────────────────────               ──────────────────
name: order-svc                      args: [-text, {"region":"asia-south1"}]
image: hashicorp/http-echo           labels: {region: asia-south1}
replicas: 2
ports: 8080
resources: ...
probes: ...

= Final applied manifest for Mumbai (in memory, never written to disk)
```

### Kustomize vs Helm

| Feature | Kustomize | Helm |
|---------|-----------|------|
| Templating syntax | None — pure YAML patches | Go templates `{{ .Values.x }}` |
| Learning curve | Low | Medium-High |
| Debugging | Easy — `kubectl kustomize` shows final YAML | Harder — `helm template` needed |
| Built into kubectl | Yes | No (separate install) |
| Good for | Config overlays, environment differences | Complex apps with many parameters |
| Our use case | ✅ Perfect fit | Overkill for http-echo |

Helm IS used in Phase 6 for Prometheus (because kube-prometheus-stack is
a complex chart with hundreds of parameters — that's where Helm shines).

---

## Directory Structure Explained

```
multi-region-demo/
│
├── manifests/
│   └── base/
│       ├── order-svc/
│       │   ├── deployment.yaml      ← K8s Deployment resource
│       │   ├── service.yaml         ← K8s Service resource
│       │   ├── hpa.yaml             ← HorizontalPodAutoscaler
│       │   └── kustomization.yaml   ← Kustomize entry point
│       ├── product-svc/   (same structure)
│       └── user-svc/      (same structure)
│
└── gitops/
    └── apps/
        ├── order-svc/
        │   └── overlays/
        │       ├── mumbai/
        │       │   ├── patch-region.yaml    ← patches args + labels
        │       │   └── kustomization.yaml   ← references base + patches
        │       └── singapore/
        │           ├── patch-region.yaml
        │           └── kustomization.yaml
        ├── product-svc/  (same structure)
        └── user-svc/     (same structure)
```

The split between `manifests/base/` and `gitops/apps/` is intentional:
- `manifests/base/` = pure K8s definitions (no GitOps concepts)
- `gitops/apps/` = ArgoCD-specific overlays pointing at the base

This makes the base reusable even if you swap ArgoCD for something else.

---

## Deep Dive: Each Manifest File

### deployment.yaml (Base)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-svc
  namespace: microservices
  labels:
    app: order-svc
    version: v1
    managed-by: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"    ← deploy after namespace/configmaps
spec:
  replicas: 2                             ← 2 pods = basic redundancy
  selector:
    matchLabels:
      app: order-svc                      ← must match pod template labels
  template:
    metadata:
      labels:
        app: order-svc
        version: v1
      annotations:
        prometheus.io/scrape: "true"      ← Prometheus auto-discovers this pod
        prometheus.io/port: "8080"
        prometheus.io/path: "/"
    spec:
      containers:
        - name: order-svc
          image: hashicorp/http-echo:latest
          args:
            - "-text=REGION_PLACEHOLDER"  ← overridden by overlay patch
            - "-listen=:8080"
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: "50m"                  ← guaranteed minimum
              memory: "32Mi"
            limits:
              cpu: "200m"                 ← hard maximum
              memory: "64Mi"
          livenessProbe:                  ← K8s restarts pod if this fails
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5        ← wait 5s before first check
            periodSeconds: 10             ← check every 10s
          readinessProbe:                 ← K8s removes pod from LB if this fails
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
```

#### Why `resources.requests` and `resources.limits`?

**Without requests**: Kubernetes does not know how much CPU/memory a pod needs,
so it cannot make smart scheduling decisions. Pods may land on overloaded nodes.

**Without limits**: One misbehaving pod can consume all node resources,
starving all other pods on the same node.

```
requests = "I need at least this much"
limits   = "I must never use more than this"

K8s scheduler uses requests to fit pods onto nodes.
K8s kubelet enforces limits using Linux cgroups.
```

#### Why `livenessProbe` and `readinessProbe`?

**livenessProbe**: "Is this pod alive?"
- If it fails: K8s KILLS the pod and creates a new one
- Use for: detecting deadlocks, infinite loops, corrupted state

**readinessProbe**: "Is this pod ready to receive traffic?"
- If it fails: K8s REMOVES the pod from Service endpoints (no traffic)
- Pod is NOT killed — just taken out of rotation
- Use for: app still initializing, temporarily overloaded

```
New pod starts:
  readiness fails for 3s (still starting)
  K8s: do NOT send traffic to this pod yet
  readiness passes at t=3s
  K8s: add this pod to Service endpoints → traffic flows
```

#### Why `sync-wave: "2"`?

ArgoCD sync waves control deployment order within a sync operation:
- Wave 0: Namespaces, CRDs (must exist before anything else)
- Wave 1: ConfigMaps, Secrets (needed by pods)
- Wave 2: Deployments (our services)
- Wave 3: Services (expose deployments)
- Wave 4: HPAs (scale deployments)

Without sync waves, ArgoCD might try to create a Service before its
Deployment exists, or an HPA before its target Deployment.

---

### service.yaml (Base)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: order-svc
  namespace: microservices
  annotations:
    cloud.google.com/neg: '{"ingress": true}'   ← creates NEG for GLB (Phase 7)
    argocd.argoproj.io/sync-wave: "3"
spec:
  selector:
    app: order-svc           ← routes to pods with this label
  ports:
    - name: http
      port: 80               ← port on the Service (cluster-internal)
      targetPort: 8080       ← port on the Pod container
  type: ClusterIP            ← not exposed externally; GLB handles that
```

#### Why `ClusterIP` not `LoadBalancer`?

`LoadBalancer` creates a GCP Network Load Balancer per service = 3 LBs per cluster
= 6 LBs total. Expensive and not needed.

We use `ClusterIP` (internal only) and let the single **Global HTTP Load Balancer**
(Phase 7) handle all external traffic routing. The GLB connects directly to pods
via Network Endpoint Groups (NEGs), bypassing the Service entirely for
external traffic.

#### The NEG Annotation

```yaml
cloud.google.com/neg: '{"ingress": true}'
```

This tells GKE to automatically create a **Network Endpoint Group** for this
Service. A NEG is a collection of pod IPs and ports registered directly with
GCP's load balancing layer.

```
Without NEG (old way):          With NEG (container-native):
────────────────────            ──────────────────────────────
GLB → Node IP:NodePort          GLB → Pod IP:Port directly
     → kube-proxy               No kube-proxy hop
     → Pod                      Faster, better health checks
```

GKE auto-creates and auto-populates the NEG as pods scale up/down.

---

### hpa.yaml (Base)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-svc
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-svc
  minReplicas: 2             ← never go below 2 (high availability)
  maxReplicas: 5             ← never exceed 5 (cost control)
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  ← scale up if avg CPU > 70%
```

The HPA continuously polls the metrics-server for pod CPU usage.
If all pods average >70% CPU, it adds a replica (up to maxReplicas).
If usage drops, it removes replicas (down to minReplicas).

In our lab:
- Normal load: 2 replicas each cluster
- During failover simulation (Phase 8): when Singapore's traffic shifts
  to Mumbai, Mumbai pods get more load, HPA may scale to 3-4 replicas

---

### Kustomize Overlay: patch-region.yaml (Mumbai)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-svc          ← must match the base resource name
  namespace: microservices
spec:
  template:
    metadata:
      labels:
        region: asia-south1     ← added to pod labels (for Prometheus)
        cluster: gke-mumbai
    spec:
      containers:
        - name: order-svc       ← must match container name in base
          args:
            - "-text={\"service\":\"order\",\"region\":\"asia-south1\",\"cluster\":\"gke-mumbai\",\"status\":\"ok\"}"
            - "-listen=:8080"
```

This patch:
1. Overrides the `args` to set a Mumbai-specific response text
2. Adds `region` and `cluster` labels to pods (used by Prometheus queries)

Kustomize does a **strategic merge** — it does not replace the whole
deployment spec, just the fields you specify in the patch.

---

## How to Preview the Final Manifest

Before applying, you can see exactly what Kustomize will generate:

```bash
# Preview Mumbai order-svc final manifest
kubectl kustomize gitops/apps/order-svc/overlays/mumbai

# Preview Singapore order-svc final manifest
kubectl kustomize gitops/apps/order-svc/overlays/singapore
```

This shows the merged YAML without applying anything.
Useful for debugging and understanding.

---

## Step-by-Step: What the Script Does

`scripts/04-deploy-apps.sh` does:

```
Step 1: For each of the 3 services:
   └── Create manifests/base/<svc>/deployment.yaml
   └── Create manifests/base/<svc>/service.yaml
   └── Create manifests/base/<svc>/hpa.yaml
   └── Create manifests/base/<svc>/kustomization.yaml

Step 2: For each service × each region:
   └── Create gitops/apps/<svc>/overlays/mumbai/patch-region.yaml
   └── Create gitops/apps/<svc>/overlays/mumbai/kustomization.yaml
   └── Create gitops/apps/<svc>/overlays/singapore/patch-region.yaml
   └── Create gitops/apps/<svc>/overlays/singapore/kustomization.yaml

Step 3: Create the ApplicationSet manifest (gitops/appsets/)
   └── Used in Phase 5 if you push to a real git repo

Step 4: (Lab mode) Apply directly with kubectl kustomize
   └── kubectl apply -k gitops/apps/order-svc/overlays/mumbai
   └── kubectl apply -k gitops/apps/order-svc/overlays/singapore
   └── (repeated for product-svc and user-svc)

Step 5: Wait for all Deployments to be Available

Step 6: Port-forward and test one service to confirm response
```

> **Note on lab mode vs production mode**:
> In a real setup, you push these manifests to a Git repository and ArgoCD
> syncs them automatically. For this lab, we use `kubectl apply -k` directly
> to avoid needing a git remote. The manifests structure is identical either way.

---

## Executing Phase 4

```bash
cd /home/deepak.kumar30/multi-region-demo
./scripts/04-deploy-apps.sh
```

Expected time: **3-5 minutes**

---

## Verification Commands

```bash
# List all pods on Mumbai
kubectl get pods -n microservices --context=gke-mumbai -o wide

# List all pods on Singapore
kubectl get pods -n microservices --context=gke-singapore -o wide

# Expected on each cluster:
# NAME                           READY   STATUS    NODE
# order-svc-xxx-yyy              1/1     Running   ...
# order-svc-xxx-zzz              1/1     Running   ...
# product-svc-xxx-yyy            1/1     Running   ...
# product-svc-xxx-zzz            1/1     Running   ...
# user-svc-xxx-yyy               1/1     Running   ...
# user-svc-xxx-zzz               1/1     Running   ...
# Total: 6 pods per cluster, 12 pods total

# Preview what Kustomize generates for Singapore
kubectl kustomize gitops/apps/order-svc/overlays/singapore

# Test Mumbai order-svc response
kubectl port-forward svc/order-svc 18080:80 \
  -n microservices --context=gke-mumbai &
curl http://localhost:18080
# Expected: {"service":"order","region":"asia-south1","cluster":"gke-mumbai","status":"ok"}

# Check HPAs
kubectl get hpa -n microservices --context=gke-mumbai
kubectl get hpa -n microservices --context=gke-singapore
```

---

## Real-World Note: CPU Requests on Shared Nodes

During this lab, the initial CPU request of `50m` per pod caused scheduling
failures on Mumbai nodes because ArgoCD already consumes ~900m of the 940m
allocatable CPU per node.

**Fix applied**: Reduced requests to `10m` / limits `50m` for all services.
http-echo uses <5m CPU in practice — the request is purely for scheduling.

In production, size CPU requests based on actual profiled usage, not guesses.
Use `kubectl top pods` after running load to right-size.

---

## Actual Deployment Values (Phase 4 Completed)

| Item | Value |
|------|-------|
| Mumbai pods | 6/6 Running (2 per service) |
| Singapore pods | 6/6 Running (2 per service) |
| CPU request per pod | 10m (reduced from 50m due to ArgoCD co-tenancy) |
| CPU limit per pod | 50m |
| Kustomize path fix | 5 levels up (`../../../../../`) not 4 |
| Verification method | Pod logs + jsonpath args inspection |

### Verified Singapore response (from pod args + readiness probe logs):
```
order-svc:   {"service":"order","region":"asia-southeast1","cluster":"gke-singapore","status":"ok"}
product-svc: {"service":"product","region":"asia-southeast1","cluster":"gke-singapore","status":"ok"}
user-svc:    {"service":"user","region":"asia-southeast1","cluster":"gke-singapore","status":"ok"}
```

### Verified Mumbai response (from direct curl via port-forward):
```
order-svc:   {"service":"order","region":"asia-south1","cluster":"gke-mumbai","status":"ok"}
product-svc: {"service":"product","region":"asia-south1","cluster":"gke-mumbai","status":"ok"}
user-svc:    {"service":"user","region":"asia-south1","cluster":"gke-mumbai","status":"ok"}
```

---

## Summary

✅ Base manifests created for 3 services (Deployment + Service + HPA)  
✅ Kustomize overlays created (mumbai + singapore for each service)  
✅ Region-specific response text confirmed via pod args + probe logs  
✅ Pod labels include `region` and `cluster` for Prometheus filtering  
✅ NEG annotation on Services (ready for GLB in Phase 7)  
✅ All 6 pods Running on Mumbai, 6 on Singapore (12 total)  
✅ HPAs active — CPU at 2-3%, scaling headroom to 5 replicas each  

**Next → Phase 5: ArgoCD ApplicationSet for Multi-Cluster GitOps Deployment**
