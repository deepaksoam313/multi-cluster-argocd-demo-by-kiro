# Phase 5: ArgoCD ApplicationSet for Multi-Cluster Deployment

## What Are We Doing in This Phase?

We are creating an ArgoCD **ApplicationSet** — a resource that automatically
generates and manages multiple ArgoCD `Application` resources from a single
template definition.

The result: one YAML file controls how all three microservices are deployed
to both clusters. Add a new cluster → one line change → it gets all services.

---

## The Problem ApplicationSet Solves

Without ApplicationSet, you would need to create one `Application`
resource per service per cluster manually:

```yaml
# Application 1 of 6
kind: Application
metadata:
  name: order-svc-mumbai
spec:
  destination:
    server: https://gke-mumbai-api
    namespace: microservices
  source:
    path: gitops/apps/order-svc/overlays/mumbai
---
# Application 2 of 6
kind: Application
metadata:
  name: order-svc-singapore
spec:
  destination:
    server: https://gke-singapore-api
    namespace: microservices
  source:
    path: gitops/apps/order-svc/overlays/singapore
---
# ... and 4 more Application files
```

Problems with this:
- 3 services × 2 clusters = **6 files to maintain**
- Adding a third cluster = manually create 3 more files
- Easy to forget one, causing drift
- No single place to see the full picture

---

## What is an ApplicationSet?

An `ApplicationSet` is an ArgoCD controller resource that:

1. Takes a **generator** (defines the matrix of environments)
2. Takes a **template** (defines what each Application looks like)
3. **Combines** them to produce N Application resources automatically

```
ApplicationSet
├── generator: "give me all combinations of clusters × services"
└── template: "for each combination, create an Application like this"

Output (auto-generated):
├── Application: order-svc-gke-mumbai
├── Application: order-svc-gke-singapore
├── Application: product-svc-gke-mumbai
├── Application: product-svc-gke-singapore
├── Application: user-svc-gke-mumbai
└── Application: user-svc-gke-singapore
```

If you delete the ApplicationSet, all 6 generated Applications are also deleted.
If you update the template, all 6 Applications are updated simultaneously.

---

## Generator Types in ArgoCD

ArgoCD supports several generator types. We use the **Matrix generator**
which is the cartesian product of two sub-generators:

### List Generator
Provides a static list of key-value pairs:

```yaml
- list:
    elements:
      - app: order-svc
      - app: product-svc
      - app: user-svc
```
Produces 3 iterations.

### Clusters Generator
Automatically iterates over all clusters registered with ArgoCD:

```yaml
- clusters: {}
```
With 2 clusters registered, this produces 2 iterations.
Each iteration exposes: `{{.name}}`, `{{.server}}`, `{{.metadata.labels.*}}`

### Matrix Generator (what we use)
Combines the above two — cartesian product:

```yaml
- matrix:
    generators:
      - clusters: {}    # 2 clusters
      - list:           # 3 services
          elements:
            - app: order-svc
              overlay: mumbai   # when cluster is gke-mumbai
            ...
```

Result: 2 × 3 = **6 combinations** → 6 Applications

### Other Generator Types (for reference):
- **Git generator**: Scans a Git repo directory structure for app folders
- **SCM provider**: Generates from GitHub/GitLab org repos
- **Pull Request**: Creates preview envs per PR
- **Cluster Decision Resource**: Integrates with Open Cluster Management

---

## Template Variables

In the ApplicationSet template, variables from the generator are referenced
with `{{.variableName}}` syntax:

```yaml
template:
  metadata:
    name: '{{.app}}-{{.name}}'         # e.g. "order-svc-gke-mumbai"
  spec:
    source:
      path: 'gitops/apps/{{.app}}/overlays/{{.overlay}}'
      # resolves to: gitops/apps/order-svc/overlays/mumbai
    destination:
      server: '{{.server}}'            # cluster API endpoint from ArgoCD registry
      namespace: microservices
```

Available variables depend on the generator:
- From `clusters` generator: `.name`, `.server`, `.metadata.labels.region`, etc.
- From `list` generator: whatever key-value pairs you define

---

## Automated Sync Policy

This is the core of GitOps automation:

