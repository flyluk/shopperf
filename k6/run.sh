#!/usr/bin/env bash
# Run k6 load test via Docker (use from WSL).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
IMAGE="${IMAGE:-grafana/k6:latest}"
TEST_ID_ARG=""

usage() {
  echo "Usage: $0 [--test-id ID] [-t ID]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t | --test-id)
      [[ $# -ge 2 ]] || usage
      TEST_ID_ARG="$2"
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    *)
      if [[ -z "$TEST_ID_ARG" ]]; then
        TEST_ID_ARG="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        usage
      fi
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed or not in PATH." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE — edit BASE_URL and PROMETHEUS_RW_URL before running."
fi

# shellcheck disable=SC1090
set -a
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
    name="${BASH_REMATCH[1]// /}"
    value="${BASH_REMATCH[2]}"
    # Legacy key — prefix is always derived from TEST_RUN_ID
    [[ "$name" == "TEST_EMAIL_PREFIX" ]] && continue
    export "$name=$value"
  fi
done <"$ENV_FILE"
set +a

if [[ -z "${BASE_URL:-}" ]]; then
  echo "ERROR: BASE_URL is required in $ENV_FILE" >&2
  exit 1
fi

if [[ -n "$TEST_ID_ARG" ]]; then
  export TEST_RUN_ID="$TEST_ID_ARG"
  export TEST_ID="$TEST_ID_ARG"
fi

if [[ -z "${TEST_RUN_ID:-}" ]]; then
  TEST_RUN_ID="$(date +%s%3N)"
  export TEST_RUN_ID TEST_ID="$TEST_RUN_ID"
fi

EMAIL_BASE="${TEST_EMAIL_PREFIX_BASE:-k6user}"
unset TEST_EMAIL_PREFIX 2>/dev/null || true
export TEST_EMAIL_PREFIX="${EMAIL_BASE}-${TEST_RUN_ID}"

echo "Pulling k6 image ($IMAGE)..."
docker pull "$IMAGE" >/dev/null

docker_args=(
  run --rm -i
  -v "${SCRIPT_DIR}:/scripts:ro"
  -e "BASE_URL=${BASE_URL}"
  -e "TEST_EMAIL_PREFIX_BASE=${EMAIL_BASE}"
  -e "TEST_PASSWORD=${TEST_PASSWORD:-k6pass123}"
  -e "TEST_EMAIL_DOMAIN=${TEST_EMAIL_DOMAIN:-example.com}"
  -e "TEST_RUN_ID=${TEST_RUN_ID}"
  -e "TEST_ID=${TEST_ID}"
)

optional_vars=(
  K6_VUS K6_RAMP_UP K6_HOLD K6_RAMP_DOWN K6_SLEEP K6_HTTP_TIMEOUT
  K6_CART_MODE K6_NO_CONNECTION_REUSE K6_CART_RETRIES K6_SETUP_BATCH_SIZE K6_SETUP_TIMEOUT
  K6_SUMMARY_TREND_STATS
  K6_THRESHOLD_HTTP_AVG_MS K6_THRESHOLD_HTTP_MIN_MS K6_THRESHOLD_HTTP_MAX_MS
  K6_THRESHOLD_HTTP_P95_MS K6_THRESHOLD_HTTP_P99_MS
  K6_THRESHOLD_ITER_AVG_MS K6_THRESHOLD_ITER_MIN_MS K6_THRESHOLD_ITER_MAX_MS
  K6_THRESHOLD_ITER_P95_MS K6_THRESHOLD_ITER_P99_MS
  K6_THRESHOLD_HTTP_FAILED
  K6_PROMETHEUS_RW_TREND_STATS
)

for var in "${optional_vars[@]}"; do
  val="${!var:-}"
  if [[ -n "$val" ]]; then
    docker_args+=(-e "${var}=${val}")
  fi
done

k6_args=(run)

if [[ -n "${PROMETHEUS_RW_URL:-}" ]]; then
  rw_url="$PROMETHEUS_RW_URL"
  if [[ -z "${K6_PROMETHEUS_RW_TREND_STATS:-}" ]]; then
    export K6_PROMETHEUS_RW_TREND_STATS='avg,min,max,p(95),p(99)'
  fi
  docker_args+=(
    -e "K6_PROMETHEUS_RW_SERVER_URL=${rw_url}"
    -e "K6_PROMETHEUS_RW_TREND_STATS=${K6_PROMETHEUS_RW_TREND_STATS}"
  )
  if [[ -n "${PROMETHEUS_RW_USER:-}" ]]; then
    docker_args+=(-e "K6_PROMETHEUS_RW_USERNAME=${PROMETHEUS_RW_USER}")
  fi
  if [[ -n "${PROMETHEUS_RW_PASSWORD:-}" ]]; then
    docker_args+=(-e "K6_PROMETHEUS_RW_PASSWORD=${PROMETHEUS_RW_PASSWORD}")
  fi
  k6_args+=(--out experimental-prometheus-rw)
  echo "Sending metrics to: $rw_url"
else
  echo "PROMETHEUS_RW_URL not set — running with stdout summary only."
fi

k6_args+=("/scripts/shopperf.js")

echo "Target: ${BASE_URL}"
echo "Test ID (testid tag): ${TEST_RUN_ID}"
echo "Users: ${TEST_EMAIL_PREFIX}-vu{N}@${TEST_EMAIL_DOMAIN:-example.com}"
echo "Profile: ${K6_VUS:-5} VUs, ramp ${K6_RAMP_UP:-5s} / hold ${K6_HOLD:-25s} / down ${K6_RAMP_DOWN:-5s}, cart=${K6_CART_MODE:-add}"
echo "Running k6 via Docker..."

docker_args+=("$IMAGE" "${k6_args[@]}")
exec docker "${docker_args[@]}"
