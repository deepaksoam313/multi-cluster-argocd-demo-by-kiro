# Cluster: gke-mumbai

## Identity

| Field          | Value                          |
|----------------|--------------------------------|
| Name           | gke-mumbai                     |
| GCP Region     | asia-south1                    |
| GCP Zone       | asia-south1-a                  |
| K8s Version    | 1.35.8-gke.1225000             |
| Node Count     | 3 × e2-medium (2 vCPU, 4GB)   |
| Role           | Primary — ArgoCD hub, Grafana  |
| Cluster IP     | 8.234.68.126 (master endpoint) |

## Access

```bash
# Switch context
kubectl config use-context gke-mumbai

# Or fetch fresh credentials
gcloud container clusters get-credentials gke-mumbai \
  --zone=asia-south1-a \
  --project=skilled-text-468416-g3
```

## Services Exposed Externally

| Service    | External IP     | Port | Purpose                     |
|------------|-----------------|------|-----------------------------|
| ArgoCD     | 35.200.130.47   | 80   | GitOps UI + API             |
| Grafana    | 34.93.126.133   | 80   | Unified metrics dashboard   |
| Prometheus | 8.234.93.217    | 9090 | Raw metrics (Mumbai)        |

## Namespaces

| Namespace      | What lives here                         |
|----------------|-----------------------------------------|
| argocd         | ArgoCD (manages both clusters)          |
| microservices  | order-svc, product-svc, user-svc        |
| monitoring     | Prometheus + Grafana + AlertManager     |

## Why This Cluster Is the Hub

- ArgoCD is installed here and manages both Mumbai and Singapore
- Grafana is only on this cluster — it receives Singapore's metrics via remote_write
- If this cluster goes down, ArgoCD visibility is lost (but Singapore keeps serving traffic)
- In production this would be a dedicated management cluster, not an app cluster

## Node Sizing Note

Was originally 2 nodes. Scaled to 3 nodes because CoreDNS pods could not
schedule due to CPU exhaustion. Minimum recommended for this setup is 3 × e2-medium.
See `docs/LAB-COMPLETE-GUIDE.md` Section 6 for the full story.