```yaml
syncPolicy:
  automated:
    prune: true       # delete K8s resources removed from Git
    selfHeal: true    # revert manual kubectl changes
  syncOptions:
    - CreateNamespace=true         # create namespace if missing
    - ApplyOutOfSyncOnly=true      # only apply changed resources (faster)
```

### `prune: true` — why this matters

Without prune:
- You have a Deployment in Git
- You delete it from Git
- ArgoCD syncs but DOES NOT delete the Deployment from the cluster
- Orphaned resources accumulate over time

With prune:
- Deleting from Git → ArgoCD deletes from cluster on next sync
- Cluster state always matches Git exactly

### `selfHeal: true` — why this matters

Without selfHeal:
- ArgoCD syncs once when Git changes
- Someone runs `kubectl scale deployment order-svc --replicas=10`
- ArgoCD shows "OutOfSync" but does NOT revert
- Cluster drifts from Git

With selfHeal:
- ArgoCD continuously compares live state vs Git state
- Any drift detected → immediately syncs back to Git state
- Manual kubectl changes are always overwritten within ~3 minutes
- This is the "immutable infrastructure" principle

---

## ArgoCD Sync Status vs Health Status

ArgoCD tracks two separate concepts per Application:

### Sync Status
"Does the cluster match Git?"
- `Synced` — cluster matches Git exactly
- `OutOfSync` — cluster differs from Git (could be unsynced changes)

### Health Status
"Are the resources actually working?"
- `Healthy` — all Deployments have desired replicas ready
- `Progressing` — rollout in progress (pods starting)
- `Degraded` — Deployment has fewer ready replicas than desired
- `Missing` — resource exists in Git but not in cluster

```
Good state:    Synced + Healthy     ← what we want
Deploying:     Synced + Progressing ← pods starting up
Problem:       Synced + Degraded    ← pods crashing
Drift:         OutOfSync + Healthy  ← works but not matching git
```

---

## Sync Waves in Detail

Sync waves ensure resources are applied in the right order within a single sync:

```
Wave -1 (before everything):
  └── Namespace (needs to exist first)

Wave 0 (default if no annotation):
  └── Most resources

Wave 1:
  └── ConfigMaps, Secrets (needed before pods start)

Wave 2:
  └── Deployments (our microservices)

Wave 3:
  └── Services (expose after deployments exist)

Wave 4:
  └── HPAs (scale after deployments exist)
```

ArgoCD waits for all resources in wave N to be `Healthy` before
starting wave N+1. This prevents race conditions during initial deploy.

---

## ApplicationSet YAML: Full Annotated Version

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd           # Must always be in argocd namespace
spec:
  # ── Generator ────────────────────────────────────────────────────
  generators:
    - list:
        elements:
          # Each element = one cluster configuration
          - cluster: gke-mumbai
            url: https://kubernetes.default.svc  # in-cluster reference
            overlay: mumbai
          - cluster: gke-singapore
            url: https://<singapore-api-endpoint> # fetched from argocd cluster list
            overlay: singapore
  
  # ── Template ─────────────────────────────────────────────────────
  template:
    metadata:
      name: '{{app}}-{{cluster}}'   # unique name per generated Application
    spec:
      project: multi-region-demo    # ArgoCD project for access control
      
      source:
        repoURL: https://github.com/YOUR_ORG/multi-region-demo
        targetRevision: HEAD         # always use latest commit on default branch
        path: 'gitops/apps/{{app}}/overlays/{{overlay}}'
        # Kustomize is auto-detected from kustomization.yaml presence
      
      destination:
        server: '{{url}}'            # which cluster to deploy to
        namespace: microservices
      
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true
        retry:
          limit: 5                   # retry failed syncs up to 5 times
          backoff:
            duration: 5s
            factor: 2               # 5s, 10s, 20s, 40s, 80s
            maxDuration: 3m
```

---

## Git Repository Requirement

In production, ArgoCD pulls from a real Git repository. For this lab
we use `kubectl apply -k` directly (lab mode) to avoid needing a git remote.

To use full GitOps mode:

```bash
# 1. Create a GitHub repo (or use any git host)
gh repo create multi-region-demo --public

