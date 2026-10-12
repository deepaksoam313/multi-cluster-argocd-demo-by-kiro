# Phase 3: Install ArgoCD and Register Clusters

## What Are We Doing in This Phase?

We are installing **ArgoCD** — a GitOps continuous delivery tool — on Cluster 1
(Mumbai) and configuring it to manage deployments on BOTH clusters from a
single control plane.

By the end of this phase:
- ArgoCD runs on `gke-mumbai` (the hub cluster)
- ArgoCD has credentials to also deploy to `gke-singapore` (remote cluster)
- You can open the ArgoCD UI and see both clusters registered
- ArgoCD is ready to deploy applications in Phase 4 & 5

---

## What is GitOps? (The Mental Model)

Before understanding ArgoCD, understand GitOps.

### Traditional deployment flow (imperative):
```
Developer → runs kubectl apply → cluster changes
              OR
Developer → runs helm upgrade → cluster changes
```
Problem: no audit trail, easy to drift, hard to reproduce, manual.

### GitOps flow (declarative):
```
Developer → pushes to Git → ArgoCD detects change → cluster changes
```

The Git repository is the **single source of truth**.
The cluster always reflects what is in Git — nothing more, nothing less.

### The Four GitOps Principles:
1. **Declarative** — describe desired state (YAML), not steps
2. **Versioned** — Git history = full audit log of every change
3. **Pulled automatically** — ArgoCD pulls from Git, not pushed from CI
4. **Continuously reconciled** — ArgoCD detects and fixes drift continuously

```
Without GitOps:                    With GitOps (ArgoCD):
──────────────────                 ──────────────────────────
kubectl apply ──► cluster          Git push ──► ArgoCD ──► cluster
                                              ▲
                                              │ polls every 3 min
                                              │ or instant via webhook
                                              Git repo
```

---

## What is ArgoCD?

ArgoCD is a **Kubernetes-native GitOps controller** that:

1. Watches a Git repository for YAML/Helm/Kustomize manifests
2. Compares what is in Git vs what is running in the cluster
3. If there is a diff → syncs the cluster to match Git (if auto-sync enabled)
4. Shows health status of every resource it manages
5. Can manage **multiple clusters** from a single ArgoCD instance

### ArgoCD Components

When you install ArgoCD, these pods run in the `argocd` namespace:

```
argocd-server
  └── Web UI + REST API + gRPC API
  └── This is what you open in the browser
  └── ArgoCD CLI talks to this

argocd-repo-server
  └── Clones git repos
  └── Runs Helm template / kustomize build
  └── Generates final K8s manifests to apply

argocd-application-controller
  └── The core reconciliation loop
  └── Compares live state vs desired state (git)
  └── Triggers syncs when drift detected
  └── Reports health of all managed resources

argocd-applicationset-controller
  └── Manages ApplicationSet resources
  └── Generates multiple Applications from templates
  └── This is key for multi-cluster deployments (Phase 5)

argocd-dex-server
  └── Handles SSO / OAuth integration
  └── We use local admin login for this lab

argocd-redis
  └── Caching layer for ArgoCD's internal state
  └── Speeds up UI and reduces load on K8s API
```

---

## Why Install ArgoCD Only on Cluster 1 (Mumbai)?

This is the **hub-and-spoke** model.

```
Hub (gke-mumbai):                  Spoke (gke-singapore):
────────────────────               ───────────────────────
ArgoCD installed here              ArgoCD NOT installed
Has credentials for:               Has only:
  - itself (in-cluster)              - argocd-manager ServiceAccount
  - gke-singapore (remote)           - ClusterRoleBinding for above
```

### Why not install ArgoCD on both?

Option: Install ArgoCD on each cluster (peer model)
- Doubles operational overhead
- Two UIs to check, two configs to maintain
- Sync conflicts possible if both try to reconcile the same git state
- Harder to get a unified view

Option: Install once on hub, manage all clusters from there (our choice)
- Single UI, single source of truth
- Add a new cluster = just register it, no new ArgoCD install
- Easier auditing — all deployments visible in one place
- Industry standard pattern for < 50 clusters

For very large setups (100s of clusters), you'd look at ArgoCD's
multi-instance federation, but that's out of scope here.

---

## How Does ArgoCD Deploy to a Remote Cluster?

This is the magic — how does ArgoCD on Mumbai reach inside Singapore's cluster?

### Step-by-step:

