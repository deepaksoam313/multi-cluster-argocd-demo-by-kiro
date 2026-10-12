# Phase 8: Failover Simulation and Observability

## What Are We Doing in This Phase?

We are **intentionally breaking one region** and watching the entire system
respond automatically — without any human intervention.

This is the payoff phase. Everything we built comes together here:
- The GLB detects the failure and reroutes traffic (Phase 7)
- Grafana shows the failure in real time (Phase 6)
- ArgoCD self-heal demonstrates GitOps discipline (Phase 3)

By the end of this phase, you will have witnessed:
1. Normal active-active operation (both regions serving)
2. Automatic failover when Singapore goes down (~15s)
3. Real-time visibility in Grafana
4. Automatic recovery when Singapore comes back (~10s)
5. ArgoCD reverting a manual change (self-heal)

---

## Why Simulate Failures?

In production systems, **failures are inevitable**. The question is not
"will something fail?" but "how does our system respond when it does?"

Testing failure scenarios before they happen in production:
- Confirms your failover works the way you think it does
- Reveals gaps in monitoring (did you know the region was down?)
- Validates your SLO assumptions (how long does failover take?)
- Builds team confidence (we've drilled this, we know what to expect)

This practice is called **Chaos Engineering**, pioneered by Netflix.
Our simulation is a simple version of the same concept.

---

## What Exactly Happens During Failover?

Understanding the detailed sequence helps you read Grafana correctly.

### T+0:00 — Normal State
```
GLB:
  Mumbai NEG:    HEALTHY (3/3 health checks passing)
  Singapore NEG: HEALTHY (3/3 health checks passing)

Traffic distribution: ~50% Mumbai, ~50% Singapore
Grafana: both clusters show 6 running pods, normal CPU
```

### T+0:01 — We Scale Singapore to 0
```
kubectl scale deployment order-svc --replicas=0 -n microservices --context=gke-singapore
kubectl scale deployment product-svc --replicas=0 ...
kubectl scale deployment user-svc --replicas=0 ...

Singapore pods enter Terminating state.
Singapore NEG: GKE starts removing pod endpoints from NEG.
GLB health checks: Singapore pods stop responding.
```

### T+0:15 — GLB Detects Failure
```
GLB has seen 3 consecutive health check failures to Singapore NEG.
3 failures × 5s interval = 15 seconds after pods die.

GLB action: Mark Singapore NEG as UNHEALTHY.
GLB action: Stop routing new requests to Singapore.
GLB action: Route 100% of traffic to Mumbai NEG.

This happens in GCP's load balancing layer — sub-millisecond reroute.
```

### T+0:16 — In-Flight Requests
```
Any requests that were already sent to Singapore pods:
- If pods terminated gracefully: those requests get a response
- If pods terminated abruptly: those connections are dropped

This is why k8s terminationGracePeriodSeconds matters (default 30s).
Pods get 30 seconds to finish in-flight requests before being killed.

In our lab: http-echo is trivial, it responds immediately.
Expect < 1% error rate during the transition.
```

### T+0:20 — Full Failover Complete
```
All traffic: 100% Mumbai.
Singapore metrics in Grafana: dropping to 0.
Mumbai metrics in Grafana: doubling in request rate.
Singapore pod count in Grafana: 0.
```

### T+2:00 — We Restore Singapore
```
kubectl scale deployment order-svc --replicas=2 ...
kubectl scale deployment product-svc --replicas=2 ...
kubectl scale deployment user-svc --replicas=2 ...

Singapore pods enter Pending → ContainerCreating → Running state.
This takes 20-30 seconds (image pull + startup).
```

### T+2:30 — GLB Detects Recovery
```
Singapore pods are Running, passing readinessProbe.
GKE adds Singapore pod IPs back to the NEG.
GLB health checks start reaching Singapore pods again.
After 2 consecutive successes (10 seconds): Singapore NEG → HEALTHY.
GLB resumes routing some traffic to Singapore.
```

### T+2:45 — Full Recovery
```
Traffic: ~50% Mumbai, ~50% Singapore (restored)
Grafana: both clusters show 6 running pods again
```

---

## Three Methods to Simulate Failure

### Method 1: Scale Deployments to Zero (cleanest, most realistic)

```bash
for svc in order-svc product-svc user-svc; do
  kubectl scale deployment $svc \
    --replicas=0 \
    -n microservices \
    --context=gke-singapore
done
```

What this simulates: An application failure — all pods die but the
infrastructure (nodes, cluster) is still up.

Real-world equivalent: A bad deployment rolls out and crashes all pods,
or an OOM event kills all containers simultaneously.

This is the cleanest method because:
- Pods terminate gracefully (30s drain window)
- GKE removes pod IPs from NEG cleanly
- GLB health checks fail cleanly (connection refused, not timeout)
- Easiest to observe and reverse

### Method 2: Cordon and Drain Nodes (node failure)

```bash
# Get node names
NODES=$(kubectl get nodes --context=gke-singapore -o name)

# Mark nodes as unschedulable (no new pods)
kubectl cordon $NODES --context=gke-singapore

# Evict all pods from nodes
for node in $NODES; do
  kubectl drain $node \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --context=gke-singapore
done
```

What this simulates: Node-level failure — the machines stop working
but the cluster control plane is still up.

Real-world equivalent: A bad kernel update crashes nodes, node hardware
fails, or a cloud provider has a zonal hardware issue.

More realistic but harder to reverse:
- `kubectl uncordon $NODES` to restore
- Pods need to be rescheduled manually or by ArgoCD self-heal

### Method 3: Network Policy Block (partition simulation)

```bash
kubectl apply --context=gke-singapore -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: simulate-partition
  namespace: microservices
spec:
  podSelector: {}       # applies to all pods
  policyTypes:
    - Ingress
  ingress: []           # deny all ingress
EOF
```

What this simulates: Network partition — pods are running but unreachable.

Real-world equivalent: Firewall misconfiguration blocks traffic to the cluster,
or a network device failure isolates the region.

Interesting to observe because:
- Pods show as Running in kubectl (they're alive!)
- But health checks fail (no network access)
- GLB sees them as UNHEALTHY despite pods being healthy
- ArgoCD still shows them as Healthy (ArgoCD uses K8s API, not network)

Reverse with:
```bash
kubectl delete networkpolicy simulate-partition \
  -n microservices --context=gke-singapore
```

---

## Reading Grafana During Failover

Open Grafana BEFORE triggering the failure so you can watch in real time.

### Panel: Pods Running per Cluster
```promql
sum by (cluster) (
  kube_pod_status_phase{phase="Running", namespace="microservices"}
)
```
What to watch: Singapore drops from 6 to 0 at T+0:01.
Mumbai stays at 6 throughout.

### Panel: Node CPU Usage per Cluster
```promql
avg by (cluster) (
  100 - (rate(node_cpu_seconds_total{mode="idle"}[5m]) * 100)
)
```
What to watch: Mumbai CPU ticks up slightly as it handles all traffic.
Demonstrates that the failover has a measurable performance impact.

### Panel: Deployment Replicas Available
```promql
sum by (cluster, deployment) (
  kube_deployment_status_replicas_available{namespace="microservices"}
)
```
What to watch: Singapore deployments hit 0. Mumbai stays at 2.
This is the clearest visual indicator of the failure state.

### Panel: "up" metric per cluster
```promql
sum by (cluster) (
  up{namespace="microservices"}
)
```
What to watch: Singapore shows 0 (all scrape targets down).
Mumbai stays at its normal count.

---

## ArgoCD Self-Heal Demonstration

This bonus demo shows why GitOps matters for configuration discipline.

```bash
# Step 1: Manually change a deployment (simulate an engineer making
# an emergency change without following the proper process)
kubectl scale deployment order-svc \
  --replicas=5 \
  -n microservices \
  --context=gke-mumbai

# Step 2: Verify the change took effect
kubectl get deployment order-svc \
  -n microservices --context=gke-mumbai
# Shows: 5/5 replicas

# Step 3: Check ArgoCD's view
argocd app get order-svc-gke-mumbai
# Shows: OutOfSync (Git says 2, cluster has 5)

# Step 4: Wait ~3 minutes (ArgoCD polls every 3 min by default)
# ArgoCD detects drift:
#   Git state: replicas=2
#   Live state: replicas=5
#   Difference detected → selfHeal=true → trigger sync

# Step 5: Verify reversion
kubectl get deployment order-svc \
  -n microservices --context=gke-mumbai
# Shows: 2/2 replicas (back to what Git says)
```

### Why does this matter in production?

Scenario: At 3am, an on-call engineer scales up a deployment to handle
a traffic spike. This works, but now:
- The cluster no longer matches the Git definition
- Next ArgoCD sync will revert the scaling (oops!)
- Or if selfHeal is off, it stays at 5 but nobody documented why
- The engineer forgot to update Git → drift builds up over time

With selfHeal=true: any change that isn't committed to Git is automatically
reverted. This forces the right behavior: **always update Git first**.

If you legitimately need to scale up: update the HPA `maxReplicas` in Git,
commit, push → ArgoCD applies it within 3 minutes. Auditable, reviewable,
reversible.

---

## Observed Metrics Summary (Fill in After the Lab)

Use this table to record what you actually observed:

| Metric | Baseline | During Failure | Recovery |
|--------|----------|----------------|----------|
| Mumbai request rate | | | |
| Singapore request rate | | | |
| GLB failover time | - | seconds | - |
| GLB recovery time | - | - | seconds |
| Mumbai pod count | | | |
| Singapore pod count | | | |
| Error rate during transition | 0% | % | 0% |
| Mumbai CPU during failover | | | |
| Time ArgoCD detected drift | - | - | min |

---

## Step-by-Step: What the Script Does

`scripts/07-simulate-failover.sh` runs in phases:

```
Phase: baseline
  └── Verify both clusters healthy
  └── Start background traffic generator (3 req/sec to GLB)
  └── Run 30 requests and count region distribution (should be ~50/50)

Phase: fail
  └── Scale all Singapore deployments to 0
  └── Count down 30 seconds (time for GLB to detect failure)
  └── Run 20 requests — should be 100% Mumbai

Phase: recover
  └── Scale Singapore back to 2 replicas
  └── Wait for pods Running + readiness passes
  └── Count down 20 seconds (GLB recovery detection)
  └── Run 20 requests — should be ~50/50 again

Phase: selfheal
  └── Scale Mumbai order-svc to 5 manually
  └── Watch ArgoCD revert within 3 minutes
  └── Confirm replicas back to 2
```

---

## Executing Phase 8

```bash
cd /home/deepak.kumar30/multi-region-demo

# Open Grafana in your browser first (get IP from previous phase output)
# Then run the failover simulation:
./scripts/07-simulate-failover.sh

# Or run individual phases:
./scripts/07-simulate-failover.sh --phase=baseline
./scripts/07-simulate-failover.sh --phase=fail
./scripts/07-simulate-failover.sh --phase=recover
./scripts/07-simulate-failover.sh --phase=selfheal
```

Expected time: **15-20 minutes** (including observation pauses)

---

## After the Lab: Cleanup

```bash
./scripts/cleanup.sh
```

This deletes all GCP resources created during the lab:
- Both GKE clusters (and all workloads inside them)
- Global Load Balancer (forwarding rule, URL map, backends, health checks)
- Static IP address
- NEGs (auto-deleted with the clusters)

**Always run cleanup** — leaving clusters running costs ~$0.47/hr.
A forgotten cluster running for a week = ~$79 for no benefit.

---

## Key Takeaways from the Entire Lab

### 1. Active-active is intentional design, not a default
You do not get active-active by deploying to multiple regions.
You need: stateless services + a global load balancer + shared (or replicated)
data layer + conscious failover design.

### 2. GLB failover is fast, DNS failover is slow
GLB detects failure in ~15 seconds and reroutes instantly.
DNS-based failover requires TTL expiry — that's minutes of downtime.
For multi-region HA, always use a global load balancer, not DNS tricks.

### 3. GitOps prevents configuration drift
Without ArgoCD selfHeal, clusters gradually drift from their declared state.
With it, Git is the authoritative source and drift is automatically corrected.
This makes clusters predictable, auditable, and recoverable.

### 4. Centralized monitoring is non-negotiable for multi-cluster
You cannot effectively operate two clusters by checking them independently.
remote_write or Thanos aggregates metrics into one view.
Without this, you are flying blind half the time.

### 5. NEGs > NodePort for production load balancing
Container-native load balancing (NEGs) gives pod-level health checks,
eliminates kube-proxy hops, and integrates cleanly with GCP's GLB.
NodePort was a workaround before NEGs existed.

---

## Summary of the Entire Lab

| Phase | What Was Built | Key Concept |
|-------|---------------|-------------|
| 1 | Project structure + docs | Foundation |
| 2 | 2 GKE clusters | Multi-region infrastructure |
| 3 | ArgoCD hub + cluster registration | GitOps control plane |
| 4 | K8s manifests with Kustomize | Declarative configuration |
| 5 | ApplicationSet | Multi-cluster GitOps automation |
| 6 | Prometheus + Grafana | Unified multi-cluster observability |
| 7 | Global HTTP Load Balancer | Active-active traffic routing |
| 8 | Failover simulation | Validation and observability |

✅ Full active-active multi-region architecture built from scratch  
✅ GitOps-driven deployments via ArgoCD  
✅ Unified monitoring across both clusters  
✅ Sub-15-second regional failover demonstrated  
✅ ArgoCD self-heal demonstrated  
✅ All documented for future reference  
