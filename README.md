# Multi-Region Active-Active GKE Setup

A complete hands-on lab for building a production-grade multi-region Kubernetes
architecture using GCP GKE, ArgoCD (GitOps), and Prometheus/Grafana monitoring.

Each phase has a dedicated documentation file in `docs/` that explains:
- What we are doing and WHY
- Every design decision with tradeoffs
- Deep dives into how each technology works
- Step-by-step script breakdown
- Verification commands
- Troubleshooting guide

If you are returning to this lab or picking it up for the first time,
start by reading the doc for the phase you want to understand.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      ArgoCD (GitOps Hub)                        │
│            Installed on Cluster 1 (Mumbai) only                 │
│            Manages deployments to BOTH clusters                 │
└──────┬──────────────────────────────────────────┬───────────────┘
       │  deploys to                              │  deploys to
       ▼                                          ▼
┌─────────────────────┐              ┌─────────────────────┐
│  GKE Cluster 1      │              │  GKE Cluster 2      │
│  asia-south1        │              │  asia-southeast1    │
│  (Mumbai) ● Active  │              │  (Singapore) ●Active│
│                     │              │                     │
│  order-svc × 2      │              │  order-svc × 2      │
│  product-svc × 2    │              │  product-svc × 2    │
│  user-svc × 2       │              │  user-svc × 2       │
│                     │              │                     │
│  Prometheus         │◄─remote_────►│  Prometheus         │
│  Grafana (unified)  │   write      │  (no Grafana)       │
└──────────┬──────────┘              └──────────┬──────────┘
           │ NEG                                │ NEG
           └──────────────┬─────────────────────┘
                          │
               ┌──────────▼──────────┐
               │  GCP Global HTTP LB │
               │  Anycast IP         │
               │  Health: 5s checks  │
               │  Failover: ~15s     │
               └──────────┬──────────┘
                          │
                 Users (anywhere in world)
```

---

## What "Active-Active" Means Here

Both clusters serve real production traffic simultaneously.
Neither is a standby. If one region fails:
- The Global Load Balancer detects it within ~15 seconds
- All traffic automatically shifts to the surviving region
- No DNS changes, no manual intervention, no downtime

When the failed region recovers:
- GLB detects recovery within ~10 seconds
- Traffic automatically redistributes across both regions

---

## Quick Start (If Returning to the Lab)

```bash
cd /home/deepak.kumar30/multi-region-demo

# Load environment variables (do this first every session)
source scripts/env.sh

# Check where you left off
gcloud container clusters list --project=skilled-text-468416-g3
kubectl config get-contexts
argocd cluster list 2>/dev/null || echo "ArgoCD not yet installed"
```

Then pick up at the appropriate phase script below.

---

## Phase Execution Order

```bash
# Phase 2: Create both GKE clusters (~8 min)
./scripts/01-create-clusters.sh

# Phase 3a: Install ArgoCD on Mumbai (~6 min)
./scripts/02-install-argocd.sh

# Phase 3b: Register Singapore with ArgoCD (~2 min)
./scripts/03-register-clusters.sh

# Phase 4+5: Deploy microservices to both clusters via Kustomize (~5 min)
./scripts/04-deploy-apps.sh

# Phase 6: Install Prometheus + Grafana (~10 min)
./scripts/05-setup-monitoring.sh

# Phase 7: Create Global Load Balancer (~15 min including propagation)
./scripts/06-setup-glb.sh

# Phase 8: Simulate failover and observe (~20 min)
./scripts/07-simulate-failover.sh

