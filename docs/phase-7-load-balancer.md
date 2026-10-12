# Phase 7: GCP Global HTTP Load Balancer

## What Are We Doing in This Phase?

We are creating a **GCP External Global HTTP Load Balancer** — the component that
makes traffic routing in an active-active architecture actually work.

The GLB is the single entry point for all user traffic. It:
- Receives all requests on a single global Anycast IP
- Routes each request to the nearest healthy cluster
- Detects unhealthy backends (pods) within 15 seconds
- Automatically reroutes traffic when a region goes down
- Splits traffic across both regions when both are healthy

By the end of this phase, you have one IP address that routes to both Mumbai and
Singapore simultaneously. Users in India hit Mumbai; users in Southeast Asia hit
Singapore. If Mumbai fails, everyone gets routed to Singapore automatically.

---

## Why a Global Load Balancer? Can't Kubernetes Do This?

Kubernetes has its own load balancing — a Service of type `LoadBalancer` creates
a GCP Network Load Balancer (Layer 4). The problem is those are **regional**, not global:

```
Kubernetes LoadBalancer Service (regional):
  - Creates one NLB per service per region
  - Users must know which region to connect to
  - No automatic failover between regions
  - You'd need DNS failover (slow, minutes of downtime)
  - 3 services × 2 clusters = 6 load balancers (expensive)

GCP Global HTTP Load Balancer (our choice):
  - Single global Anycast IP
  - GCP's network automatically routes to nearest region
  - Sub-second failover (15s detection + instant reroute)
  - One LB handles all services via URL paths
  - Anycast = faster because traffic enters Google's network sooner
```

---

## What is Anycast?

Anycast is a network addressing method where one IP address is announced
from multiple geographic locations simultaneously.

```
Without Anycast (unicast):
  User in India  ──[open internet]──────────────► Server in Singapore
  
  Every packet crosses the public internet for the entire journey.
  Latency = whatever the public internet gives you.

With Anycast (GCP Premium Tier):
  User in India  ──[hops]──► GCP Point of Presence (Mumbai)
                                      │
                                      │ [GCP's private fiber backbone]
                                      │
                                      ▼
                                GKE gke-mumbai pods
  
  Traffic enters Google's network at the nearest POP,
  then travels on Google's private backbone to the destination.
  Latency = much lower, more predictable.
```

GCP has 100+ Points of Presence globally. Traffic always enters at
the closest one to the user, then routes on Google's backbone.
This is part of the GCP "Premium Tier" network (default for Global LB).

---

## GCP Global Load Balancer Components

The GLB is not a single resource — it is a **chain of components**:

```
Internet
   │
   ▼
[Forwarding Rule]            ← binds global IP + port to a proxy
   │
   ▼
[Target HTTP Proxy]          ← terminates HTTP, routes to URL map
   │
   ▼
[URL Map]                    ← routes by path (/orders → order-svc backend)
   │
   ├──/orders──► [Backend Service: order-svc]
   │                 ├── [Health Check]
   │                 ├── [NEG: order-svc pods in asia-south1-a]
   │                 └── [NEG: order-svc pods in asia-southeast1-a]
   │
   ├──/products──► [Backend Service: product-svc]
   │
   └──/users──► [Backend Service: user-svc]
```

Let's understand each component:

### Forwarding Rule
The entry point. Binds a specific IP + port to a proxy:
```
IP: 34.x.x.x (our global static IP)
Port: 80 (HTTP)
Target: multi-region-http-lb-proxy
```

### Target HTTP Proxy
Understands the HTTP protocol. Receives the forwarding rule's traffic
and consults the URL map to decide where to send each request.

### URL Map
Path-based routing rules:
```
Host: * (any hostname)
Path: /orders   → order-svc backend service
Path: /products → product-svc backend service
Path: /users    → user-svc backend service
Path: /*        → order-svc (default)
```

### Backend Service
Groups together the backends (NEGs) for one logical service,
plus the health check configuration.

The backend service also controls:
- Balancing algorithm (RATE = requests per second per pod)
- Session affinity (none for our stateless services)
- Connection draining timeout (how long to wait for in-flight requests)
- CDN caching (not used here)

### Health Check
Probes each backend (NEG endpoint = pod) periodically:
```
Protocol: HTTP
Port: 8080
Path: /
Interval: 5 seconds
Timeout: 5 seconds
Healthy threshold: 2 consecutive successes
Unhealthy threshold: 3 consecutive failures
```

Time to detect failure: 3 × 5 = **15 seconds maximum**
Time to detect recovery: 2 × 5 = **10 seconds**

### NEG (Network Endpoint Group)
A NEG is a group of **individual pod IP:port** pairs registered with GCP's
load balancing layer.

