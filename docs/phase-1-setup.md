# Phase 1: Project Setup & Documentation Framework

## Objective
Set up the project workspace, understand the architecture, and verify all
prerequisites are in place before touching any GCP resources.

---

## 1.1 Architecture Deep Dive

### What is Active-Active?

In an **active-active** multi-region setup:
- ALL regions serve **live production traffic simultaneously**
- No region is in standby — every region handles reads AND writes
- If one region fails, traffic automatically shifts to remaining regions
- Contrast with **active-passive** where one region is always idle (hot standby)

```
Active-Active:                    Active-Passive:
                                  
Region A ──► serves traffic       Region A ──► serves traffic
Region B ──► serves traffic       Region B ──► STANDBY (idle)

Both healthy = both serve         Both healthy = only A serves
A fails = B takes 100%            A fails = B activates (lag!)
```

### Why Multi-Region?

| Concern | Solution |
|---------|---------|
| Low latency | Route users to nearest region |
| High availability | No single point of failure |
| Disaster recovery | Region failure = zero downtime |
| Compliance | Data residency requirements |
| Scale | Distribute load across regions |

---

## 1.2 Component Roles

### GKE (Google Kubernetes Engine)
- Managed Kubernetes — GCP handles control plane
- Each region gets its own independent cluster
- Clusters do NOT share state — ArgoCD ensures config consistency

### ArgoCD (GitOps Controller)
- Installed ONCE on Cluster 1 (Mumbai) — this is the **hub**
- Watches a Git repository for changes
- Automatically syncs manifests to BOTH clusters
- Single pane of glass for deployment status across all clusters

```
Git Repo (source of truth)
       │
       ▼
   ArgoCD (hub on cluster-1)
   ├── syncs ──► cluster-1 (local)
   └── syncs ──► cluster-2 (remote via kubeconfig)
```

### ApplicationSet (ArgoCD)
- An ArgoCD resource that generates multiple `Application` resources
- One ApplicationSet definition → deploys to N clusters automatically
- Add a new cluster? Just add it to the ApplicationSet — no new manifests needed

### Prometheus + Grafana
- **Prometheus**: scrapes metrics from pods, nodes, K8s API
- **Grafana**: visualizes metrics, builds dashboards
- Strategy: each cluster has its own Prometheus, both **remote_write** to 
  a central Grafana in cluster-1 for a unified view

---

## 1.3 Prerequisites Verification

```bash
# Verify gcloud
gcloud version

# Verify kubectl
kubectl version --client

# Verify helm
helm version

# Verify active GCP account
gcloud auth list

# Verify project
gcloud config get-value project
```

### Expected Output
- gcloud: 588.0.0+
- kubectl: v1.35+
- helm: v3+
- Active account: deepaksoam313@gmail.com
- Project: skilled-text-468416-g3

---

## 1.4 Environment Variables

These variables are used across all scripts. Source this file before running any script:

```bash
source scripts/env.sh
```

See `scripts/env.sh` for all variables.

---

## 1.5 Project Directory Structure

```
multi-region-demo/
├── README.md
├── docs/                    ← You are here
├── clusters/                ← Cluster-specific kubeconfigs and configs
├── gitops/                  ← ArgoCD application definitions
│   ├── apps/                ← Per-service manifests
│   ├── appsets/             ← ApplicationSet definitions
│   └── monitoring/          ← Prometheus/Grafana configs
├── manifests/base/          ← Base K8s manifests
└── scripts/                 ← Executable shell scripts
```

---

## 1.6 Cost Estimate

Running this lab for ~4 hours:

| Resource | Type | Count | Est. Cost |
|----------|------|-------|-----------|
| GKE nodes | e2-medium | 4 (2 per cluster) | ~$0.40/hr |
| GKE cluster fee | - | 2 | $0.20/hr |
| Global LB | - | 1 | $0.025/hr |
| **Total** | | | **~$0.65/hr** |

> Always run `scripts/cleanup.sh` after the lab to avoid unexpected charges.

---

## Summary

✅ Architecture understood  
✅ Prerequisites verified  
✅ Project structure created  
✅ Documentation framework in place  

**Next → Phase 2: Create GKE Clusters**
