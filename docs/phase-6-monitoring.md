# Phase 6: Prometheus + Grafana Monitoring

## What Are We Doing in This Phase?

We are deploying a **unified monitoring stack** across both clusters:

- **Prometheus** on each cluster — collects metrics locally
- **Grafana** on Cluster 1 only — single dashboard showing BOTH clusters
- Singapore Prometheus **remote_writes** metrics to Mumbai Prometheus
- Result: one Grafana showing metrics from all regions simultaneously

By the end of this phase you can open one URL and see CPU, memory,
pod counts, and request rates from both Mumbai and Singapore side-by-side.

---

## Why Do We Need Monitoring in Multi-Region?

In a single-cluster setup, debugging is relatively straightforward:
`kubectl logs` and `kubectl describe` usually tell you what went wrong.

In a multi-cluster setup, problems become harder to spot:
- A cluster in Singapore might have pods crashlooping — do you know?
- Traffic from Mumbai might be double the normal rate — is that a failover?
- A node in Singapore is at 90% memory — before or after it causes evictions?

Without centralized monitoring, you would need to manually check each
cluster separately. With it, anomalies stand out immediately on one screen.

---

## Monitoring Architecture Explained

```
┌───────────────────────────────────┐    ┌───────────────────────────────┐
│  Cluster 1: gke-mumbai            │    │  Cluster 2: gke-singapore     │
│                                   │    │                               │
│  ┌──────────────────────────┐     │    │  ┌──────────────────────┐    │
│  │  Prometheus (Mumbai)     │     │    │  │  Prometheus (SG)     │    │
│  │  - scrapes pods          │     │    │  │  - scrapes pods      │    │
│  │  - scrapes nodes         │     │    │  │  - scrapes nodes     │    │
│  │  - scrapes k8s API       │     │    │  │  - scrapes k8s API   │    │
│  │  - stores 24h locally    │     │    │  │  - stores 6h locally │    │
│  │  - receives remote_write │◄────┼────┼──┤  - remote_writes to  │    │
│  └──────────┬───────────────┘     │    │  │    Mumbai Prometheus  │    │
│             │                     │    │  └──────────────────────┘    │
│             │ datasource          │    │                               │
│             ▼                     │    │  node-exporter (per node)    │
│  ┌──────────────────────────┐     │    │  kube-state-metrics          │
│  │  Grafana                 │     │    └───────────────────────────────┘
│  │  - queries Prometheus    │     │
│  │  - shows both clusters   │     │    node-exporter (per node)
│  │  - dashboards, alerts    │     │    kube-state-metrics
│  └──────────────────────────┘     │
└───────────────────────────────────┘
```

### Why Not Thanos?

**Thanos** is the production-grade multi-cluster metrics solution:
- Stores metrics in GCS/S3 indefinitely (Prometheus stores in-memory/disk, short-term)
- Global query layer that federates across clusters with deduplication
- Handles high cardinality much better than remote_write

**Why we use remote_write instead:**
- Thanos requires: sidecar per Prometheus + object storage + query frontend + compactor
- That is 5+ additional components to configure and debug
- For a 2-cluster lab lasting hours, remote_write is entirely sufficient
- remote_write teaches the same concept (centralized metrics) with 1/5th the complexity

For a production setup with 3+ clusters or long-term metrics retention,
switch to Thanos (or Google Cloud Managed Prometheus which handles this automatically).

---

## What is Prometheus?

Prometheus is an **open-source metrics and alerting toolkit** that:

1. **Scrapes** HTTP endpoints that expose metrics in a specific text format
2. **Stores** metrics as time-series data (metric name + labels + value + timestamp)
3. **Evaluates** alerting rules and fires alerts via Alertmanager
4. **Exposes** a query API using **PromQL** (Prometheus Query Language)

### The Scrape Model (Pull, not Push)

Most monitoring systems use a push model (apps send metrics to a collector).
Prometheus uses **pull** — Prometheus reaches out to each target and reads its metrics.

```
Push model (Datadog, Splunk):        Pull model (Prometheus):
──────────────────────────           ──────────────────────────
App ──pushes──► Collector            Prometheus ──scrapes──► App
App ──pushes──► Collector            Prometheus ──scrapes──► App
App ──pushes──► Collector            Prometheus ──scrapes──► App
```

Pull model benefits:
- Prometheus knows which targets are down (no data = down)
- Easier to debug: you can `curl http://pod:8080/metrics` to see what Prometheus sees
- No credentials needed on the app side

