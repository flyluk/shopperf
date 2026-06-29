param(
  [string]$EnvFile = "$PSScriptRoot\.env",
  [string]$Image = "grafana/k6:latest",
  [string]$TestId = ""
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "Docker is not installed or not in PATH."
}

if (-not (Test-Path $EnvFile)) {
  Copy-Item "$PSScriptRoot\.env.example" $EnvFile
  Write-Host "Created $EnvFile — edit BASE_URL and PROMETHEUS_RW_URL before running."
}

Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
    $name = $matches[1].Trim()
    # Legacy key — prefix is always derived from TEST_RUN_ID
    if ($name -eq 'TEST_EMAIL_PREFIX') { return }
    Set-Item -Path "env:$name" -Value $matches[2].Trim()
  }
}

if (-not $env:BASE_URL) {
  Write-Error "BASE_URL is required in $EnvFile"
}

if ($TestId) {
  $env:TEST_RUN_ID = $TestId
  $env:TEST_ID = $TestId
}

if (-not $env:TEST_RUN_ID) {
  $env:TEST_RUN_ID = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
}
$env:TEST_ID = $env:TEST_RUN_ID

$emailBase = if ($env:TEST_EMAIL_PREFIX_BASE) { $env:TEST_EMAIL_PREFIX_BASE } else { 'k6user' }
# Always match testid — ignore any stale TEST_EMAIL_PREFIX in the shell
Remove-Item Env:TEST_EMAIL_PREFIX -ErrorAction SilentlyContinue
$env:TEST_EMAIL_PREFIX = "$emailBase-$($env:TEST_RUN_ID)"

Write-Host "Pulling k6 image ($Image)..."
docker pull $Image | Out-Null

$dockerArgs = @(
  "run", "--rm", "-i",
  "-v", "${PSScriptRoot}:/scripts:ro",
  "-e", "BASE_URL=$($env:BASE_URL)",
  "-e", "TEST_EMAIL_PREFIX_BASE=$emailBase",
  "-e", "TEST_PASSWORD=$($env:TEST_PASSWORD)",
  "-e", "TEST_EMAIL_DOMAIN=$($env:TEST_EMAIL_DOMAIN)",
  "-e", "TEST_RUN_ID=$($env:TEST_RUN_ID)",
  "-e", "TEST_ID=$($env:TEST_ID)"
)

foreach ($var in @(
  'K6_VUS', 'K6_RAMP_UP', 'K6_HOLD', 'K6_RAMP_DOWN', 'K6_SLEEP', 'K6_HTTP_TIMEOUT',
  'K6_CART_MODE', 'K6_NO_CONNECTION_REUSE', 'K6_CART_RETRIES',
  'K6_SUMMARY_TREND_STATS',
  'K6_THRESHOLD_HTTP_AVG_MS', 'K6_THRESHOLD_HTTP_MIN_MS', 'K6_THRESHOLD_HTTP_MAX_MS',
  'K6_THRESHOLD_HTTP_P95_MS', 'K6_THRESHOLD_HTTP_P99_MS',
  'K6_THRESHOLD_ITER_AVG_MS', 'K6_THRESHOLD_ITER_MIN_MS', 'K6_THRESHOLD_ITER_MAX_MS',
  'K6_THRESHOLD_ITER_P95_MS', 'K6_THRESHOLD_ITER_P99_MS',
  'K6_THRESHOLD_HTTP_FAILED',
  'K6_PROMETHEUS_RW_TREND_STATS'
)) {
  $val = (Get-Item -Path "env:$var" -ErrorAction SilentlyContinue).Value
  if ($val) {
    $dockerArgs += @("-e", "$var=$val")
  }
}

$k6Args = @("run")

if ($env:PROMETHEUS_RW_URL) {
  $rwUrl = $env:PROMETHEUS_RW_URL
  if (-not $env:K6_PROMETHEUS_RW_TREND_STATS) {
    $env:K6_PROMETHEUS_RW_TREND_STATS = 'avg,min,max,p(95),p(99)'
  }
  $dockerArgs += @("-e", "K6_PROMETHEUS_RW_SERVER_URL=$rwUrl")
  $dockerArgs += @("-e", "K6_PROMETHEUS_RW_TREND_STATS=$($env:K6_PROMETHEUS_RW_TREND_STATS)")
  if ($env:PROMETHEUS_RW_USER) {
    $dockerArgs += @("-e", "K6_PROMETHEUS_RW_USERNAME=$($env:PROMETHEUS_RW_USER)")
  }
  if ($env:PROMETHEUS_RW_PASSWORD) {
    $dockerArgs += @("-e", "K6_PROMETHEUS_RW_PASSWORD=$($env:PROMETHEUS_RW_PASSWORD)")
  }
  $k6Args += @("--out", "experimental-prometheus-rw")
  Write-Host "Sending metrics to: $rwUrl"
} else {
  Write-Host "PROMETHEUS_RW_URL not set — running with stdout summary only."
}

$k6Args += "/scripts/shopperf.js"

Write-Host "Target: $($env:BASE_URL)"
Write-Host "Test ID (testid tag): $($env:TEST_RUN_ID)"
Write-Host "Users: $($env:TEST_EMAIL_PREFIX)-vu{N}@$(if ($env:TEST_EMAIL_DOMAIN) { $env:TEST_EMAIL_DOMAIN } else { 'example.com' })"
Write-Host "Profile: $(if ($env:K6_VUS) { $env:K6_VUS } else { '5' }) VUs, ramp $(if ($env:K6_RAMP_UP) { $env:K6_RAMP_UP } else { '5s' }) / hold $(if ($env:K6_HOLD) { $env:K6_HOLD } else { '25s' }) / down $(if ($env:K6_RAMP_DOWN) { $env:K6_RAMP_DOWN } else { '5s' }), cart=$(if ($env:K6_CART_MODE) { $env:K6_CART_MODE } else { 'add' })"
Write-Host "Running k6 via Docker..."

$dockerArgs += @($Image) + $k6Args
& docker @dockerArgs
