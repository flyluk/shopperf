#!/usr/bin/env bash
# Expose Prometheus remote-write via LoadBalancer on dev-vm1.
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-dev-vm1.test.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../k8s/prometheus-external.yaml"

echo "Applying Prometheus LoadBalancer on ${REMOTE_HOST} ..."
ssh "$REMOTE_HOST" "kubectl apply -f -" <"$MANIFEST"

echo "Waiting for external IP..."
for _ in $(seq 1 30); do
  ip="$(ssh "$REMOTE_HOST" "kubectl get svc prometheus-remote-write -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || true)"
  if [[ -n "$ip" ]]; then
    echo ""
    echo "Prometheus remote write URL:"
    echo "  http://${ip}:9090/api/v1/write"
    echo ""
    echo "Add to k6/.env:"
    echo "  PROMETHEUS_RW_URL=http://${ip}:9090/api/v1/write"
    exit 0
  fi
  sleep 2
done

echo "Service applied but no external IP yet. Check with:"
echo "  ssh ${REMOTE_HOST} \"kubectl get svc prometheus-remote-write -n monitoring\""
