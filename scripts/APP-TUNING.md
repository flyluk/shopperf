# Shop-demo performance tuning (dev-vm1)

**Local source:** `C:\Users\flyluk\Projects\shop-demo`  
**Cluster copy:** `/home/flyluk/development/shop-demo` on `dev-vm1.test.local`  
**Load tests:** `C:\Users\flyluk\Projects\shopperf\k6`

This doc captures what we learned tuning shop-demo under k6 (20–50 VUs, add+delete cart flow) and how to deploy, verify, and troubleshoot.

---

## Symptoms and root causes

Under load the API looked “slow” but CPU stayed low. Failures fell into three buckets:

| Symptom | Typical cause | Where to look |
|---------|---------------|---------------|
| `checks` threshold failed, `add_timeout` / `remove_timeout` | Request hung ~10s then timed out | DB pool queue, k6 TCP churn |
| `add_400_stock` | Insufficient stock | Wrong cart mode, depleted stock, VU product contention |
| `GET /api/products` 500, `relation "products" does not exist` | Empty DB after Postgres helm upgrade | Run `init-shop-demo-db.sh` |

### Server-side queueing (not CPU)

| Before | Issue |
|--------|--------|
| 1 uvicorn worker / pod | Too few processes for concurrent requests |
| JWT auth + DB lookup on cart | Extra Postgres round-trip per cart call |
| Extra query after cart add | Re-fetch with join after commit |
| nginx → API | No upstream keepalive |
| 2 API replicas, 500m CPU limit | Limited concurrency |
| Pool 20+30 × 16 workers | **320–800** DB conns vs Postgres `max_connections=300` → workers wait on pool |

When `DB_POOL_TIMEOUT` was **10s**, pool wait aligned exactly with k6’s `K6_HTTP_TIMEOUT=10s`, producing `request timeout` errors even though successful requests were ~10–25ms.

### k6 client (Docker → LAN)

Forcing `Connection: close` on every request while `K6_NO_CONNECTION_REUSE=false` defeated keep-alive and caused TCP connection storms from Docker. Fixed in `shopperf.js`: only send `Connection: close` when reuse is disabled; retry cart add/delete once on timeout (`K6_CART_RETRIES=1`).

### Stock / cart mode

- Use **`K6_CART_MODE=add_remove`** (default): add + delete each iteration; stock stays flat when deletes succeed.
- **`add` mode** depletes stock → many `400 Insufficient stock` failures.
- With 50 VUs and 10 products, multiple VUs share the same product (`vu 1` and `vu 11` → product 1).

---

## Current tuned settings

### API / SQLAlchemy (`k8s/configmap.yaml`)

| Setting | Value | Notes |
|---------|-------|-------|
| `UVICORN_WORKERS` | 4 | Per pod |
| `DB_POOL_SIZE` | 5 | Per worker process |
| `DB_MAX_OVERFLOW` | 8 | Burst headroom per worker |
| `DB_POOL_TIMEOUT` | 5 | Seconds to wait for a pool connection |
| `DB_POOL_RECYCLE` | 1800 | Seconds |

**Connection budget:** 4 pods × 4 workers × (5+8) = **208** max API→Postgres connections (must stay below `max_connections`).

### Kubernetes

| Resource | Value |
|----------|-------|
| API replicas | 4 |
| API CPU limit | 1 / pod |
| API memory limit | 512Mi / pod |
| Web replicas | 2 |

### Postgres (`scripts/shop-demo-postgres-values.yaml`)

| Setting | Value |
|---------|-------|
| `max_connections` | 400 |
| `shared_buffers` | 128MB |
| `effective_cache_size` | 512MB |
| Persistence | disabled (ephemeral — **schema must be re-applied after reinstall**) |

### nginx (`frontend/nginx.conf`)

- Upstream keepalive: **64** connections to API
- `/api/`: `proxy_connect_timeout 10s`, `proxy_read_timeout 30s`

### Backend app (requires image rebuild)

- `get_current_user_id()` — JWT only on cart routes (no DB auth lookup)
- Cart add/delete — fewer queries; delete restores stock
- Index on `cart_items(user_id)`
- Startup `seed_products()` if products table is empty

### k6 (`shopperf/k6/.env`)

| Setting | Recommended | Purpose |
|---------|-------------|---------|
| `K6_CART_MODE` | `add_remove` | Sustainable load; restores stock |
| `K6_NO_CONNECTION_REUSE` | `false` | Reuse TCP (faster from Docker) |
| `K6_CART_RETRIES` | `1` | Retry add/delete on HTTP timeout |
| `K6_HTTP_TIMEOUT` | `10s` | Keep while server is tuned; don’t raise to mask queueing |
| `K6_THRESHOLD_HTTP_FAILED` | `0.05` | Fail if >5% checks fail |

After each run, check the **Cart failure breakdown** in the k6 summary (`shop_fail_add_timeout`, `shop_fail_remove_timeout`, `shop_fail_add_400_stock`, etc.).