### How Kubernetes Service Discovery Works

Prometheus uses Kubernetes API to automatically discover pods to scrape.
We tell it "scrape all pods with these annotations":

```yaml
annotations:
  prometheus.io/scrape: "true"    ← include this pod
  prometheus.io/port: "8080"      ← scrape this port
  prometheus.io/path: "/"         ← scrape this path
```

Prometheus continuously polls the K8s API for pod updates.
When a new pod starts, it is automatically scraped within seconds.
When a pod dies, Prometheus stops trying to scrape it.

### What Metrics Does Prometheus Collect?

From our setup, Prometheus collects:

**From microservice pods** (via annotations):
- `up{pod="order-svc-xxx"}` → 1 if pod is up, 0 if down
- Basic HTTP metrics (request count, duration histogram if app exposes them)

**From kube-state-metrics**:
- `kube_deployment_status_replicas_available` → running replicas per deployment
- `kube_pod_status_phase` → pod lifecycle phase (Running/Pending/Failed)
- `kube_node_status_condition` → node health
- `kube_hpa_status_current_replicas` → current HPA replica count

**From node-exporter** (runs on every node as a DaemonSet):
- `node_cpu_seconds_total` → CPU usage by mode (idle/user/system)
- `node_memory_MemAvailable_bytes` → available memory
- `node_filesystem_avail_bytes` → disk space
- `node_network_transmit_bytes_total` → network I/O

---

## What is kube-state-metrics?

`kube-state-metrics` is a Kubernetes add-on that **listens to the Kubernetes API**
and exposes object state as Prometheus metrics.

Without it, Prometheus can only scrape pod endpoints.
With it, Prometheus gets metrics about K8s objects themselves:

```
Without kube-state-metrics:
  "Is pod X up?" → yes/no

With kube-state-metrics:
  "How many desired replicas does deployment X have?" → 2
  "How many available replicas?" → 1     (one pod is crashing!)
  "What is the pod's restart count?" → 47
  "Is the node schedulable?" → false     (it was cordoned)
  "What image is the deployment using?" → hashicorp/http-echo:latest
```

---

## What is node-exporter?

`node-exporter` runs as a **DaemonSet** (one pod per node) and exposes
Linux system metrics to Prometheus:

- CPU usage, idle time, I/O wait
- Memory: total, free, cached, buffers
- Disk: space used, I/O operations, latency
- Network: bytes sent/received, errors, dropped packets
- Filesystem: mounts, inodes

It gives you the "server health" view on top of K8s object health.

---

## What is remote_write?

`remote_write` is a Prometheus feature where one Prometheus instance
**forwards its metrics** to another Prometheus instance's write endpoint.

```
Singapore Prometheus:
  - collects metrics locally (pods, nodes, K8s objects)
  - at the same time, forwards every sample to:
    http://<mumbai-prometheus>:9090/api/v1/write

Mumbai Prometheus:
  - collects its own local metrics
  - also receives Singapore's metrics via remote_write receiver
  - stores ALL metrics with cluster/region labels to distinguish them
```

### Why not just query both Prometheus instances from Grafana?

You could add two Prometheus datasources to Grafana (Mumbai + Singapore)
and query each separately. The problem:
- You cannot write a single PromQL query comparing both regions
- `sum by (cluster) (rate(...))` would not work across datasources
- Dashboard panels need to be duplicated per region

With remote_write into a single Prometheus:
- All metrics are in one place
- Single PromQL query: `sum by (cluster) (rate(...))` works perfectly
- One panel shows both regions with a `{cluster}` legend

### external_labels — how we distinguish sources

When Singapore Prometheus sends data to Mumbai, every metric gets
these labels automatically appended:

```yaml
externalLabels:
  cluster: gke-singapore
  region: asia-southeast1
```

So in Mumbai's Prometheus, you see:
```
up{cluster="gke-mumbai", pod="order-svc-x"}     ← from Mumbai
up{cluster="gke-singapore", pod="order-svc-y"}  ← from Singapore via remote_write
```

This is how you filter per region in Grafana.

---

## The kube-prometheus-stack Helm Chart

We use `prometheus-community/kube-prometheus-stack` — a Helm chart that bundles:

| Component | Description |
|-----------|-------------|
| Prometheus Operator | CRD-based management of Prometheus instances |
| Prometheus | Metrics collection |
| Alertmanager | Alert routing and silencing |
| Grafana | Visualization |
| kube-state-metrics | K8s object metrics |
| node-exporter | Node-level metrics |
| Pre-built rules | AlertRules for K8s cluster health |
| Pre-built dashboards | Grafana dashboards auto-imported |