```
Without NEG (old NodePort model):
  GLB → Node IP:30080 (NodePort)
           │
           └── kube-proxy → Pod (extra hop, load balanced by iptables)
  
  Health check: at the NODE level (a node is healthy if ANY pod is ready)
  Problem: GLB might send traffic to a node whose pod is terminating

With NEG (container-native):
  GLB → Pod IP:8080 directly
  
  Health check: at the POD level (each pod independently healthy or not)
  If a pod crashes: GLB stops sending to that specific pod immediately
  No kube-proxy hop, no iptables rules involved
```

GKE auto-creates NEGs when a Service has the annotation:
```yaml
cloud.google.com/neg: '{"ingress": true}'
```

GKE also auto-registers/de-registers pods as they start and stop.

---

## How Traffic Routing Works in Active-Active

### Normal operation (both regions healthy):
```
Request from user in Mumbai:
  1. DNS resolves to Anycast IP 34.x.x.x
  2. Packet enters GCP network at Mumbai PoP
  3. GLB routes to nearest backend → gke-mumbai NEG
  4. Pod in Mumbai responds

Request from user in Singapore:
  1. Same Anycast IP 34.x.x.x
  2. Packet enters GCP network at Singapore PoP
  3. GLB routes to nearest backend → gke-singapore NEG
  4. Pod in Singapore responds
```

Both regions serve traffic simultaneously — **active-active**.

### Failover (Mumbai goes down):
```
Mumbai pods fail health checks (3 × 5s = 15s):
  1. Health checks to Mumbai NEG start failing
  2. After 3 failures: Mumbai NEG marked UNHEALTHY
  3. GLB stops sending traffic to Mumbai NEG
  4. All traffic (including from India) routes to Singapore

There is NO DNS change, NO IP change, NO TTL wait.
Failover happens in the load balancer layer — sub-second rerouting
after the unhealthy state is detected.
```

### Recovery (Mumbai comes back):
```
Mumbai pods pass health checks (2 × 5s = 10s):
  1. Health checks to Mumbai NEG start passing again
  2. After 2 successes: Mumbai NEG marked HEALTHY
  3. GLB resumes sending traffic to Mumbai
  4. Traffic distributes across both regions again
```

---

## Path-Based Routing Explained

We route different service paths to different backend services:

```
http://34.x.x.x/orders/123    → order-svc backend
http://34.x.x.x/products/456  → product-svc backend
http://34.x.x.x/users/789     → user-svc backend
```

This simulates a real API gateway pattern where one IP serves multiple
microservices, each on its own path prefix.

In production, you would typically add:
- HTTPS with a managed SSL certificate
- Cloud Armor (WAF) for security
- Cloud CDN for caching static responses
- Custom error responses

---

## Static vs Ephemeral IP

We reserve a **static** global IP address:

```bash
gcloud compute addresses create multi-region-lb-ip --global
```

Without a static IP:
- The IP is assigned dynamically when the forwarding rule is created
- If you delete and recreate the forwarding rule, the IP changes
- DNS records pointing to the old IP break

With a static IP:
- IP is reserved independently from the load balancer
- You can delete/recreate the LB and keep the same IP
- DNS records remain valid

---

## Step-by-Step: What the Script Does

`scripts/06-setup-glb.sh`:

```
Step 1: Reserve global static IP
        └── gcloud compute addresses create multi-region-lb-ip --global

Step 2: Create health checks (one per service)
        └── HTTP, port 8080, path /, interval 5s, threshold 3

Step 3: Wait for NEGs to appear
        └── GKE auto-creates NEGs after Services with annotation are deployed
        └── Poll gcloud compute network-endpoint-groups list until found
        └── We need NEG names to add them to backend services

Step 4: Create backend services (one per service)
        └── Each backend service references one health check
        └── Add Mumbai NEG as backend (from asia-south1-a)
        └── Add Singapore NEG as backend (from asia-southeast1-a)
        └── Balancing mode: RATE (requests per second)

Step 5: Create URL map
        └── Default service: order-svc-backend
        └── Path rules:
              /orders/* → order-svc-backend
              /products/* → product-svc-backend
              /users/* → user-svc-backend

Step 6: Create Target HTTP Proxy
        └── References the URL map

Step 7: Create Forwarding Rule
        └── Binds static IP + port 80 to the proxy

Step 8: Wait for GLB to propagate (5-10 minutes)
        └── Poll /orders until HTTP 200 is received
```

---

## GLB Propagation Delay

After creating all components, the GLB is not immediately functional.
GCP needs to propagate the configuration to all of its Points of Presence
globally. This typically takes **5-10 minutes**.

During propagation you will get:
- HTTP 404 or connection errors
- Intermittent responses

This is normal — just wait. The GLB stabilizes without any action from you.

---

## Executing Phase 7

```bash
cd /home/deepak.kumar30/multi-region-demo
./scripts/06-setup-glb.sh
```

Expected time: **10-15 minutes** (includes propagation wait)

---

## Verification Commands

