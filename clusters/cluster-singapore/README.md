# Cluster: gke-singapore

## Identity

| Field          | Value                            |
|----------------|----------------------------------|
| Name           | gke-singapore                    |
| GCP Region     | asia-southeast1                  |
| GCP Zone       | asia-southeast1-a                |
| K8s Version    | 1.35.8-gke.1225000               |
| Node Count     | 2 × e2-medium (2 vCPU, 4GB)     |
| Role           | Secondary — active app cluster   |
| Cluster IP     | 34.143.165.98 (master endpoint)  |
| ArgoCD Server  | https://34.143.165.98            |

## Access

```bash
# Switch context
kubectl config use-context gke-singapore

# Or fetch fresh credentials
gcloud container clusters get-credentials gke-singapore \
  --zone=asia-southeast1-a \
  --project=skilled-text-468416-g3
```

## Services

No externally exposed services on this cluster. Traffic reaches pods here
only via the Global Load Balancer (Anycast IP: `8.233.61.198`).

## Namespaces

| Namespace      | What lives here                         |
|----------------|-----------------------------------------|
| microservices  | order-svc, product-svc, user-svc        |
| monitoring     | Prometheus only (no Grafana)            |

## Monitoring Setup

- Prometheus scrapes local pods and nodes
- No Grafana (centralized on Mumbai)
- All metrics forwarded to Mumbai via `remote_write`:
  `http://MUMBAI_PROMETHEUS_IP:9090/api/v1/write`
- In Grafana, filter by `cluster="gke-singapore"` to see this cluster's metrics

## ArgoCD Registration

This cluster was registered with ArgoCD on Mumbai via:
```bash
argocd cluster add gke-singapore --name gke-singapore --yes
```

This created a `argocd-manager` ServiceAccount in `kube-system` here,
and stored the credentials as a Secret in the `argocd` namespace on Mumbai.
ArgoCD uses those credentials to deploy to this cluster remotely.
