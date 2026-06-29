# ShopPerf k6 Load Tests

Run **k6 in Docker** on Windows against your app on MicroK8s. Metrics go **directly to Prometheus** in the cluster — no SSH tunnel.

## Architecture

```
Windows (Docker/k6)                         MicroK8s cluster
┌──────────────────┐                       ┌─────────────────────────┐
│  k6 run.ps1      │ ──HTTP──▶            │  your app (shopperf)    │
│                  │   BASE_URL            │                         │
│                  │ ──remote write──▶    │  prometheus-remote-write│
│                  │   :9090/api/v1/write  │  (LoadBalancer)         │
└──────────────────┘                       │         │               │
                                           │         ▼               │
                                           │  Grafana 192.168.1.52   │
                                           └─────────────────────────┘
```

## One-time setup: expose Prometheus

Prometheus is ClusterIP by default. Expose remote write on your LAN (same as Grafana):

```powershell
.\scripts\expose-prometheus.ps1
```

This creates `prometheus-remote-write` (LoadBalancer) in the `monitoring` namespace and prints the URL.

Or manually on dev-vm1:

```powershell
ssh dev-vm1.test.local "kubectl apply -f -" < k8s\prometheus-external.yaml
ssh dev-vm1.test.local "kubectl get svc prometheus-remote-write -n monitoring"
```

Your cluster already has `enableRemoteWriteReceiver: true` on Prometheus.

## Run a load test

### 1. Configure

```powershell
copy k6\.env.example k6\.env
```

Set in `k6\.env`:

```
BASE_URL=http://<your-app-ip>
PROMETHEUS_RW_URL=http://<prometheus-external-ip>:9090/api/v1/write
```

Get app URL:

```powershell
ssh dev-vm1.test.local "kubectl get svc -n shopperf"
```

### 2. Run

```powershell
.\k6\run.ps1
```

### 3. View in Grafana

Open http://192.168.1.52 and import dashboard **19665** (*k6 Prometheus*).

## What the test does

1. Register (or login) a unique user per VU/iteration
2. List products (`GET /api/products`)
3. Add items to cart (`POST /api/cart/items`)
4. Fetch cart (`GET /api/cart`)

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Docker not found | Install Docker Desktop |
| Connection refused (app) | Check `BASE_URL` in `k6\.env` |
| No Grafana metrics | Run `expose-prometheus.ps1`; verify `PROMETHEUS_RW_URL` is the LoadBalancer IP |
| Prometheus 404 on /api/v1/write | Confirm `enableRemoteWriteReceiver: true` on your Prometheus CR |

## Project layout

```
shopperf/
├── k8s/
│   └── prometheus-external.yaml   LoadBalancer for remote write
├── scripts/
│   └── expose-prometheus.ps1      Apply expose service via dev-vm1
└── k6/
    ├── shopperf.js
    ├── run.ps1
    ├── docker-compose.yml
    └── .env.example
```
