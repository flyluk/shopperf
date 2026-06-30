# Context — shopperf

Handoff for new chats / agents. Full docs: [README.md](README.md), [scripts/APP-TUNING.md](scripts/APP-TUNING.md).

## What this repo is

k6 load tests against [shop-demo](https://github.com/flyluk/shop-demo) on MicroK8s. Runs from **WSL** via Docker. Metrics → Prometheus remote write → Grafana.

## Sibling repo

| Repo | Role |
|------|------|
| [shop-demo](https://github.com/flyluk/shop-demo) | Target app (API, nginx, Postgres) |
| shopperf (this) | k6 runner, Prometheus expose, tuning docs |

## Paths

| | |
|---|---|
| Local (WSL) | `/mnt/c/Users/flyluk/Projects/shopperf` |
| Cluster host | `dev-vm1.test.local` |
| shop-demo on cluster | `/home/flyluk/development/shop-demo` |

## Cluster endpoints

| Service | URL |
|---------|-----|
| shop-demo web (BASE_URL) | `http://192.168.1.53` |
| Grafana | `http://192.168.1.52` (dashboard **19665**) |
| Prometheus remote write | `http://192.168.1.54:9090/api/v1/write` |

## Run load test

```bash
# Reset stock on cluster (recommended between runs)
ssh dev-vm1.test.local "bash /home/flyluk/development/shop-demo/scripts/reset-shop-demo-db.sh"

cd /mnt/c/Users/flyluk/Projects/shopperf/k6
cp .env.example .env   # first time only — edit BASE_URL, PROMETHEUS_RW_URL, K6_VUS
./run.sh --test-id <id>
```

## k6 config (`k6/.env`, gitignored)

| Variable | Typical value | Notes |
|----------|---------------|-------|
| `BASE_URL` | `http://192.168.1.53` | shop-demo web LB |
| `PROMETHEUS_RW_URL` | `http://192.168.1.54:9090/api/v1/write` | One-time: `./scripts/expose-prometheus.sh` |
| `K6_CART_MODE` | `add_remove` | Add + delete each iter; restores stock |
| `K6_NO_CONNECTION_REUSE` | `false` | Reuse TCP from Docker |
| `K6_CART_RETRIES` | `1` | Retry on HTTP timeout |
| `K6_SETUP_BATCH_SIZE` | `25` | Parallel user registration in setup |
| `K6_THRESHOLD_HTTP_FAILED` | `0.05` | Fail if >5% checks fail |

## Key files

| File | Purpose |
|------|---------|
| `k6/shopperf.js` | Scenario, failure metrics, batched setup |
| `k6/run.sh` | Docker k6 entry point |
| `scripts/APP-TUNING.md` | Troubleshooting (timeouts, pool, stock 400s) |
| `scripts/expose-prometheus.sh` | Expose Prometheus LoadBalancer |
| `scripts/reset-shop-demo-db.sh` | SSH helper to reset shop-demo DB |

## Read after each run

- `checks pass rate` — default threshold > 95%
- `Cart failure breakdown` — `add_timeout`, `remove_timeout`, `add_400_stock`
- `Product stock at setup` — should be ~20000 after DB reset

## Known gotchas

- **Setup timeout** at high VU counts: fixed via batched setup + auto `setupTimeout` (scales with `K6_VUS`).
- **checks failures** were HTTP timeouts (not stock) — fixed with keep-alive + retries; server pool tuned in shop-demo.
- **Postgres wipe** after helm upgrade → run shop-demo `init-shop-demo-db.sh`.
- At **200 VUs**, `cart_remove` latency threshold may still fail under heavy load.

## Scripts are bash only

No `.ps1` files. Use WSL for all commands.