```
1. You run: argocd cluster add gke-singapore
             │
             ▼
2. ArgoCD CLI reads gke-singapore context from ~/.kube/config
   (contains Singapore's API server URL + your current credentials)
             │
             ▼
3. ArgoCD connects to Singapore's API server using YOUR credentials
   and creates these resources in Singapore:
   
   Namespace:            argocd           (if not exists)
   ServiceAccount:       argocd-manager   (in kube-system)
   ClusterRole:          argocd-manager-role   (cluster-admin)
   ClusterRoleBinding:   argocd-manager-rolebinding
             │
             ▼
4. ArgoCD retrieves the argocd-manager ServiceAccount token
             │
             ▼
5. ArgoCD stores this as a Secret in gke-mumbai's argocd namespace:
   
   Secret name: cluster-<hash-of-singapore-url>
   Contents:
     - server: https://<singapore-api-endpoint>
     - caData: <base64 singapore CA certificate>
     - bearerToken: <argocd-manager service account token>
             │
             ▼
6. From now on, ArgoCD uses this Secret to authenticate to Singapore.
   Your local kubeconfig is no longer needed.
```

### What this means:
- ArgoCD has **permanent** access to Singapore via a K8s ServiceAccount
- The ServiceAccount token is stored as a K8s Secret in Mumbai
- No SSH, no VPN, no VPC peering required — just HTTPS to the K8s API
- Singapore's API server is accessible publicly (GKE endpoint is public by default)

### Security note:
The `argocd-manager` ServiceAccount has `cluster-admin` role in Singapore.
In production you would scope this to specific namespaces.
For this lab, cluster-admin is fine.

---

## ArgoCD Projects

An ArgoCD **Project** is an access boundary — it controls:
- Which Git repos can be used as sources
- Which clusters/namespaces can be used as destinations
- Which K8s resource types are allowed

We create a project called `multi-region-demo`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: multi-region-demo
spec:
  sourceRepos:
    - '*'          # any git repo (restrict in production)
  destinations:
    - server: '*'  # any cluster (restrict in production)
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'    # allow cluster-level resources
```

In production you would restrict `sourceRepos` to your org's GitHub
and `destinations` to specific cluster/namespace combinations.

---

## Accessing the ArgoCD UI

ArgoCD's server is exposed as a Kubernetes Service. By default it is
type `ClusterIP` (no external access). We patch it to `LoadBalancer`
so GCP provisions an external IP for us.

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'
```

GCP then:
1. Provisions a Network Load Balancer (Layer 4)
2. Assigns a static external IP
3. Routes port 80/443 to the argocd-server pod

Alternative (without LoadBalancer, saves cost):
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access at https://localhost:8080
```

For this lab we use LoadBalancer so the UI is persistently accessible.

### Initial Admin Password

ArgoCD auto-generates an initial admin password and stores it as a
Kubernetes Secret during install:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

This password should be changed after first login in production.

---

## ArgoCD CLI

The `argocd` CLI is a companion tool to the UI. We use it for:
- Logging in: `argocd login <server>`
- Cluster management: `argocd cluster add/list/rm`
- App management: `argocd app sync/get/list`
- Rollbacks: `argocd app rollback`

The CLI communicates with argocd-server over gRPC (port 443).

---

## What Could Go Wrong (and How to Fix It)

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| ArgoCD pods in `Pending` | Insufficient node resources | Check: `kubectl describe pod -n argocd` for resource pressure |
| LoadBalancer IP stays `<pending>` | GCP LB provisioning takes time | Wait 3-5 min. Check: `kubectl describe svc argocd-server -n argocd` |
| `argocd login` fails with TLS error | Self-signed cert | Add `--insecure` flag |
| `argocd cluster add` permission denied | Insufficient local kubeconfig perms | Ensure your gcloud auth has K8s admin |
| Singapore cluster shows `Unknown` | API server unreachable | Check GKE private cluster settings; public endpoint should work |
| ArgoCD shows `OutOfSync` immediately | No apps deployed yet | Normal — apps come in Phase 5 |
| `argocd-redis` CrashLoopBackOff | Memory pressure | Nodes need time; e2-medium has enough once settled |

---

## Step-by-Step: What the Scripts Do

### `scripts/02-install-argocd.sh`

```
Step 1: Switch kubectl context to gke-mumbai
Step 2: kubectl apply ArgoCD stable manifest
         └── ~20 K8s resources (Deployments, Services, CRDs, RBAC)
         └── CRDs installed: Application, ApplicationSet, AppProject
