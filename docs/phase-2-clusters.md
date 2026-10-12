# Phase 2: Create GKE Clusters

## What Are We Doing in This Phase?

We are provisioning **two independent Kubernetes clusters** on Google Cloud,
each in a different geographic region:

| Cluster | Region | City | Role |
|---------|--------|------|------|
| `gke-mumbai` | asia-south1 | Mumbai, India | Primary — will host ArgoCD hub |
| `gke-singapore` | asia-southeast1 | Singapore | Secondary — managed remotely by ArgoCD |

These two clusters together form the **active-active** foundation.
Both will run the same microservices and handle live traffic simultaneously.

---

## Why Two Separate Clusters (Not One Big One)?

This is one of the most important design decisions. Here is why:

### Option A: One cluster, multi-zone (NOT what we are doing)
```
Single Cluster
├── Node in asia-south1-a
├── Node in asia-south1-b
└── Node in asia-south1-c
```
- Protects against **zone failure** (datacenter fire, power outage)
- Does NOT protect against **regional failure** (undersea cable cut,
  regional GCP outage, natural disaster in one city)
- Single control plane = single point of failure for the whole cluster

### Option B: Two clusters, two regions (what we ARE doing)
```
Cluster 1 (Mumbai)         Cluster 2 (Singapore)
├── Node a                 ├── Node a
└── Node b                 └── Node b
```
- Protects against **full regional failure**
- Each cluster has its own independent control plane
- If the entire Mumbai GCP region goes down, Singapore keeps serving traffic
- This is true **multi-region** high availability

### The Tradeoff
Two clusters means more operational complexity:
- You need to deploy apps to both (ArgoCD solves this)
- You need to view metrics from both (Prometheus remote_write solves this)
- You need a global load balancer to route traffic (GCP GLB solves this)

That is exactly what this lab teaches — how to solve each of these problems.

---

## What is GKE (Google Kubernetes Engine)?

GKE is Google's **managed Kubernetes service**. When you create a GKE cluster:

```
What GCP manages for you:          What you manage:
───────────────────────────         ──────────────────────
✅ Kubernetes control plane         ✅ Worker node sizing
✅ etcd (cluster state DB)          ✅ Your application pods
✅ API server availability          ✅ Namespaces and RBAC
✅ Certificate rotation             ✅ Resource requests/limits
✅ K8s version upgrades (optional)  ✅ Networking policies
✅ Node auto-repair                 ✅ Monitoring setup
```

You never SSH into a control plane node — GCP manages it fully and charges
a flat $0.10/hr per cluster for this (waived for clusters with 5+ nodes).

---

## Cluster Configuration Decisions Explained

Every flag we pass to `gcloud container clusters create` is a deliberate choice.
Here is what each one means and why we chose it:

### `--zone=asia-south1-a` (Zonal, not Regional)

**Zonal cluster**: All nodes in one zone (one datacenter).
**Regional cluster**: Nodes spread across 3 zones in the region.

We chose **zonal** because:
- Regional = 3× the node count = 3× the cost for a lab
- A zonal cluster is sufficient to demonstrate the multi-region pattern
- In production you would use regional clusters for each region

```
Zonal (we use):              Regional (production):
asia-south1-a only           asia-south1-a + b + c
2 nodes, ~$0.10/hr           6 nodes, ~$0.30/hr
```

### `--num-nodes=2`

Two nodes per cluster gives us:
- Enough capacity to run 3 microservices + Prometheus + ArgoCD
- Pod scheduling flexibility (some pods require different nodes)
- Demonstrates node-level scheduling without overcomplicating

In production this would be governed by a cluster autoscaler based on actual load.

### `--machine-type=e2-medium`

`e2-medium` = 2 vCPU, 4 GB RAM per node.

```
Our workloads per cluster:
─────────────────────────────────────────────
Component          CPU req   Memory req
─────────────────────────────────────────────
order-svc (×2)     100m      64Mi
product-svc (×2)   100m      64Mi
user-svc (×2)      100m      64Mi
Prometheus         200m      400Mi
Grafana (cluster1) 100m      200Mi
kube-state-metrics  50m       50Mi
node-exporter       30m       30Mi
ArgoCD (cluster1)  500m      512Mi
System pods        300m      300Mi
─────────────────────────────────────────────
TOTAL             ~1480m    ~1758Mi
─────────────────────────────────────────────
Available (2×e2-medium): 4000m / 8192Mi ✅
```

e2-medium is enough with ~60% headroom for burst.

### `--release-channel=regular`

GKE has three release channels:

| Channel | Update cadence | Use for |
|---------|---------------|---------|
| rapid | Weekly | Testing new K8s features |
| regular | Monthly | General workloads (our choice) |
| stable | Quarterly | Mission-critical production |

`regular` gives us a recent stable K8s version with monthly patches.