# CLEANUP (always run when done!)
./scripts/cleanup.sh
```

---

## Project Structure

```
multi-region-demo/
│
├── README.md                        ← You are here
│
├── docs/                            ← Phase-by-phase deep documentation
│   ├── phase-1-setup.md             ← Architecture overview, prerequisites
│   ├── phase-2-clusters.md          ← GKE cluster design, every flag explained
│   ├── phase-3-argocd.md            ← GitOps concepts, ArgoCD internals
│   ├── phase-4-manifests.md         ← K8s manifests, Kustomize deep dive
│   ├── phase-5-applicationset.md    ← ApplicationSet, GitOps automation
│   ├── phase-6-monitoring.md        ← Prometheus, Grafana, remote_write
│   ├── phase-7-load-balancer.md     ← GLB components, Anycast, NEGs
│   └── phase-8-failover.md          ← Failover mechanics, chaos engineering
│
├── scripts/                         ← Executable scripts, one per phase
│   ├── env.sh                       ← Source this first (sets all variables)
│   ├── 01-create-clusters.sh        ← Phase 2
│   ├── 02-install-argocd.sh         ← Phase 3a
│   ├── 03-register-clusters.sh      ← Phase 3b
│   ├── 04-deploy-apps.sh            ← Phase 4+5
│   ├── 05-setup-monitoring.sh       ← Phase 6
│   ├── 06-setup-glb.sh              ← Phase 7
│   ├── 07-simulate-failover.sh      ← Phase 8
│   └── cleanup.sh                   ← Delete everything
│
├── manifests/
│   └── base/                        ← Base K8s manifests (region-agnostic)
│       ├── order-svc/               ← deployment.yaml, service.yaml, hpa.yaml
│       ├── product-svc/
│       └── user-svc/
│
├── gitops/
│   ├── apps/                        ← Kustomize overlays per service per region
│   │   ├── order-svc/
│   │   │   └── overlays/
│   │   │       ├── mumbai/          ← patches args + labels for Mumbai
│   │   │       └── singapore/       ← patches args + labels for Singapore
│   │   ├── product-svc/
│   │   └── user-svc/
│   ├── appsets/
│   │   └── microservices-appset.yaml  ← ArgoCD ApplicationSet definition
│   └── monitoring/
│       ├── values-mumbai.yaml         ← kube-prometheus-stack values (Mumbai)
│       └── values-singapore.yaml      ← kube-prometheus-stack values (Singapore)
│
└── clusters/                          ← Cluster-specific notes and configs
    ├── cluster-mumbai/
    └── cluster-singapore/
```

---

## Technologies Used

| Tool | Version | Purpose |
|------|---------|---------|
| GCP GKE | K8s 1.35 | Managed Kubernetes clusters |
| ArgoCD | stable | GitOps continuous delivery |
| Kustomize | built-in kubectl | K8s config overlays |
| Prometheus | via kube-prometheus-stack | Metrics collection |
| Grafana | via kube-prometheus-stack | Metrics visualization |
| hashicorp/http-echo | latest | Lightweight test microservice |
| Helm | 3.x | Deploy monitoring stack |
| gcloud CLI | 588.0.0 | GCP resource management |

---

## Regions and Clusters

| Name | Region | Zone | Nodes | Role |
|------|--------|------|-------|------|
| gke-mumbai | asia-south1 | asia-south1-a | 2 × e2-medium | Primary (ArgoCD hub) |
| gke-singapore | asia-southeast1 | asia-southeast1-a | 2 × e2-medium | Secondary |

---

## Microservices

| Service | Image | Port | Response |
|---------|-------|------|----------|
| order-svc | hashicorp/http-echo | 8080 | `{"service":"order","region":"...","cluster":"...","status":"ok"}` |
| product-svc | hashicorp/http-echo | 8080 | `{"service":"product","region":"...","cluster":"...","status":"ok"}` |
| user-svc | hashicorp/http-echo | 8080 | `{"service":"user","region":"...","cluster":"...","status":"ok"}` |

The `region` and `cluster` fields in the response change per overlay,
letting you verify which region served each request.

---

## Cost Estimate

| Phase | Resources Added | Running Cost |
|-------|----------------|-------------|
| After Phase 2 | 2 GKE clusters (4 nodes) | ~$0.47/hr |
| After Phase 6 | + monitoring pods (no new VMs) | ~$0.47/hr |
| After Phase 7 | + Global LB | ~$0.50/hr |
| **Full lab** | | **~$0.50/hr** |

Full lab for 4 hours ≈ **$2.00**

> ⚠️ Always run `./scripts/cleanup.sh` when done.
> Forgetting for a week = ~$85 wasted.

---

## Glossary

| Term | Definition |
|------|-----------|
| Active-Active | All regions serve live traffic simultaneously (vs Active-Passive where one waits) |
| GitOps | Using Git as the single source of truth for infrastructure state |
| ApplicationSet | ArgoCD resource that generates multiple Applications from a template |
| NEG | Network Endpoint Group — GCP object that maps to individual pod IPs |
| Anycast | One IP announced from multiple locations; traffic goes to nearest |
| remote_write | Prometheus feature to forward metrics to another Prometheus instance |
| Kustomize | Template-free K8s config customization via base + overlay patches |
| self-heal | ArgoCD feature that reverts manual cluster changes to match Git |
| sync-wave | ArgoCD ordering mechanism for resource creation sequence |
| PromQL | Prometheus Query Language used to query metrics in Grafana |