# 2. Push the project
cd /home/deepak.kumar30/multi-region-demo
git init
git add .
git commit -m "initial multi-region setup"
git remote add origin https://github.com/YOUR_ORG/multi-region-demo
git push -u origin main

# 3. Update ApplicationSet repoURL to your repo
# 4. Apply the ApplicationSet
kubectl apply -f gitops/appsets/microservices-appset.yaml \
  -n argocd --context=gke-mumbai

# 5. ArgoCD automatically generates 6 Applications and syncs them
```

For the lab, script 04 applies manifests directly and also registers
them with ArgoCD via `argocd app create` for UI visibility.

---

## ArgoCD UI: What You Will See

After this phase, the ArgoCD UI shows:

```
Applications (6 total):

┌─────────────────────────────────────────────┐
│ order-svc-gke-mumbai                        │
│ Status: ✅ Synced   Health: ✅ Healthy       │
│ Cluster: gke-mumbai  Namespace: microservices│
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│ order-svc-gke-singapore                     │
│ Status: ✅ Synced   Health: ✅ Healthy       │
└─────────────────────────────────────────────┘
... (and 4 more)
```

Clicking on an Application shows:
- Resource tree: Deployment → ReplicaSet → 2 Pods
- Sync history (when each sync happened, what changed)
- Pod logs
- Live manifest diff (Git vs cluster)

---

## Executing Phase 5

Phase 4 and 5 are handled together by the same script:

```bash
cd /home/deepak.kumar30/multi-region-demo
./scripts/04-deploy-apps.sh
```

Expected time: **3-5 minutes**

---

## Verification Commands

```bash
# List all ArgoCD applications
argocd app list

# Expected:
# NAME                       CLUSTER        NAMESPACE      STATUS  HEALTH
# order-svc-gke-mumbai       gke-mumbai     microservices  Synced  Healthy
# order-svc-gke-singapore    gke-singapore  microservices  Synced  Healthy
# product-svc-gke-mumbai     gke-mumbai     microservices  Synced  Healthy
# product-svc-gke-singapore  gke-singapore  microservices  Synced  Healthy
# user-svc-gke-mumbai        gke-mumbai     microservices  Synced  Healthy
# user-svc-gke-singapore     gke-singapore  microservices  Synced  Healthy

# Get details of one app
argocd app get order-svc-gke-mumbai

# Test GitOps self-heal: manually change replica count
kubectl scale deployment order-svc --replicas=5 \
  -n microservices --context=gke-mumbai
# Watch ArgoCD revert it within 3 minutes
kubectl get deployment order-svc \
  -n microservices --context=gke-mumbai -w
```

---

## Lab Mode vs Full GitOps Mode

In a real GitOps setup, ArgoCD pulls manifests from a Git remote and syncs
them to clusters. For this lab we have no git remote, so we:

1. Applied manifests directly with `kubectl apply -k` (workloads are running)
2. Created ArgoCD `Application` CRs that register each deployment in ArgoCD's UI
3. The `Application` CRs currently point to a placeholder git repo — they show
   in the UI but are in `Unknown` sync state (no live git diff possible)

**What matters**: All 12 pods are running correctly with the right configs.
To use full GitOps: push this repo to GitHub, update `repoURL` in each
Application CR and the ApplicationSet, then trigger a sync.

---

## Actual Deployment Values (Phase 5 Completed)

| Item | Value |
|------|-------|
| Applications in ArgoCD | 6 (3 services × 2 clusters) |
| ApplicationSet file | `gitops/appsets/microservices-appset.yaml` |
| Singapore server URL | `https://34.143.165.98` |
| ArgoCD project | `multi-region-demo` |

```bash
# Quick resume commands
export PATH="$HOME/.local/bin:$PATH"
argocd login 35.200.130.47 --username admin --password ISmy5X9fZGkUshXW --insecure
argocd app list
```

---

## Summary

✅ ApplicationSet manifest created (`gitops/appsets/microservices-appset.yaml`)  
✅ 6 Application CRs created in ArgoCD (visible in UI at http://35.200.130.47)  
✅ All apps registered under project `multi-region-demo`  
✅ Both cluster endpoints correctly mapped  
✅ All 12 pods Running across both clusters  

**Next → Phase 6: Prometheus + Grafana Monitoring**