### `--enable-ip-alias` (VPC-native networking)

This enables **VPC-native** (alias IP) networking instead of legacy routes-based.

Without this: Pods get IPs from a secondary range but routing goes through
`iptables` rules on each node — less efficient, harder to debug.

With this: Each pod gets a real VPC IP. GCP's network fabric routes pod
traffic directly — no NAT, no iptables overhead. Also required for:
- Container-native load balancing (NEGs) — needed in Phase 7
- Better network visibility in GCP console
- VPC peering compatibility

### `--enable-network-policy`

Enables **Kubernetes NetworkPolicy** enforcement via Calico (GKE's default CNI).

By default, all pods can talk to all other pods in the cluster. Network policies
let you say "only order-svc can talk to the database" etc.

We enable it now because:
- It is a cluster-level setting — cannot be added after creation
- Good security practice from day 1
- We may use it in Phase 8 to simulate a "network partition" failure

### `--workload-pool=PROJECT_ID.svc.id.goog`

This enables **Workload Identity** — the recommended way for pods to authenticate
to GCP services (like Cloud Spanner, Pub/Sub, etc.).

Without Workload Identity: you mount a service account JSON key file into pods
(bad — keys can leak, hard to rotate).

With Workload Identity: pods are automatically authenticated via their Kubernetes
ServiceAccount, which is mapped to a GCP Service Account — no key files ever
touch the cluster.

Even though our simple http-echo services don't call GCP APIs today,
we enable it now because:
- It cannot be enabled after cluster creation easily
- Best practice for any real workload
- Prometheus might need it later to scrape GCP metrics

---

## What Happens When We Create a GKE Cluster?

Understanding what GCP does behind the scenes helps you debug problems.

```
gcloud container clusters create ...
         │
         ▼
1. GCP provisions a GCE VM for the K8s control plane (hidden from you)
         │
         ▼
2. GCP installs etcd, kube-apiserver, kube-controller-manager,
   kube-scheduler on the control plane VM
         │
         ▼
3. GCP provisions your worker node VMs (the ones you pay for)
         │
         ▼
4. Worker nodes register themselves with the control plane
         │
         ▼
5. GKE installs system pods: kube-dns, kube-proxy, fluentd,
   metrics-server, gke-metadata-server
         │
         ▼
6. GCP generates cluster certificates and kubeconfig entry
         │
         ▼
7. Cluster status changes: PROVISIONING → RECONCILING → RUNNING
   (Total time: 5-8 minutes)
```

---

## kubeconfig Context Management

After creating clusters, `gcloud` updates your `~/.kube/config` file automatically.
The context names it creates are long and ugly:

```
gke_skilled-text-468416-g3_asia-south1-a_gke-mumbai
```

We rename them to short friendly names so every kubectl command is readable:

```bash
# Before rename:
kubectl get pods --context=gke_skilled-text-468416-g3_asia-south1-a_gke-mumbai

# After rename:
kubectl get pods --context=gke-mumbai
```

The rename is done with:
```bash
kubectl config rename-context \
  gke_skilled-text-468416-g3_asia-south1-a_gke-mumbai \
  gke-mumbai
```

After this, your `~/.kube/config` has:
```yaml
contexts:
- name: gke-mumbai        ← friendly name
  context:
    cluster: gke_skilled-text-468416-g3_asia-south1-a_gke-mumbai
    user: gke-mumbai-admin
- name: gke-singapore
  context:
    cluster: gke_skilled-text-468416-g3_asia-southeast1-a_gke-singapore
    user: gke-singapore-admin
```

---

## Namespace Strategy

We pre-create namespaces before deploying anything. Why?

Kubernetes **namespaces** are virtual partitions inside a cluster:
- Resources in different namespaces don't conflict
- RBAC policies can be scoped per namespace
- Resource quotas can be set per namespace
- Makes it easy to `kubectl delete namespace X` to wipe everything cleanly

| Namespace | Created on | Contains |
|-----------|-----------|----------|
| `microservices` | Both clusters | order-svc, product-svc, user-svc pods |
| `monitoring` | Both clusters | Prometheus, Grafana, node-exporter |
| `argocd` | Cluster 1 only | All ArgoCD components |

```
gke-mumbai                    gke-singapore
├── namespace: microservices  ├── namespace: microservices
├── namespace: monitoring     ├── namespace: monitoring
└── namespace: argocd         └── (no argocd here)
```

---

## What Could Go Wrong (and How to Fix It)

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `PERMISSION_DENIED` on cluster create | Missing `container.clusters.create` IAM role | Run `gcloud auth login` or check IAM |
| Cluster stuck in `PROVISIONING` >10 min | GCP quota exceeded | Check `gcloud compute regions describe asia-south1 --format='value(quotas)'` |
| `ZONE_RESOURCE_POOL_EXHAUSTED` | e2-medium out of stock in zone | Try `-b` or `-c` zone suffix |
| kubeconfig not updated | `get-credentials` not run | Run manually: `gcloud container clusters get-credentials gke-mumbai --zone=asia-south1-a` |
| Nodes in `NotReady` state | Node still bootstrapping | Wait 2-3 min after cluster shows RUNNING |
| `error: no configuration` | Wrong context | `kubectl config use-context gke-mumbai` |

---

## Step-by-Step: What the Script Does

`scripts/01-create-clusters.sh` executes these steps in order:

```
Step 1: Enable APIs
  └── container.googleapis.com  (GKE)
  └── compute.googleapis.com    (VMs, networking)
  └── cloudresourcemanager.googleapis.com (IAM checks)

Step 2: Create gke-mumbai (--async → does not block)
  └── Submitted to GCP, returns immediately

Step 3: Create gke-singapore (--async → does not block)
  └── Submitted to GCP, both clusters now provisioning in parallel

Step 4: Poll both clusters every 20 seconds
  └── Waits until STATUS == RUNNING for both

Step 5: gcloud container clusters get-credentials (for each cluster)
  └── Writes kubeconfig entries to ~/.kube/config

Step 6: kubectl config rename-context
  └── Shortens context names to gke-mumbai, gke-singapore

Step 7: Create namespaces on both clusters
  └── microservices, monitoring, argocd (argocd only on cluster 1)

Step 8: Verify — print nodes from both clusters
  └── Confirms connectivity and node readiness
```

---

## Executing Phase 2

```bash
cd /home/deepak.kumar30/multi-region-demo
./scripts/01-create-clusters.sh
```

Expected total time: **7-10 minutes**

### Progress indicators you will see:
```
[INFO] Enabling required GCP APIs...
[OK] APIs enabled
[INFO] Creating cluster 1: gke-mumbai in asia-south1-a ...
[OK] Cluster 1 creation started (async)
[INFO] Creating cluster 2: gke-singapore in asia-southeast1-a ...
[OK] Cluster 2 creation started (async)
[INFO] Waiting for both clusters to be RUNNING...
  Waiting for gke-mumbai...
    Status: PROVISIONING — retrying in 20s...
    Status: PROVISIONING — retrying in 20s...
    Status: RECONCILING  — retrying in 20s...  ← almost ready
[OK] gke-mumbai is RUNNING
  Waiting for gke-singapore...
    Status: RUNNING  ← Singapore finished around the same time
[OK] gke-singapore is RUNNING
[INFO] Fetching kubeconfigs...
[INFO] Renaming kubectl contexts...
[OK] Contexts renamed: gke-mumbai, gke-singapore
[INFO] Creating namespaces on both clusters...
[OK] Namespaces created
[OK] Phase 2 complete! Both clusters are ready.
```

---

## Verification Commands (Run After the Script)

```bash
# List all clusters in the project
gcloud container clusters list --project=skilled-text-468416-g3

# Expected output:
# NAME           LOCATION           MASTER_VERSION       STATUS
# gke-mumbai     asia-south1-a      1.35.x               RUNNING
# gke-singapore  asia-southeast1-a  1.35.x               RUNNING

# Check contexts
kubectl config get-contexts

# Check nodes on Mumbai
kubectl get nodes --context=gke-mumbai -o wide

# Check nodes on Singapore
kubectl get nodes --context=gke-singapore -o wide

# Check namespaces on Mumbai
kubectl get namespaces --context=gke-mumbai

# Check namespaces on Singapore
kubectl get namespaces --context=gke-singapore
```

---

## Cost Snapshot After Phase 2

| Resource | Rate | Running cost |
|----------|------|-------------|
| gke-mumbai control plane | $0.10/hr | $0.10/hr |
| gke-mumbai nodes (2× e2-medium) | $0.067/hr each | $0.134/hr |
| gke-singapore control plane | $0.10/hr | $0.10/hr |
| gke-singapore nodes (2× e2-medium) | $0.067/hr each | $0.134/hr |
| **Total after Phase 2** | | **~$0.47/hr** |

> ⚠️ Clusters cost money even when idle. If taking a break, note the time.
> Run `./scripts/cleanup.sh` when done with the full lab.

---

## Summary

✅ Both clusters provisioned (K8s 1.35, e2-medium, 2 nodes each)  
✅ VPC-native networking enabled (required for GLB NEGs in Phase 7)  
✅ Workload Identity enabled (production security best practice)  
✅ Network policy enabled (required for Phase 8 partition simulation)  
✅ kubeconfigs fetched and contexts renamed to friendly names  
✅ Namespaces pre-created on both clusters  
✅ Connectivity verified — nodes in Ready state  

**Next → Phase 3: Install ArgoCD and Register Both Clusters**
