# ShopPerf — k6 Load Tests

Run **k6 in Docker from WSL** against [shop-demo](https://github.com/flyluk/shop-demo) on MicroK8s. Metrics stream **directly to Prometheus** in the cluster — no SSH tunnel for metrics.

| | Path |
|---|------|
| **Local repo (WSL)** | `/mnt/c/Users/flyluk/Projects/shopperf` |
| **Target app** | [shop-demo](https://github.com/flyluk/shop-demo) at `http://192.168.1.53` |
| **Tuning guide** | `scripts/APP-TUNING.md` |
| **Grafana** | http://192.168.1.52 (dashboard **19665**) |

All scripts are bash — run from **WSL**.

---

## Architecture

```
WSL (Docker/k6)                             MicroK8s cluster
┌──────────────────┐                       ┌─────────────────────────┐
│  ./k6/run.sh     │ ──HTTP──▶            │  shop-demo web (LB)     │
│                  │   BASE_URL            │    → api → Postgres     │
│                  │ ──remote write──▶    │  prometheus-remote-write│
│                  │   :9090/api/v1/write  │  (LoadBalancer)         │
└──────────────────┘                       │         │               │
                                           │         ▼               │
                                           │  Grafana 192.168.1.52   │
                                           └─────────────────────────┘
```

---

## Prerequisites

- WSL2 with Docker (Docker Desktop → Settings → Resources → WSL integration)
- `ssh` to `dev-vm1.test.local` (for Prometheus expose + DB reset helpers)
- shop-demo deployed and reachable at `BASE_URL`

---

## Quick start

### 1. One-time: expose Prometheus remote write

```bash
cd /mnt/c/Users/flyluk/Projects/shopperf
./scripts/expose-prometheus.sh
```

Copy the printed URL into `k6/.env` as `PROMETHEUS_RW_URL`.

Or manually:

```bash
ssh dev-vm1.test.local "kubectl apply -f -" < k8s/prometheus-external.yaml
ssh dev-vm1.test.local "kubectl get svc prometheus-remote-write -n monitoring"
```

Cluster Prometheus must have `enableRemoteWriteReceiver: true`.

### 2. Configure k6

```bash
cd k6
cp .env.example .env
```

Edit `k6/.env`:

```ini
BASE_URL=http://192.168.1.53
PROMETHEUS_RW_URL=http://192.168.1.54:9090/api/v1/write
K6_VUS=20
K6_CART_MODE=add_remove
```

Get the app LoadBalancer IP:

```bash
ssh dev-vm1.test.local "kubectl get svc web -n shop-demo"
```

### 3. Reset DB (recommended between runs)

```bash
ssh dev-vm1.test.local "bash /home/flyluk/development/shop-demo/scripts/reset-shop-demo-db.sh"
```

Or from WSL via the helper in this repo:

```bash
ssh dev-vm1.test.local "bash -s" < scripts/reset-shop-demo-db.sh
```

### 4. Run

```bash
cd /mnt/c/Users/flyluk/Projects/shopperf/k6
./run.sh
./run.sh --test-id 20260629-1
```

### 5. View results

- **Terminal:** human summary at end (checks pass rate, failure breakdown, latencies)
- **Grafana:** http://192.168.1.52 — import dashboard **19665**, filter by `testid` tag

---

## What the test does

Two scenarios (set `K6_SCENARIO` in `k6/.env` or on the CLI):

| Scenario | `K6_SCENARIO` | Flow |
|----------|---------------|------|
| Browse + cart (default) | `browse_and_cart` | Add item to cart, then delete (`add_remove` restores stock) |
| Checkout | `checkout` | Add to cart → edit address → place order |

**Setup:** health check, list products, register one user per VU (`k6user-{runId}-{cart\|checkout}-vu{N}@example.com`). Checkout also creates address + payment method per VU.

**Metrics:** `shop_iteration_ms`, `shop_cart_add_ok_ms`, `shop_checkout_ok_ms` (checkout), per-endpoint HTTP durations, failure counters.

**Thresholds:** configurable via `k6/.env` (default: p95 < 2s, checks pass rate > 95%).

### Run checkout scenario

```bash
K6_SCENARIO=checkout ./run.sh --test-id checkout-1
```

### Run two scenarios in parallel

Use **separate terminals**. CLI env vars override `k6/.env`. Use `SHOP_K6_VUS` (not `K6_VUS`) on the CLI so ramping stages are not overridden.

```bash
# Terminal 1 — browse + cart
K6_SCENARIO=browse_and_cart SHOP_K6_VUS=15 TEST_RUN_ID=mix ./run.sh

# Terminal 2 — checkout
K6_SCENARIO=checkout SHOP_K6_VUS=5 TEST_RUN_ID=mix ./run.sh
```

Each scenario gets its own user suffix (`-cart` / `-checkout`) so carts are not shared even with the same `TEST_RUN_ID`.

---

## Key `k6/.env` settings

| Variable | Recommended | Purpose |
|----------|-------------|---------|
| `K6_SCENARIO` | `browse_and_cart` | `checkout` = cart → edit address → place order |
| `K6_CART_MODE` | `add_remove` | Add + delete each iter; stock stays flat |
| `K6_NO_CONNECTION_REUSE` | `false` | Reuse TCP from Docker (faster) |
| `K6_CART_RETRIES` | `1` | Retry add/delete on HTTP timeout |
| `K6_HTTP_TIMEOUT` | `10s` | Don't raise to mask server queueing |
| `K6_THRESHOLD_HTTP_FAILED` | `0.05` | Fail if >5% checks fail (`off` to disable) |
| `K6_VUS` | start 5–20 | VU count in `.env`; on CLI use `SHOP_K6_VUS` instead |

See `k6/.env.example` for the full list including per-endpoint latency thresholds.

---

## Reading the summary

After each run, scroll up for:

```
=== k6 summary (testid=...) ===
Product stock at setup: min=... max=...
checks pass rate: ...
Cart failure breakdown (shop_cart_failures):
  Nx  add_timeout
  Nx  remove_timeout
  Nx  add_400_stock
```

| Failure code | Meaning |
|--------------|---------|
| `add_timeout` / `remove_timeout` | HTTP hung ~10s — server pool queue or TCP churn |
| `add_400_stock` | Insufficient stock — reset DB or use `add_remove` |
| `add_5xx` / `remove_5xx` | Server error |

Full diagnosis guide: **`scripts/APP-TUNING.md`**.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Docker not found in WSL | Enable Docker Desktop WSL integration |
| Connection refused | Check `BASE_URL` in `k6/.env` |
| No Grafana metrics | Run `./scripts/expose-prometheus.sh`; verify `PROMETHEUS_RW_URL` |
| Prometheus 404 on `/api/v1/write` | Confirm `enableRemoteWriteReceiver: true` on Prometheus CR |
| `checks` threshold failed | Read failure breakdown; see APP-TUNING.md |
| Parallel runs share carts / wrong VU count | CLI vars override `.env`; use `SHOP_K6_VUS` and distinct scenario suffixes (automatic) |
| `GET /api/products` 500 in setup | Run `init-shop-demo-db.sh` on dev-vm1 (shop-demo) |
| `bash\r: No such file` | Scripts need LF line endings — run `sed -i 's/\r$//' k6/run.sh` |

---

## Related repos & scripts

| Resource | Purpose |
|----------|---------|
| [shop-demo](https://github.com/flyluk/shop-demo) | Target app (API, nginx, Postgres) |
| `shop-demo/scripts/deploy-remote.sh` | Deploy app changes from WSL |
| `shop-demo/scripts/reset-shop-demo-db.sh` | Clear carts, restore stock 20000 |
| `scripts/APP-TUNING.md` | DB pool sizing, nginx, k6 client fixes |
| `scripts/tune-shop-demo-remote.sh` | Legacy one-shot remote patch script |

---

## Project structure

```
shopperf/
├── k6/
│   ├── shopperf.js          k6 scenario, failure metrics, retries
│   ├── run.sh               Run k6 via Docker (primary entry point)
│   ├── .env.example         Load profile + thresholds template
│   ├── .env                 Your config (gitignored)
│   └── docker-compose.yml   Optional local k6 compose
├── k8s/
│   └── prometheus-external.yaml   LoadBalancer for remote write
└── scripts/
    ├── expose-prometheus.sh       Expose Prometheus on dev-vm1
    ├── reset-shop-demo-db.sh      SSH helper to reset shop-demo DB
    ├── APP-TUNING.md              Performance tuning & troubleshooting
    └── tune-shop-demo-remote.sh   Legacy remote patch script
```

---

## Typical benchmark workflow

```bash
# 1. Deploy latest shop-demo (if app changed)
cd /mnt/c/Users/flyluk/Projects/shop-demo/scripts && ./deploy-remote.sh

# 2. Reset stock
ssh dev-vm1.test.local "bash /home/flyluk/development/shop-demo/scripts/reset-shop-demo-db.sh"

# 3. Run load test
cd /mnt/c/Users/flyluk/Projects/shopperf/k6 && ./run.sh --test-id my-run-1

# 4. Check Grafana (testid=my-run-1)
```