The "Operator" pattern means you configure Prometheus via CRDs
(`ServiceMonitor`, `PrometheusRule`) instead of editing config files.

### Why Helm for monitoring but Kustomize for apps?

- kube-prometheus-stack has **200+ configuration values** — Helm's parameterized
  templating handles this elegantly
- Our simple http-echo services have ~5 things that differ between regions —
  Kustomize's patch approach is cleaner for that
- Right tool for the right job

---

## Key PromQL Queries for Multi-Region Visibility

PromQL (Prometheus Query Language) is used in Grafana panels.

### Pod availability per cluster:
```promql
sum by (cluster) (
  kube_deployment_status_replicas_available{namespace="microservices"}
)
```
Shows: `gke-mumbai → 6`, `gke-singapore → 6` (or 0 when failed)

### CPU usage per cluster:
```promql
avg by (cluster) (
  100 - (rate(node_cpu_seconds_total{mode="idle"}[5m]) * 100)
)
```

### Memory usage per cluster:
```promql
avg by (cluster) (
  1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
) * 100
```

### "Is Singapore down?":
```promql
sum(kube_pod_status_phase{
  phase="Running",
  namespace="microservices",
  cluster="gke-singapore"
}) == 0
```
Returns a result (value 0) only during failure simulation — easy to alert on.

---

## Grafana Dashboards We Use

| Dashboard | Import ID | What it shows |
|-----------|-----------|--------------|
| Kubernetes Cluster Overview | 7249 | Node CPU, memory, pod counts by cluster |
| Node Exporter Full | 1860 | Detailed per-node OS metrics |
| Kubernetes Pod Overview | 6417 | Per-pod resource usage |
| Custom Multi-Region | (our own) | Side-by-side Mumbai vs Singapore comparison |

To import a dashboard:
1. Open Grafana UI
2. Left sidebar → Dashboards → Import
3. Enter the Grafana.com dashboard ID (e.g. 7249)
4. Select datasource → Import

---

## Step-by-Step: What the Script Does

`scripts/05-setup-monitoring.sh`:

```
Step 1: Add prometheus-community Helm repo
Step 2: Create Helm values file for Mumbai
        └── Grafana enabled (admin password: demo-password-123)
        └── enableRemoteWriteReceiver: true  ← accepts Singapore's metrics
        └── externalLabels: cluster=gke-mumbai
Step 3: Create Helm values file for Singapore
        └── Grafana disabled (save resources)
        └── remoteWrite URL: http://<mumbai-prometheus>:9090/api/v1/write
        └── externalLabels: cluster=gke-singapore
Step 4: helm upgrade --install on Mumbai context
        └── Creates ~30 K8s resources in monitoring namespace
Step 5: helm upgrade --install on Singapore context
Step 6: Get Grafana LoadBalancer IP
Step 7: Get Mumbai Prometheus internal ClusterIP
        └── Update Singapore values with real Prometheus IP
        └── Re-run helm upgrade --install on Singapore with correct URL
Step 8: Print access URLs and credentials
```

---

## Executing Phase 6

```bash
cd /home/deepak.kumar30/multi-region-demo
./scripts/05-setup-monitoring.sh
```

Expected time: **8-12 minutes** (Prometheus pods take time to stabilize)

---

## Verification Commands

```bash
# Check monitoring pods on Mumbai
kubectl get pods -n monitoring --context=gke-mumbai

# Expected Running pods:
# alertmanager-kube-prometheus-stack-xxx
# kube-prometheus-stack-grafana-xxx
# kube-prometheus-stack-kube-state-metrics-xxx
# kube-prometheus-stack-operator-xxx
# kube-prometheus-stack-prometheus-node-exporter-xxx (one per node)
# prometheus-kube-prometheus-stack-prometheus-0

# Check monitoring pods on Singapore (no Grafana)
kubectl get pods -n monitoring --context=gke-singapore

# Get Grafana IP
kubectl get svc kube-prometheus-stack-grafana \
  -n monitoring --context=gke-mumbai

# Port-forward to Prometheus UI (Mumbai)
kubectl port-forward svc/prometheus-operated \
  9090:9090 -n monitoring --context=gke-mumbai &
# Open http://localhost:9090
# Go to Status > Targets — should show all scrape targets as UP
# Go to Status > Configuration — shows remote_write receiver config

# Verify Singapore metrics appear in Mumbai Prometheus
# In Prometheus UI, query: up{cluster="gke-singapore"}
# Should return results from Singapore

# Port-forward to Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana \
  3000:80 -n monitoring --context=gke-mumbai &
# Open http://localhost:3000
# Username: admin  Password: demo-password-123
```