---

## Deploy

Edit locally, sync, and deploy from WSL:

```bash
cd /mnt/c/Users/flyluk/Projects/shop-demo/scripts
./deploy-remote.sh
```

Or on dev-vm1:

```bash
bash /home/flyluk/development/shop-demo/scripts/redeploy-shop-demo.sh
```

`redeploy-shop-demo.sh` applies ConfigMap, rebuilds images, rolls out API/web, and (if Helm is available) upgrades Postgres then runs **`init-shop-demo-db.sh`**.

### Verify deployment

```bash
# ConfigMap pool settings
kubectl get cm shop-demo-config -n shop-demo -o yaml | grep DB_

# Postgres max_connections
kubectl exec -n shop-demo shop-demo-postgres-postgresql-0 -- \
  env PGPASSWORD="$(kubectl get secret shop-demo-secrets -n shop-demo -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)" \
  psql -U shopuser -d shopdb -c "SHOW max_connections;"

# API health + products (products hits DB)
curl -s http://<web-lb-ip>/health
curl -s http://<web-lb-ip>/api/products | head -c 200
```

From WSL (replace IP):

```bash
curl -s http://192.168.1.53/health
curl -s http://192.168.1.53/api/products | head -c 200
```

---

## Database scripts

| Script | When to use |
|--------|-------------|
| `init-shop-demo-db.sh` | After Postgres install/reinstall/helm upgrade; creates tables, seeds 10 products (stock 20000) if empty |
| `reset-shop-demo-db.sh` | **Between k6 runs** — clears `cart_items`, sets all product stock to 20000 |

```bash
# on dev-vm1
bash /home/flyluk/development/shop-demo/scripts/init-shop-demo-db.sh   # schema + seed
bash /home/flyluk/development/shop-demo/scripts/reset-shop-demo-db.sh  # between benchmarks
```

**Important:** Postgres persistence is off. A helm upgrade can wipe data. If `/api/products` returns 500 with `relation "products" does not exist`, run `init-shop-demo-db.sh` before k6.

---

## Run k6

From WSL:

```bash
cd /mnt/c/Users/flyluk/Projects/shopperf/k6

# Optional: reset stock on cluster first (ssh to dev-vm1)
./run.sh --test-id 20260629-1
```

Read the human summary at the end of the run:

- `Product stock at setup` — confirm stock levels before load
- `checks pass rate` — must exceed threshold (default 95%)
- `Cart failure breakdown` — counts by failure type

Grafana: `http://192.168.1.52` (dashboard ID **19665** for k6). Filter by `testid` tag.

---

## Troubleshooting

### `thresholds on metrics 'checks' have been crossed`

1. Read **Cart failure breakdown** in the k6 summary.
2. **`add_timeout` / `remove_timeout`** → server pool queue or k6 TCP; verify ConfigMap pool values are deployed; confirm `K6_NO_CONNECTION_REUSE=false` and `K6_CART_RETRIES=1`.
3. **`add_400_stock`** → run `reset-shop-demo-db.sh`; confirm `K6_CART_MODE=add_remove`.
4. **`shop_checkout_errors` high** → stock/contention; reset DB or lower `K6_VUS`.

### `GET /api/products returned 500`

```bash
kubectl logs -n shop-demo deployment/api --tail=30
```

If `relation "products" does not exist`:

```bash
bash /home/flyluk/development/shop-demo/scripts/init-shop-demo-db.sh
```

### Pool sizing rule

```
(API replicas × UVICORN_WORKERS × (DB_POOL_SIZE + DB_MAX_OVERFLOW)) + ~20 headroom < max_connections
```

Current: `4 × 4 × 13 + 20 = 228 < 400` ✓

Do **not** raise per-worker pools without raising Postgres `max_connections` or reducing replicas/workers.

---

## File reference

| Path | Purpose |
|------|---------|
| `shop-demo/k8s/configmap.yaml` | Pool + worker env |
| `shop-demo/k8s/api-deployment.yaml` | API replicas, resources |
| `shop-demo/scripts/shop-demo-postgres-values.yaml` | Postgres Helm values |
| `shop-demo/scripts/init-shop-demo-db.sh` | Schema + seed |
| `shop-demo/scripts/reset-shop-demo-db.sh` | Reset between k6 runs |
| `shop-demo/scripts/deploy-remote.sh` | Sync + deploy from WSL |
| `shop-demo/db/init.sql` | SQL source for init script |
| `shopperf/k6/run.sh` | Run k6 from WSL (primary) |
| `shopperf/k6/shopperf.js` | k6 scenario, failure metrics, retries |
| `shopperf/k6/.env` | Load profile + thresholds |
| `shopperf/scripts/expose-prometheus.sh` | Expose Prometheus remote write |
| `shopperf/scripts/tune-shop-demo-remote.sh` | Legacy one-shot remote patch script |
