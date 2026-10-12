# Multi-Region Active-Active GKE — Complete Lab Guide

> Covers: every command used, why it was run, how to access ArgoCD & Grafana,
> how external IPs are assigned, why the clusters/ folder is empty, Grafana dashboards,
> the full ArgoCD troubleshooting story, hands-on request tracing, and production ArgoCD patterns.

---

## Table of Contents

1. [Access ArgoCD UI](#1-access-argocd-ui)
2. [Access Grafana UI](#2-access-grafana-ui)
3. [How ArgoCD and Grafana Get Their External IP Addresses](#3-how-argocd-and-grafana-get-their-external-ip-addresses)
4. [Why the clusters/ Folder Is Empty](#4-why-the-clusters-folder-is-empty)
5. [Grafana Dashboards — What Exists and How to Use Them](#5-grafana-dashboards--what-exists-and-how-to-use-them)
6. [Why ArgoCD Apps Showed ComparisonError — Full Troubleshooting Story](#6-why-argocd-apps-showed-comparisonerrror--full-troubleshooting-story)
7. [Hands-On: How a Request Travels Across Clusters](#7-hands-on-how-a-request-travels-across-clusters)
8. [Every Command Used — With Why and How](#8-every-command-used--with-why-and-how)
9. [ArgoCD in Production — Cluster or Standalone?](#9-argocd-in-production--cluster-or-standalone)
10. [Quick Reference — Access Everything](#10-quick-reference--access-everything)

---

## 1. Access ArgoCD UI

### URLs and Credentials

| Field    | Value                        |
|----------|------------------------------|
| URL      | http://35.200.130.47         |
| Username | admin                        |
| Password | ISmy5X9fZGkUshXW             |

ArgoCD's `argocd-server` service is exposed as a **LoadBalancer** on the Mumbai cluster.
Port 80 and 443 are both available. Use HTTP to skip the TLS warning in the lab.

### Login from CLI

```bash
cd ~/multi-region-demo
source scripts/env.sh

# Login
argocd login 35.200.130.47 \
  --username admin \
  --password ISmy5X9fZGkUshXW \
  --insecure

# Verify login — list clusters
argocd cluster list

# List all apps
argocd app list
```

### What You Will See in the UI

- **6 Applications**: order-svc, product-svc, user-svc — one per cluster (Mumbai + Singapore)
- **Project**: multi-region-demo
- **Clusters registered**: in-cluster (Mumbai) + gke-singapore
- All apps show Health = **Healthy** but Sync = **Unknown / ComparisonError**
  → See Section 3 for the full explanation and fix.

---


---

## 2. Access Grafana UI

Grafana runs only on the Mumbai cluster (by design — unified view of both regions).

### URLs and Credentials

| Field    | Value              |
|----------|--------------------|
| URL      | http://34.93.126.133 |
| Username | admin              |
| Password | demo-password-123  |

Prometheus (raw metrics browser) is also exposed:

| Field    | Value              |
|----------|--------------------|
| URL      | http://8.234.93.217:9090 |

### CLI port-forward alternative (if LB is slow)

```bash
source ~/multi-region-demo/scripts/env.sh
kubectl config use-context gke-mumbai

# Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana \
  3000:80 -n monitoring &
# Open: http://localhost:3000

# Prometheus (Mumbai)
kubectl port-forward svc/kube-prometheus-stack-prometheus \
  9090:9090 -n monitoring &
# Open: http://localhost:9090

# Prometheus (Singapore) — on the Singapore cluster
kubectl port-forward svc/kube-prometheus-stack-prometheus \
  9091:9090 -n monitoring --context=gke-singapore &
# Open: http://localhost:9091
```

### Useful PromQL Queries to Try in Grafana

```promql
# Pods running in microservices namespace, split by cluster
sum by (cluster) (
  kube_pod_status_phase{phase="Running", namespace="microservices"}
)

# CPU usage per cluster
avg by (cluster) (
  rate(container_cpu_usage_seconds_total{namespace="microservices"}[5m])
)

# Memory usage per service
sum by (pod, cluster) (
  container_memory_usage_bytes{namespace="microservices"}
)

# HTTP request count (from http-echo prometheus annotations)
rate(http_requests_total{namespace="microservices"}[5m])
```

---


---

## 3. How ArgoCD and Grafana Get Their External IP Addresses

This is one of the most important things to understand about Kubernetes on GCP.
Neither ArgoCD nor Grafana "knows" about IP addresses. The IP comes from GCP
automatically, triggered by a single field in the Kubernetes Service manifest.

### The Chain: Service type → GCP API → Load Balancer → External IP

When you set `type: LoadBalancer` on a Kubernetes Service, this is what happens
step by step:

```
1. You apply/patch the Service with type: LoadBalancer
        ↓
2. GKE's cloud-controller-manager detects the change
   (it runs inside the GKE control plane, watching the K8s API)
        ↓
3. cloud-controller-manager calls the GCP Compute API:
   - Creates a Regional External Load Balancer (L4, TCP)
   - Creates a Target Pool pointing at all nodes in the cluster
   - Reserves a new ephemeral external IP address
   - Creates a Forwarding Rule: ExternalIP:80 → Target Pool
        ↓
4. GCP returns the assigned IP address
        ↓
5. cloud-controller-manager writes it back into the Service:
   status.loadBalancer.ingress[0].ip = "35.200.130.47"
        ↓
6. kubectl get svc shows the EXTERNAL-IP column populated
```

### For ArgoCD specifically

The original ArgoCD install creates `argocd-server` as a `ClusterIP` service
(only reachable inside the cluster). We patched it to `LoadBalancer`:

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'
```

Within ~2 minutes, GCP automatically provisioned:
- A Regional L4 TCP Load Balancer in `asia-south1`
- External IP: `35.200.130.47`
- Target Pool: all 3 Mumbai nodes
- Forwarding Rule: `35.200.130.47:80` and `:443` → nodePort on each node → argocd-server pod

You can verify this directly in GCP:
```bash
gcloud compute forwarding-rules list --project=skilled-text-468416-g3
# Shows: aa3a32f36944a4c7bae98c3adc88181d  asia-south1  35.200.130.47

gcloud compute target-pools list --project=skilled-text-468416-g3
# Shows the pool contains all 3 Mumbai node VMs
```

### For Grafana

Grafana's Helm chart (`values-mumbai.yaml`) was configured with:
```yaml
grafana:
  service:
    type: LoadBalancer
```

When Helm installed the chart, it created the Grafana Service with
`type: LoadBalancer` from the start. GCP provisioned a separate L4 LB:
- External IP: `34.93.126.133`
- Its own Target Pool → Mumbai nodes → nodePort 30447 → Grafana pod port 3000

### For Prometheus

Same pattern — `values-mumbai.yaml` sets `type: LoadBalancer` for Prometheus,
which got IP: `8.234.93.217:9090`.

### IP Types: Ephemeral vs Static

The IPs assigned to ArgoCD and Grafana are **ephemeral** — GCP picked them
automatically from its pool and did not reserve them permanently.

```
Type      | ArgoCD/Grafana IPs              | GLB IP (8.233.61.198)
----------|----------------------------------|----------------------
Ephemeral | Yes — auto-assigned, regional   | No — manually reserved
Scope     | Regional (asia-south1 only)     | Global (Anycast)
Survives  | No — changes if LB is deleted   | Yes — reserved explicitly
Command   | Automatic on type:LoadBalancer  | gcloud compute addresses create
```

The GLB IP (`8.233.61.198`) is different — we explicitly reserved it with:
```bash
gcloud compute addresses create multi-region-lb-ip --global
```

This makes it static, global, and Anycast-capable.

### Traffic Flow Diagram

```
Browser → 35.200.130.47:80 (ArgoCD)
              ↓
   GCP Regional L4 Load Balancer (asia-south1)
              ↓
   Target Pool → Mumbai node VMs (any of the 3)
              ↓
   NodePort 32022 on the chosen node
              ↓
   kube-proxy → argocd-server pod (port 8080)
              ↓
   ArgoCD UI response

Browser → 34.93.126.133:80 (Grafana)
              ↓
   GCP Regional L4 Load Balancer (asia-south1)
              ↓
   Target Pool → Mumbai node VMs
              ↓
   NodePort 30447 → Grafana pod (port 3000)
              ↓
   Grafana UI response
```

### Why L4 not L7 for ArgoCD and Grafana?

GKE's default `type: LoadBalancer` provisions an **L4 (TCP) load balancer** —
it forwards raw TCP connections to nodes. It does not understand HTTP paths,
headers, or TLS termination.

For production you would use an **Ingress** resource instead, which provisions
a GCP L7 HTTP(S) Load Balancer with:
- TLS termination with a managed certificate
- Path-based routing
- HTTP → HTTPS redirect
- A single IP for multiple services

For this lab, separate L4 LBs per service is simpler and sufficient.

---


---

## 4. Why the clusters/ Folder Is Empty

### What the folder is for

```
clusters/
├── cluster-mumbai/      ← empty
└── cluster-singapore/   ← empty
```

The `clusters/` directory was designed to hold **cluster-specific configuration
and reference files** — things like:
- Cluster metadata notes (node specs, region, purpose)
- Cluster-specific ArgoCD App-of-Apps manifests
- kubeconfig references or bootstrap instructions
- Any overrides that don't fit cleanly into Kustomize overlays

### Why it's empty in this lab

The scripts (`01-create-clusters.sh`) created the directories with `mkdir -p`
as placeholders, but the lab never needed to put anything in them because:

1. **Cluster config lives in `scripts/env.sh`** — all cluster names, zones,
   and project IDs are centralized there, not in per-cluster folders.

2. **App manifests use Kustomize overlays** — region-specific configuration
   (like which `args` a pod gets) lives in
   `gitops/apps/<service>/overlays/mumbai/` and `…/singapore/`, not in `clusters/`.

3. **ArgoCD registration is runtime, not file-based** — registering Singapore
   with ArgoCD is done via `argocd cluster add` (or the equivalent Kubernetes
   Secret), not by dropping a YAML file in `clusters/cluster-singapore/`.

### What you could put here (for a more complete setup)

**`clusters/cluster-mumbai/README.md`** — human notes:
```markdown
# gke-mumbai
- Region: asia-south1-a
- Nodes: 3 × e2-medium
- Role: Primary (ArgoCD hub, Grafana)
- ArgoCD server: http://35.200.130.47
- Grafana: http://34.93.126.133
```

**`clusters/cluster-mumbai/argocd-project.yaml`** — the AppProject manifest
so it's tracked in git:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: multi-region-demo
  namespace: argocd
spec:
  sourceRepos: ['*']
  destinations:
    - namespace: '*'
      server: '*'
```

**`clusters/cluster-singapore/cluster-secret.yaml`** — template for the
ArgoCD cluster registration Secret (without the actual token, which is a secret):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-gke-singapore
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: gke-singapore
  server: https://34.143.165.98
  # token: <managed separately via argocd cluster add>
```

In production teams typically do use this folder for cluster bootstrap
manifests, runbooks, and cluster-level ArgoCD resources.

---


---

## 5. Grafana Dashboards — What Exists and How to Use Them

### Access

```
URL:      http://34.93.126.133   (or port-forward: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring --context=gke-mumbai)
Username: admin
Password: demo-password-123
```

### Dashboards Available

Grafana comes with **32 dashboards pre-installed** by the `kube-prometheus-stack`
Helm chart. They are all ready to use — no setup required.

The most useful ones for this lab:

| Dashboard | What it shows | How to find it |
|-----------|---------------|----------------|
| **Multi-Region Active-Active Overview** | Pods running per cluster, CPU by cluster | Search: "Multi-Region" |
| **Kubernetes / Compute Resources / Cluster** | Full cluster CPU, memory, pod count | Search: "Cluster" |
| **Kubernetes / Compute Resources / Namespace (Pods)** | Per-pod CPU/memory in `microservices` namespace | Search: "Namespace (Pods)" |
| **Kubernetes / Compute Resources / Workload** | Per-deployment resource usage | Search: "Workload" |
| **Node Exporter / Nodes** | Node-level CPU, memory, disk, network | Search: "Nodes" |
| **Node Exporter Full** | Very detailed node metrics | Search: "Node Exporter Full" |
| **Kubernetes / Networking / Cluster** | Network traffic across the cluster | Search: "Networking" |
| **Alertmanager / Overview** | Active alerts | Search: "Alertmanager" |
| **Prometheus / Overview** | Prometheus's own health, scrape stats | Search: "Prometheus" |

### The Custom Multi-Region Dashboard

The `05-setup-monitoring.sh` script created a custom dashboard specifically
for this lab: **"Multi-Region Active-Active Overview"** (uid: `multi-region-001`).

It was imported via the Grafana provisioning mechanism in `values-mumbai.yaml`
and shows:
- Pods Running in Mumbai
- Pods Running in Singapore
- Node CPU usage by cluster (using the `cluster` label on metrics)

### Why the cluster label matters

Every metric from both clusters has a `cluster` label attached:
- Metrics from Mumbai → `cluster="gke-mumbai"`
- Metrics from Singapore → `cluster="gke-singapore"`

This is set in `values-mumbai.yaml`:
```yaml
prometheus:
  prometheusSpec:
    externalLabels:
      cluster: gke-mumbai
```

And in `values-singapore.yaml`:
```yaml
prometheus:
  prometheusSpec:
    externalLabels:
      cluster: gke-singapore
```

Singapore's Prometheus ships all its metrics to Mumbai via `remote_write`.
So Mumbai's Prometheus holds metrics from both clusters, each labelled
differently. In Grafana you can split or filter by cluster in any query.

### Hands-On Grafana Exploration

**Step 1 — Open the multi-region dashboard:**
1. Go to `http://34.93.126.133`
2. Login: admin / demo-password-123
3. Click the grid icon (Dashboards) → Browse
4. Search "Multi-Region" → click the dashboard

**Step 2 — Try PromQL queries in Explore:**
1. Click the compass icon (Explore) in the left sidebar
2. Make sure datasource is "Prometheus-Mumbai"
3. Try these queries:

```promql
# Pods running per cluster in the microservices namespace
sum by (cluster) (
  kube_pod_status_phase{phase="Running", namespace="microservices"}
)

# CPU usage per cluster (rolling 5m average)
avg by (cluster) (
  rate(container_cpu_usage_seconds_total{namespace="microservices"}[5m])
)

# Memory per service per cluster
sum by (pod, cluster) (
  container_memory_working_set_bytes{namespace="microservices"}
)

# See if Singapore metrics are arriving (remote_write working)
up{cluster="gke-singapore"}
```

**Step 3 — Verify remote_write (Singapore → Mumbai) is working:**
1. In Explore, run: `up{cluster="gke-singapore"}`
2. If you see results → Singapore's metrics are flowing into Mumbai's Prometheus
3. If empty → remote_write may be broken (check Singapore Prometheus logs)

**Step 4 — Check Prometheus targets directly:**
```bash
# Port-forward Mumbai Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus \
  9090:9090 -n monitoring --context=gke-mumbai &

# Open http://localhost:9090/targets
# Look for all the scrape targets (node-exporter, kube-state-metrics, etc.)

# Open http://localhost:9090/api/v1/label/cluster/values
# Should show: ["gke-mumbai", "gke-singapore"]
# This confirms metrics from both clusters are present
```

---


---

## 6. Why ArgoCD Apps Showed ComparisonError — Full Troubleshooting Story

This section documents the full investigation performed after connecting the
GitHub repo, so you understand exactly what happened and why — not just the fix.

### What was visible on the surface

All 6 ArgoCD apps showed:
```
SYNC: Unknown    HEALTH: Healthy
ComparisonError: Failed to load target state: failed to generate manifest
for source 1 of 1: rpc error: code = Unavailable
desc = name resolver error: produced zero addresses
```

Pods were running fine. The GLB was serving traffic. Only ArgoCD was broken.

### Investigation Layer 1 — Wrong Git Repo (Expected, Easy Fix)

The original apps were created by `04-deploy-apps.sh` using:
```
Repo: https://github.com/argoproj/argocd-example-apps.git
Path: guestbook
```

This is a placeholder — the ArgoCD example app repo. The real manifests
live in your repo at `gitops/apps/<service>/overlays/<region>/`.

**Fix attempted**: Delete the 6 old apps, recreate pointing at:
`https://github.com/deepaksoam313/multi-cluster-argocd-demo-by-kiro.git`

**Result**: Same error persisted on the new apps. The problem was deeper.

### Investigation Layer 2 — ArgoCD CLI gRPC Issue

The `argocd` CLI itself was failing with the same error when trying
`argocd repo add`:
```
name resolver error: produced zero addresses
```

**Root cause**: The ArgoCD CLI uses gRPC (HTTP/2) by default to communicate
with the ArgoCD server. gRPC has its own DNS resolver built in (separate from
the OS DNS resolver). In some environments — particularly when the ArgoCD
server is behind an L4 TCP load balancer — gRPC's DNS resolver fails to
resolve the server address even though normal `curl`/`wget` works fine.

**Fix**: Use `--grpc-web` flag on all CLI commands. This switches from gRPC
HTTP/2 to gRPC-Web over HTTP/1.1, which uses the normal OS resolver:
```bash
argocd login 35.200.130.47 --username admin \
  --password ISmy5X9fZGkUshXW --insecure --grpc-web

argocd app list --grpc-web
argocd cluster list --grpc-web
```

**Workaround for `repo add`**: Since the CLI's `repo add` was still failing
even with `--grpc-web`, we bypassed the CLI entirely and created the repo
registration as a Kubernetes Secret directly:
```bash
kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-multi-cluster-demo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: "https://github.com/deepaksoam313/multi-cluster-argocd-demo-by-kiro.git"
EOF
```
ArgoCD stores all repo credentials as Kubernetes Secrets internally.
Creating the Secret directly is exactly what `argocd repo add` does under the hood.

Similarly, the 6 Application objects were created via `kubectl apply` instead
of `argocd app create`, since Application is a Kubernetes CRD and kubectl
works just as well.

**Result after this**: Still the same error. Something deeper was wrong.

### Investigation Layer 3 — Internal Kubernetes DNS Was Broken

Checked DNS resolution from inside the cluster:
```bash
kubectl run dnstest --image=busybox:1.35 --restart=Never -n argocd \
  --command -- sh -c "nslookup argocd-repo-server.argocd.svc.cluster.local"
```

Output:
```
** server can't find argocd-repo-server.argocd.svc.cluster.local: SERVFAIL
```

Also checked the application-controller logs:
```
Reconnect to redis because error: "dial tcp: lookup argocd-redis on
34.118.224.10:53: no such host"
```

ArgoCD's internal components couldn't resolve each other's service names
via Kubernetes DNS. This was the actual root cause — not GitHub connectivity.

### Investigation Layer 4 — CoreDNS Was Stuck Pending

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```
```
NAME                    READY   STATUS    RESTARTS   AGE
kube-dns-...-hnrdz      0/4     Pending   0          131m   ← Pending for 2+ hours!
kube-dns-...-wjjv4      0/4     Pending   0          132m   ← Same
```

Describing the pod revealed:
```
Warning  FailedScheduling  0/2 nodes are available: 2 Insufficient cpu.
```

**The real root cause**: The 2-node e2-medium cluster (2 vCPU = ~940m
allocatable per node) was already at 88–99% CPU requests before CoreDNS
even tried to schedule. Each kube-dns pod needs ~270m CPU. There was no room.

**Why did everything else work?**
- App pods (order-svc etc.) use direct pod IPs → no DNS needed
- The GLB uses IP-based backend routing via NEGs → no DNS needed
- ArgoCD components had pod IPs hardcoded in environment vars on startup
  before DNS broke, so they partially worked
- The `argocd-server` LoadBalancer IP is assigned by GCP → no DNS needed

Only things that needed in-cluster DNS broke:
- ArgoCD repo-server → `argocd-redis.argocd.svc.cluster.local`
- ArgoCD application-controller → `argocd-repo-server.argocd.svc.cluster.local`
- Any new pod trying to connect to any service by name

**Fix**: Scale Mumbai from 2 → 3 nodes:
```bash
gcloud container clusters resize gke-mumbai \
  --zone=asia-south1-a \
  --project=skilled-text-468416-g3 \
  --num-nodes=3 --quiet
```

The new node (e2-medium, ~940m CPU free) had room for one kube-dns pod.
It scheduled, started, and internal DNS immediately began working.

### Why Only One kube-dns Pod Scheduled (Not Both)

After adding node 3, one kube-dns pod scheduled on it. The second pod
(`hnrdz`) remained Pending because of a taint:
```
0/3 nodes: 1 node(s) had untolerated taint(s), 2 Insufficient cpu
```

GKE applies a temporary taint to newly added nodes during initialization.
Once the taint cleared and the node warmed up, the second pod also had
nowhere to go (nodes 1 and 2 were still full). This is acceptable — one
kube-dns replica is enough for the cluster to function. GKE's `kube-dns-autoscaler`
will eventually adjust, and adding a 4th node would fix it fully.

### Final Fix — Restart ArgoCD With Working DNS

```bash
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout restart deployment/argocd-server -n argocd
```

The pods restarted, resolved all service names via CoreDNS, connected to Redis,
cloned the GitHub repo, ran Kustomize, and compared against the running state.

All 6 apps became **Synced + Healthy**.

### Lesson Learned

> **e2-medium nodes are too small for a full GKE cluster stack.**
>
> By the time GKE installs its own system components (Calico × 2, calico-typha × 2,
> fluentbit × 2, kube-proxy × 2, gke-metadata-server × 2, node-local-dns × 2,
> metrics-server, kube-state-metrics) + your workloads (ArgoCD, Prometheus,
> 6 app deployments × 2 replicas), the CPU request budget is exhausted on
> 2 nodes and CoreDNS — a critical system component — can't schedule.
>
> For production: use `e2-standard-4` (4 vCPU) or larger, or use 3+ nodes from
> the start. Never size a cluster so tight that system pods can't schedule.

### Summary Table

| Layer | What Was Wrong | Fix |
|-------|---------------|-----|
| 1 | Apps pointed at wrong Git repo (example-apps placeholder) | Deleted and recreated apps pointing at correct repo |
| 2 | ArgoCD CLI gRPC DNS resolver failure | Used `--grpc-web` flag; applied Secrets/CRDs via kubectl directly |
| 3 | Internal K8s DNS (CoreDNS) not working | Traced to CoreDNS pods being Pending |
| 4 | CoreDNS Pending due to CPU exhaustion on 2-node cluster | Scaled Mumbai to 3 nodes; restarted ArgoCD components |

---

*Document last updated: 2026-10-12*


---

---

## 7. Hands-On: How a Request Travels Across Clusters

### Architecture Reminder

```
User → GLB Anycast IP (8.233.61.198)
         ↓
    URL Map (routes /order → order-svc-backend, /product → ...)
         ↓
    Backend Service (has NEGs from BOTH clusters)
         ↓
    NEG in Mumbai OR Singapore (GLB picks based on proximity + health)
         ↓
    Pod in microservices namespace
         ↓
    Response includes {"region": "asia-south1", "cluster": "gke-mumbai"}
```

### Step 1 — Test Direct Pod Response (bypasses everything)

```bash
source ~/multi-region-demo/scripts/env.sh

# Port-forward directly to a pod in Mumbai
kubectl port-forward svc/order-svc 18080:80 \
  -n microservices --context=gke-mumbai &
PF1=$!
sleep 2

curl http://localhost:18080
# → {"service":"order","region":"asia-south1","cluster":"gke-mumbai","status":"ok"}

kill $PF1

# Port-forward to Singapore
kubectl port-forward svc/order-svc 18081:80 \
  -n microservices --context=gke-singapore &
PF2=$!
sleep 2

curl http://localhost:18081
# → {"service":"order","region":"asia-southeast1","cluster":"gke-singapore","status":"ok"}

kill $PF2
```

These responses prove the pods in each region return their own region identity.

### Step 2 — Test Through the Global Load Balancer

```bash
# Hit the GLB 10 times — notice which cluster responds
for i in {1..10}; do
  echo -n "Request $i → "
  curl -s --max-time 5 http://8.233.61.198/order
  echo ""
done
```

Since you are in India (close to Mumbai), the GLB routes all traffic to Mumbai.
This is Anycast working correctly — nearest healthy region wins.

### Step 3 — Trace the Full Request Path

```bash
# See which NEG (Network Endpoint Group) serves your traffic
gcloud compute backend-services get-health order-svc-backend \
  --global \
  --project=skilled-text-468416-g3

# You will see backends from BOTH regions and their health status:
# asia-south1-a/networkEndpointGroups/...   HEALTHY
# asia-southeast1-a/networkEndpointGroups/... HEALTHY
```

### Step 4 — See the NEGs (what maps GLB → Pods)

```bash
# List NEGs on Mumbai
gcloud compute network-endpoint-groups list \
  --filter="zone:asia-south1-a" \
  --project=skilled-text-468416-g3

# Describe one NEG to see which pod IPs are registered
NEG_NAME=$(gcloud compute network-endpoint-groups list \
  --filter="zone:asia-south1-a AND name~order-svc" \
  --format="value(name)" \
  --project=skilled-text-468416-g3)

gcloud compute network-endpoint-groups list-network-endpoints \
  "$NEG_NAME" \
  --zone=asia-south1-a \
  --project=skilled-text-468416-g3
# → shows individual pod IPs that the GLB load-balances to
```

### Step 5 — Watch Real-Time Pod Logs While Hitting GLB

```bash
# Terminal 1: watch Mumbai pods
kubectl logs -f -l app=order-svc \
  -n microservices --context=gke-mumbai

# Terminal 2: watch Singapore pods
kubectl logs -f -l app=order-svc \
  -n microservices --context=gke-singapore

# Terminal 3: send traffic to GLB
watch -n 1 'curl -s http://8.233.61.198/order'
```

You will see Mumbai pod logs light up with each request.

### Step 6 — Simulate Failover (Traffic Shifting)

```bash
# Scale down Mumbai microservices to simulate failure
kubectl scale deployment order-svc product-svc user-svc \
  --replicas=0 -n microservices --context=gke-mumbai

# Watch the GLB failover in real time (takes ~15 seconds)
for i in {1..20}; do
  echo -n "$(date +%H:%M:%S) Request $i → "
  curl -s --max-time 5 http://8.233.61.198/order || echo "TIMEOUT"
  echo ""
  sleep 2
done

# You will see responses switch from gke-mumbai → gke-singapore!

# Restore Mumbai
kubectl scale deployment order-svc product-svc user-svc \
  --replicas=2 -n microservices --context=gke-mumbai

# Traffic will redistibute back to Mumbai after ~10 seconds
```

---


---

## 8. Every Command Used — With Why and How

### Phase 1 — Environment Setup

```bash
source scripts/env.sh
```
**Why**: Sets all environment variables (project ID, cluster names, zones,
namespaces, image names) in one place. Every subsequent script sources this
file so there is no hardcoding. This is the "single source of truth" for
configuration.

---

### Phase 2 — GKE Cluster Creation (`01-create-clusters.sh`)

#### Enable GCP APIs

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID" --quiet
```
**Why**: GCP APIs are disabled by default. Before you can create GKE clusters
or VPCs, the relevant APIs must be activated on your project.
- `container.googleapis.com` — GKE control plane
- `compute.googleapis.com` — VMs, networking, Load Balancers, NEGs
- `cloudresourcemanager.googleapis.com` — IAM and project management

#### Create GKE Cluster (Mumbai)

```bash
gcloud container clusters create "gke-mumbai" \
  --project="skilled-text-468416-g3" \
  --zone="asia-south1-a" \
  --num-nodes=2 \
  --machine-type="e2-medium" \
  --disk-size="50" \
  --release-channel="regular" \
  --workload-pool="skilled-text-468416-g3.svc.id.goog" \
  --enable-ip-alias \
  --enable-network-policy \
  --labels="env=demo,region=asia-south1,managed-by=gcloud" \
  --async \
  --quiet
```

**Flag-by-flag explanation**:

| Flag | Value | Why |
|------|-------|-----|
| `--zone` | asia-south1-a | Single-zone cluster (cheaper for lab). Production uses `--region` for multi-zone redundancy |
| `--num-nodes` | 2 | 2 nodes per cluster = 4 total. Enough to run all pods with headroom |
| `--machine-type` | e2-medium | 2 vCPU, 4GB RAM. Sufficient for lab workloads at low cost |
| `--disk-size` | 50 | 50GB boot disk. Default is 100GB which is wasteful for lab |
| `--release-channel` | regular | GKE auto-upgrades K8s on a "regular" cadence (stable, not bleeding edge) |
| `--workload-pool` | PROJECT.svc.id.goog | Enables Workload Identity — pods get GCP IAM permissions without static keys |
| `--enable-ip-alias` | (flag) | VPC-native networking. Pod IPs are routable on the VPC, **required for NEGs** and GLB integration |
| `--enable-network-policy` | (flag) | Enables Kubernetes NetworkPolicy enforcement via Calico. Needed for pod-level firewall rules |
| `--labels` | env=demo,... | GCP resource labels for billing/cost tracking and filtering |
| `--async` | (flag) | Returns immediately, cluster creates in background. Both clusters start in parallel (~8 min) |

**Why two separate clusters instead of one?**:
Multi-region means the clusters are in different GCP regions (asia-south1 and
asia-southeast1). They are physically separate, so if an entire GCP region
goes down, the other cluster is unaffected. One cluster spanning two regions
is not possible in standard GKE.

#### Fetch Kubeconfig

```bash
gcloud container clusters get-credentials "gke-mumbai" \
  --zone="asia-south1-a" --project="skilled-text-468416-g3"
```
**Why**: Downloads the cluster's API server certificate, endpoint, and generates
a kubeconfig context so `kubectl` can talk to the cluster. Without this,
kubectl does not know the cluster exists.

#### Rename Contexts

```bash
kubectl config rename-context \
  "gke_skilled-text-468416-g3_asia-south1-a_gke-mumbai" \
  "gke-mumbai"
```
**Why**: gcloud names contexts with a long prefix. Renaming to `gke-mumbai`
makes every subsequent command readable. You can now write
`--context=gke-mumbai` instead of the full 50-character name.

#### Create Namespaces

```bash
kubectl create namespace microservices --dry-run=client -o yaml | \
  kubectl apply -f -
```
**Why**: 
- `microservices` — all app pods live here, isolated from system components
- `monitoring` — Prometheus/Grafana isolated from apps
- `argocd` — ArgoCD isolated from everything else

The `--dry-run=client -o yaml | kubectl apply -f -` pattern is **idempotent**
— it will not error if the namespace already exists (unlike plain `create`
which would error on re-run).

---

### Phase 3a — Install ArgoCD (`02-install-argocd.sh`)

#### Apply ArgoCD Manifests

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```
**Why**: The official ArgoCD install manifest creates:
- All ArgoCD CRDs (Application, AppProject)
- Deployments: argocd-server, argocd-repo-server, argocd-application-controller,
  argocd-dex-server (SSO), argocd-notifications-controller
- RBAC: ClusterRoles and ClusterRoleBindings
- Services, ConfigMaps, Secrets

Using `stable` channel means we get the latest stable release automatically.

#### Expose ArgoCD as LoadBalancer

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'
```
**Why**: By default `argocd-server` is a ClusterIP service (only reachable
inside the cluster). Changing it to LoadBalancer provisions a GCP External
Load Balancer with a public IP, allowing browser access from anywhere.
In production you would use an Ingress + TLS certificate instead.

#### Login to ArgoCD CLI

```bash
argocd login 35.200.130.47 \
  --username admin \
  --password ISmy5X9fZGkUshXW \
  --insecure
```
**Why**: Authenticates the `argocd` CLI against the server. All subsequent
`argocd` commands (cluster add, app create, sync) rely on this session token.
`--insecure` skips TLS verification since we're using HTTP/self-signed cert.

---

### Phase 3b — Register Singapore with ArgoCD (`03-register-clusters.sh`)

#### Add Remote Cluster

```bash
argocd cluster add gke-singapore \
  --name gke-singapore \
  --yes
```
**Why**: This is the core GitOps multi-cluster step. ArgoCD on Mumbai needs
to deploy to Singapore too. This command:
1. Reads the `gke-singapore` context from your local kubeconfig
2. Creates a ServiceAccount `argocd-manager` in the `kube-system` namespace
   on the Singapore cluster
3. Creates a ClusterRoleBinding giving it admin access
4. Stores Singapore's API server URL + token in a Secret in the `argocd`
   namespace on Mumbai

Now ArgoCD on Mumbai can authenticate to Singapore's API server and deploy
resources there, just like it can to its own cluster.

#### Create ArgoCD Project

```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: multi-region-demo
  namespace: argocd
spec:
  sourceRepos: ['*']
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF
```
**Why**: ArgoCD uses Projects to control which repos, clusters, and namespaces
each set of apps can deploy to. The `default` project allows everything, but
creating a named project (`multi-region-demo`) is better practice — it groups
related apps and applies access policies. In production, projects would be more
restrictive (specific repos, specific namespaces).

---

### Phase 4+5 — Deploy Microservices (`04-deploy-apps.sh`)

#### Create Base Manifests

The script generates:
- `manifests/base/order-svc/deployment.yaml` — Deployment with 2 replicas
- `manifests/base/order-svc/service.yaml` — ClusterIP Service with NEG annotation
- `manifests/base/order-svc/hpa.yaml` — HorizontalPodAutoscaler (2-5 replicas)
- `manifests/base/order-svc/kustomization.yaml` — Kustomize entry point

**Why hashicorp/http-echo as the image?**
It is a minimal Go HTTP server (~5MB) that returns whatever text you pass as
`-text` argument. Perfect for lab — we can make each pod return JSON identifying
its region and cluster without writing any application code.

**Why the NEG annotation on the Service?**
```yaml
annotations:
  cloud.google.com/neg: '{"ingress": true}'
```
This tells GKE to automatically create a **Network Endpoint Group** for this
service. The NEG maps each pod IP directly to the GCP load balancer, enabling
the Global HTTP LB to health-check and route to individual pods rather than
going through kube-proxy on each node. This is required for the GLB setup.

**Why Kustomize overlays?**
The base manifests are region-agnostic. The overlays patch only the
region-specific parts (the `-text` arg that sets the response body).
This follows the DRY principle — 3 services × 2 regions = 6 deployments,
but you only maintain 3 base configs + 6 small patches.

#### Apply Kustomize Overlays

```bash
kubectl apply -k gitops/apps/order-svc/overlays/mumbai \
  --context=gke-mumbai

kubectl apply -k gitops/apps/order-svc/overlays/singapore \
  --context=gke-singapore
```
**Why `-k`**: The `-k` flag tells kubectl to use Kustomize to generate the
final YAML from the base + patches before applying it. Without `-k` you would
need to manually merge all the YAML files.

---

### Phase 6 — Monitoring (`05-setup-monitoring.sh`)

#### Add Helm Repo

```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update
```
**Why**: Helm repos are like apt/yum repos for Kubernetes. `prometheus-community`
hosts the `kube-prometheus-stack` chart which bundles Prometheus Operator,
Prometheus, Grafana, AlertManager, kube-state-metrics, and node-exporter
in one chart — saving the effort of wiring them together manually.

#### Install on Mumbai (with Grafana)

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values gitops/monitoring/values-mumbai.yaml \
  --kube-context gke-mumbai \
  --wait \
  --timeout 10m
```
**Why `upgrade --install`**: Idempotent — installs if not present, upgrades
if already installed. Safe to re-run.

**Key values in `values-mumbai.yaml`**:
```yaml
prometheus:
  prometheusSpec:
    externalLabels:
      cluster: gke-mumbai     # Every metric gets this label — critical for
      region: asia-south1     # distinguishing sources in Grafana queries
    enableRemoteWriteReceiver: true   # Accept metrics pushed from Singapore
```

#### Install on Singapore (no Grafana, only remote_write)

**Why no Grafana on Singapore?**
Running two separate Grafana instances would mean you see two dashboards,
neither showing the full picture. The architecture centralizes all metrics in
Mumbai's Prometheus via `remote_write`. One Grafana sees everything.

**remote_write in `values-singapore.yaml`**:
```yaml
prometheus:
  prometheusSpec:
    remoteWrite:
      - url: "http://MUMBAI_PROMETHEUS_IP:9090/api/v1/write"
```
This makes Singapore's Prometheus continuously push all its scraped metrics
to Mumbai's Prometheus. In Grafana, you write one query that covers both
clusters by filtering on the `cluster` label.

---

### Phase 7 — Global Load Balancer (`06-setup-glb.sh`)

The GLB setup involves several GCP resources. Here is the full chain:

```
[Forwarding Rule] → [Target HTTP Proxy] → [URL Map] → [Backend Service]
                                                              ↓
                                           [NEG Mumbai] + [NEG Singapore]
```

#### Reserve Static Global IP

```bash
gcloud compute addresses create multi-region-lb-ip \
  --global --project=skilled-text-468416-g3
```
**Why global?**: A global IP is Anycast — the same IP is announced from GCP
edge PoPs worldwide. Traffic automatically routes to the nearest PoP, then
to the backend. A regional IP would not support this.

#### Create Health Checks

```bash
gcloud compute health-checks create http order-svc-hc \
  --port=8080 \
  --request-path="/" \
  --check-interval=5s \
  --timeout=5s \
  --healthy-threshold=1 \
  --unhealthy-threshold=2
```
**Why**: The GLB must know whether each backend (NEG/pod) is healthy before
routing traffic to it. It sends an HTTP GET every 5 seconds. If 2 consecutive
checks fail, the backend is marked unhealthy and taken out of rotation.
This drives the ~15-second failover time.

#### Create Backend Services

```bash
gcloud compute backend-services create order-svc-backend \
  --global \
  --protocol=HTTP \
  --health-checks=order-svc-hc \
  --load-balancing-scheme=EXTERNAL_MANAGED
```
**Why**: A Backend Service is the logical group of backends (NEGs from both
regions) plus the health check policy, session affinity settings, and timeout.
One Backend Service per microservice.

#### Attach NEGs to Backend Services

```bash
gcloud compute backend-services add-backend order-svc-backend \
  --global \
  --network-endpoint-group=NEG_MUMBAI \
  --network-endpoint-group-zone=asia-south1-a \
  --balancing-mode=RATE \
  --max-rate-per-endpoint=100
```
**Why**: This is where the GLB learns that `order-svc-backend` has backends
in two physical locations (Mumbai and Singapore NEGs). The GLB will
automatically prefer the geographically closer NEG for each incoming request.

#### Create URL Map

```bash
gcloud compute url-maps create multi-region-http-lb \
  --default-service=order-svc-backend
```
**Why**: The URL Map is the routing table. It maps HTTP paths to backend
services. `/order` → `order-svc-backend`, `/product` → `product-svc-backend`, etc.
Without a URL map, the GLB would not know which backend to send each request to.

#### Create Target HTTP Proxy

```bash
gcloud compute target-http-proxies create multi-region-lb-proxy \
  --url-map=multi-region-http-lb
```
**Why**: The Target Proxy is the layer that understands HTTP (vs raw TCP).
It terminates HTTP connections and passes them to the URL map for routing.
For HTTPS, you would use `target-https-proxies` and attach a TLS certificate.

#### Create Forwarding Rule

```bash
gcloud compute forwarding-rules create multi-region-lb-rule \
  --global \
  --target-http-proxy=multi-region-lb-proxy \
  --ports=80 \
  --address=multi-region-lb-ip
```
**Why**: The Forwarding Rule binds the public IP address and port (80) to the
Target HTTP Proxy. This is the "front door" — what the internet actually
connects to. When traffic arrives at `8.233.61.198:80`, this rule picks it
up and forwards it into the LB pipeline.

---


---

## 9. ArgoCD in Production — Cluster or Standalone?

### Short Answer

**In production, ArgoCD runs inside a dedicated Kubernetes cluster** — but that
cluster is a separate, infrastructure-only cluster (not your app clusters).
It does NOT run as a standalone binary outside of Kubernetes.

### The Patterns

#### Pattern 1: Hub-and-Spoke (what we built, and most common in production)

```
┌────────────────────────────────────────────────┐
│  Management Cluster (dedicated, small)         │
│  ┌─────────────────────────────────────────┐   │
│  │  ArgoCD                                 │   │
│  │  - argocd-server (UI + API)             │   │
│  │  - argocd-application-controller        │   │
│  │  - argocd-repo-server (clones git)      │   │
│  └──────┬──────────────────────┬───────────┘   │
└─────────│──────────────────────│───────────────┘
          │  deploys to          │  deploys to
          ▼                      ▼
    ┌─────────────┐        ┌─────────────┐
    │  Prod-East  │        │  Prod-West  │
    │  (apps)     │        │  (apps)     │
    └─────────────┘        └─────────────┘
```

**Why a separate management cluster?**
- ArgoCD has access to ALL cluster secrets and API servers — it's a high-value target
- If an app cluster is compromised or has node pressure, ArgoCD keeps running
- You don't want `kubectl drain` on an app node to accidentally kill ArgoCD
- The management cluster can be very small (2-3 nodes) and cheap

#### Pattern 2: In-Cluster (what we did in the lab — acceptable for smaller setups)

ArgoCD runs on one of the app clusters (Mumbai in our case) and manages both
itself and remote clusters. Simpler but:
- If Mumbai is down, you lose ArgoCD visibility into Singapore too
- Blast radius of a cluster outage is larger
- Not ideal for production at scale

#### Pattern 3: ArgoCD with High Availability

For large production deployments, ArgoCD itself is made HA:

```bash
# Install ArgoCD in HA mode (uses Redis Sentinel + multiple replicas)
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

This runs 3 replicas of `argocd-application-controller` and `argocd-server`
with a Redis Sentinel cluster for state sharing.

#### Pattern 4: Autopilot / Managed ArgoCD

Cloud providers offer managed GitOps:
- **GCP**: Cloud Deploy (not ArgoCD but similar GitOps)
- **AWS**: Amazon EKS Anywhere + Flux (not ArgoCD)
- **Self-managed**: Akuity (managed ArgoCD SaaS by ArgoCD creators)
- **GitLab**: built-in GitOps agent

### How ArgoCD Components Work Together

```
Git Repo (GitHub/GitLab/Bitbucket)
    │
    │  (argocd-repo-server polls/webhooks every 3 min)
    ▼
argocd-repo-server
    │  clones repo, runs Kustomize/Helm, generates final YAML
    │
    ▼
argocd-application-controller
    │  compares desired state (from repo) vs actual state (from cluster API)
    │  if drift detected → triggers sync (apply YAML)
    │
    ├──► kubectl apply → Mumbai cluster (in-cluster = localhost)
    └──► kubectl apply → Singapore cluster (via stored kubeconfig secret)

argocd-server
    └──► serves the Web UI + gRPC API (what the argocd CLI talks to)

argocd-dex-server
    └──► handles SSO (GitHub OAuth, LDAP, SAML, etc.)
```

### Key Production ArgoCD Practices

| Practice | Why |
|----------|-----|
| Use SSH deploy keys per repo | More secure than HTTPS tokens |
| Enable RBAC in ArgoCD | Devs can sync their own apps; only platform team can delete apps |
| Use App-of-Apps pattern | One ArgoCD Application that creates all other Applications |
| Set `syncPolicy: automated` with `selfHeal: true` | Auto-revert manual kubectl edits |
| Use `syncWindows` | Prevent deployments during maintenance windows |
| Enable notifications | Slack/PagerDuty alerts on sync failures |
| Store ArgoCD secrets in Vault or SOPS | Never commit cluster credentials in plaintext |

---

---

## 10. Quick Reference — Access Everything


```bash
# Load environment
cd ~/multi-region-demo
source scripts/env.sh

# Switch clusters
kubectl config use-context gke-mumbai
kubectl config use-context gke-singapore

# ArgoCD UI
echo "http://35.200.130.47  (admin / ISmy5X9fZGkUshXW)"

# Grafana UI
echo "http://34.93.126.133  (admin / demo-password-123)"

# Prometheus UI
echo "http://8.234.93.217:9090"

# GLB endpoint
echo "http://8.233.61.198/order"
echo "http://8.233.61.198/product"
echo "http://8.233.61.198/user"

# ArgoCD CLI
argocd login 35.200.130.47 --username admin \
  --password ISmy5X9fZGkUshXW --insecure
argocd app list
argocd cluster list
```

---

*Document generated on 2026-10-12 from live lab state.*


---