---

## What to Look for in Grafana After Setup

Navigate to Dashboards → Kubernetes Cluster Overview (ID 7249):

1. **Node count** — should show 2 nodes for each cluster
2. **CPU usage** — relatively low at rest (~10-20%)
3. **Memory usage** — somewhat higher due to Prometheus (~40-60%)
4. **Pod count** — 6 microservice pods + monitoring pods per cluster

Check the cluster selector dropdown at the top of the dashboard — it should
show both `gke-mumbai` and `gke-singapore` as options.

---

## Real-World Notes from This Lab

### 1. CPU requests vs actual usage
The full kube-prometheus-stack defaults request ~500m CPU per node.
With ArgoCD already consuming ~900m on e2-medium nodes (940m allocatable),
we reduced all CPU requests to 5-50m. http-echo and monitoring components
use far less CPU than their defaults — right-size based on `kubectl top pods`.

### 2. Dashboard download init container
Grafana's `download-dashboards` init container fetches dashboard JSONs from
grafana.com on startup. This failed because outbound HTTPS to grafana.com
was blocked in this environment. Fix: disabled the `dashboards:` section in
Helm values and imported dashboards via the Grafana HTTP API instead.

### 3. remote_write needs external IP
`prometheus-operated` is a headless service (ClusterIP: None) — not usable
for cross-cluster traffic. `kube-prometheus-stack-prometheus` is ClusterIP
only. We patched it to LoadBalancer to get a GCP external IP for Singapore
to write to.

---

## Actual Deployment Values (Phase 6 Completed)

| Item | Value |
|------|-------|
| Grafana URL | `http://34.93.126.133` |
| Grafana username | `admin` |
| Grafana password | `demo-password-123` |
| Mumbai Prometheus external IP | `8.234.93.217` |
| Singapore remote_write URL | `http://8.234.93.217:9090/api/v1/write` |
| Helm chart | `kube-prometheus-stack-92.3.0.tgz` |
| Dashboards pre-installed | 31 (including Multi-Cluster) |
| Custom dashboard | `/d/multi-region-001/multi-region-active-active-overview` |
| Singapore metrics in Mumbai | ✅ 13 series confirmed |

### Key Grafana Dashboards to Use

| Dashboard | URL path | Best for |
|-----------|----------|---------|
| Multi-Region Active-Active | `/d/multi-region-001/` | Failover observation |
| K8s Compute Resources Multi-Cluster | `/d/b59e6c9f.../kubernetes-compute-resources-multi-cluster` | Resource usage |
| Node Exporter Full | `/d/rYdddlPWk/node-exporter-full` | Node-level metrics |
| Kubernetes Cluster | `/d/os6Bh8Omk/kubernetes-cluster` | Overall cluster health |

### Quick Resume Commands
```bash
# Refresh credentials if connectivity lost
gcloud container clusters get-credentials gke-mumbai --zone=asia-south1-a --project=skilled-text-468416-g3
gcloud container clusters get-credentials gke-singapore --zone=asia-southeast1-a --project=skilled-text-468416-g3

# Check monitoring pods
kubectl get pods -n monitoring --context=gke-mumbai
kubectl get pods -n monitoring --context=gke-singapore

# Verify remote_write flowing (should show Singapore series)
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring --context=gke-mumbai &
curl -s "http://localhost:9090/api/v1/query?query=up{cluster=\"gke-singapore\"}" | python3 -m json.tool | grep cluster
```

---

## Summary

✅ kube-prometheus-stack installed on both clusters (chart v92.3.0)  
✅ kube-state-metrics and node-exporter running on both clusters  
✅ Grafana live at http://34.93.126.133 — 31 dashboards pre-installed  
✅ Singapore Prometheus remote_writes to Mumbai (http://8.234.93.217:9090)  
✅ 13 Singapore metric series confirmed in Mumbai Prometheus  
✅ Custom multi-region dashboard created (pod count + CPU + replicas by cluster)  
✅ Kubernetes Multi-Cluster dashboard available out of the box  

**Next → Phase 7: GCP Global HTTP Load Balancer**
