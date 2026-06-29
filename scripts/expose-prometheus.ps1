param(
  [string]$RemoteHost = "dev-vm1.test.local"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $Root "k8s\prometheus-external.yaml"

Write-Host "Applying Prometheus LoadBalancer on $RemoteHost ..."
Get-Content $Manifest | ssh $RemoteHost "kubectl apply -f -"

Write-Host "Waiting for external IP..."
for ($i = 0; $i -lt 30; $i++) {
  $ip = ssh $RemoteHost "kubectl get svc prometheus-remote-write -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null"
  if ($ip) {
    Write-Host ""
    Write-Host "Prometheus remote write URL:"
    Write-Host "  http://${ip}:9090/api/v1/write"
    Write-Host ""
    Write-Host "Add to k6\.env:"
    Write-Host "  PROMETHEUS_RW_URL=http://${ip}:9090/api/v1/write"
    exit 0
  }
  Start-Sleep -Seconds 2
}

Write-Host "Service applied but no external IP yet. Check with:"
Write-Host "  ssh $RemoteHost `"kubectl get svc prometheus-remote-write -n monitoring`""
