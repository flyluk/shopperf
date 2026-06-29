#!/bin/bash
# Reset shop-demo DB between load test runs (clears carts, restores stock).
# Run on dev-vm1 before k6 if prior add-mode tests depleted inventory.
set -euo pipefail

NS="${NAMESPACE:-shop-demo}"
PG_POD="shop-demo-postgres-postgresql-0"
PW="$(kubectl get secret shop-demo-secrets -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"

kubectl exec -n "$NS" "$PG_POD" -- env PGPASSWORD="$PW" psql -U shopuser -d shopdb -v ON_ERROR_STOP=1 <<'SQL'
DELETE FROM cart_items;
UPDATE products SET stock = 20000;
SQL

echo "Cleared cart_items and set all product stock to 20000."