```bash
# Get the global IP
GLOBAL_IP=$(gcloud compute addresses describe multi-region-lb-ip \
  --global --format='value(address)')
echo "Global IP: $GLOBAL_IP"

# Test each service path
curl http://$GLOBAL_IP/orders
curl http://$GLOBAL_IP/products
curl http://$GLOBAL_IP/users

# Run 20 requests and count which cluster responds
for i in {1..20}; do
  curl -s http://$GLOBAL_IP/orders
  echo
done | grep -oP '"cluster":"[^"]*"' | sort | uniq -c

# Expected (rough 50/50 split):
#  10  "cluster":"gke-mumbai"
#  10  "cluster":"gke-singapore"

# Check backend health in GCP console or CLI
gcloud compute backend-services get-health order-svc-backend \
  --global --project=skilled-text-468416-g3

# Expected: each NEG endpoint shows healthState: HEALTHY

# List all GLB components
gcloud compute forwarding-rules list --global
gcloud compute url-maps list
gcloud compute backend-services list --global
gcloud compute health-checks list
gcloud compute addresses list --global
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `curl` returns 404 | GLB not propagated yet | Wait 5-10 min |
| `curl` returns 502 | Backends unhealthy | Check pod health: `kubectl get pods -n microservices` |
| No NEGs appearing | K8s Service annotation missing | Verify `cloud.google.com/neg` annotation on Services |
| Backend shows UNKNOWN health | Health check not configured | Check health check port matches container port (8080) |
| All traffic goes to one region | One NEG has 0 endpoints | Check pod count in that cluster |
| `PERMISSION_DENIED` on gcloud | Missing `compute.admin` IAM role | Verify active account permissions |

---

## Summary

## Real-World Notes from This Lab

### 1. NEG annotation: `{"ingress": true}` vs `{"exposed_ports":{"80":{}}}`
`{"ingress": true}` only creates NEGs when a Kubernetes Ingress resource exists
and references the service. For standalone GLB without K8s Ingress,
use `{"exposed_ports":{"80":{}}}` — this creates NEGs immediately.

### 2. GCP API slowness
Backend service operations (create, add-backend) regularly took 60-120s
to return despite succeeding. Always verify with `describe` after a timeout
before retrying — duplicate operations throw clear errors.

### 3. Firewall rule for health checks
GCP's GLB health checkers probe from two fixed CIDR ranges:
- `130.211.0.0/22` and `35.191.0.0/16`
Without a firewall rule allowing `tcp:8080` from these ranges,
all NEG endpoints show UNHEALTHY regardless of pod state.

### 4. Anycast nearest-region routing
All 20 test requests went to `gke-mumbai` — expected behavior since
the test machine is in India and Mumbai is the nearest GCP PoP.
Singapore would serve users from Southeast Asia. Both backends are HEALTHY
and active — this IS active-active, just geographically distributed.

---

## Actual Deployment Values (Phase 7 Completed)

| Item | Value |
|------|-------|
| Global IP | `8.233.61.198` |
| URL map | `multi-region-lb` |
| HTTP proxy | `multi-region-lb-proxy` |
| Forwarding rule | `multi-region-lb-rule` |
| Firewall rule | `allow-glb-healthchecks` (tcp:8080 from GCP health check ranges) |
| NEG annotation used | `cloud.google.com/neg: '{"exposed_ports":{"80":{}}}` |

| Path | Backend | Verified |
|------|---------|---------|
| `/orders` | order-svc-backend | ✅ HTTP 200 |
| `/products` | product-svc-backend | ✅ HTTP 200 |
| `/users` | user-svc-backend | ✅ HTTP 200 |

| Backend | Mumbai NEG | Singapore NEG | Health |
|---------|-----------|--------------|--------|
| order-svc-backend | k8s1-7ce163af-...-order-svc | k8s1-949d399f-...-order-svc | ✅ All HEALTHY |
| product-svc-backend | k8s1-7ce163af-...-product-svc | k8s1-949d399f-...-product-svc | ✅ All HEALTHY |
| user-svc-backend | k8s1-7ce163af-...-user-svc | k8s1-949d399f-...-user-svc | ✅ All HEALTHY |

```bash
# Quick test commands
curl http://8.233.61.198/orders
curl http://8.233.61.198/products
curl http://8.233.61.198/users

# Check backend health
gcloud compute backend-services get-health order-svc-backend \
  --global --project=skilled-text-468416-g3
```

---

## Summary

✅ Global static IP reserved: `8.233.61.198`  
✅ NEG annotation fixed to `exposed_ports` mode — 6 NEGs created (3 per region)  
✅ Health checks created for all 3 services (5s interval, port 8080)  
✅ Firewall rule added for GCP health checker IP ranges  
✅ Backend services created with both Mumbai + Singapore NEGs  
✅ URL map with path routing (`/orders`, `/products`, `/users`)  
✅ All 12 NEG endpoints HEALTHY  
✅ GLB responding HTTP 200 on all 3 paths  
✅ Anycast routing confirmed — nearest region serves traffic  

**Next → Phase 8: Failover Simulation and Observability**