Step 3: Wait for argocd-server + argocd-repo-server deployments
         └── These are the critical pods; others start faster
Step 4: Patch argocd-server Service to LoadBalancer
Step 5: Wait for external IP from GCP
Step 6: Read initial admin password from Secret
Step 7: Install argocd CLI binary to /usr/local/bin/argocd
Step 8: argocd login <ip> --username admin --insecure
```

### `scripts/03-register-clusters.sh`

```
Step 1: Verify argocd CLI is logged in
Step 2: argocd cluster add gke-singapore
         └── Reads ~/.kube/config for gke-singapore context
         └── Creates argocd-manager SA + RBAC in Singapore
         └── Stores credentials as Secret in Mumbai argocd namespace
Step 3: argocd cluster list → verify both show "Successful"
Step 4: Label the cluster secrets with region= label
         └── These labels are used by ApplicationSet in Phase 5
Step 5: Create AppProject: multi-region-demo
```

---

## Executing Phase 3

```bash
cd /home/deepak.kumar30/multi-region-demo

# Install ArgoCD on Mumbai
./scripts/02-install-argocd.sh

# Register Singapore with ArgoCD
./scripts/03-register-clusters.sh
```

Expected total time: **5-8 minutes**

---

## Verification Commands (Run After the Scripts)

```bash
# Check ArgoCD pods are all Running
kubectl get pods -n argocd --context=gke-mumbai

# Expected (all Running):
# NAME                                       READY   STATUS
# argocd-application-controller-0            1/1     Running
# argocd-applicationset-controller-xxx       1/1     Running
# argocd-dex-server-xxx                      1/1     Running
# argocd-notifications-controller-xxx        1/1     Running
# argocd-redis-xxx                           1/1     Running
# argocd-repo-server-xxx                     1/1     Running
# argocd-server-xxx                          1/1     Running

# Check ArgoCD external IP
kubectl get svc argocd-server -n argocd --context=gke-mumbai

# List registered clusters
argocd cluster list

# Expected:
# SERVER                              NAME           STATUS       MESSAGE
# https://kubernetes.default.svc      in-cluster     Successful
# https://<singapore-ip>              gke-singapore  Successful

# Check argocd-manager SA was created in Singapore
kubectl get serviceaccount argocd-manager \
  -n kube-system --context=gke-singapore

# Check the cluster secret was created in Mumbai
kubectl get secrets -n argocd --context=gke-mumbai \
  -l argocd.argoproj.io/secret-type=cluster
```

---

## Quick Reference: ArgoCD Key Commands

```bash
# Login
argocd login <ARGOCD_IP> --username admin --insecure

# List clusters
argocd cluster list

# List apps (empty until Phase 5)
argocd app list

# Sync an app manually
argocd app sync <app-name>

# Get app details
argocd app get <app-name>

# Watch sync status
argocd app list --watch

# Rollback an app
argocd app rollback <app-name> <revision>
```

---

## Actual Deployment Values (Phase 3 Completed)

| Item | Value |
|------|-------|
| ArgoCD version installed | stable (v2.x latest) |
| ArgoCD CLI version | v3.5.4 |
| ArgoCD server external IP | `35.200.130.47` |
| ArgoCD UI URL | `http://35.200.130.47` |
| Admin username | `admin` |
| Admin password | `ISmy5X9fZGkUshXW` |
| Singapore cluster secret | `cluster-34.143.165.98-3458618292` |
| Singapore API server | `https://34.143.165.98` |
| ArgoCD CLI location | `~/.local/bin/argocd` |

### Quick Resume Commands
```bash
export PATH="$HOME/.local/bin:$PATH"
argocd login 35.200.130.47 --username admin --password ISmy5X9fZGkUshXW --insecure
argocd cluster list
```

---

## Summary

✅ ArgoCD installed on gke-mumbai — all 7 pods Running  
✅ ArgoCD UI accessible at http://35.200.130.47  
✅ ArgoCD CLI v3.5.4 installed at ~/.local/bin/argocd  
✅ gke-singapore registered — argocd-manager SA + ClusterRoleBinding created  
✅ Singapore API connectivity verified (HTTP 200 with stored token)  
✅ AppProject `multi-region-demo` created  

**Next → Phase 4: Create Kubernetes Manifests for the Three Microservices**
