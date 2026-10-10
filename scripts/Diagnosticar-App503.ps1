# Databricks Apps HTTP 503 diagnostic. No writes, no tokens printed.
[CmdletBinding()]
param(
    [string]$AppName = "asistente-cloud-erp",
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [switch]$MostrarLogs
)
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$AppUrl = $AppUrl.TrimEnd("/")

function Get-SafeProperty {
    param([object]$Value, [string]$Property)
    if ($null -eq $Value) { return $null }
    $found = $Value.PSObject.Properties[$Property]
    if ($null -eq $found) { return $null }
    return $found.Value
}

Write-Host "=== ESTADO DATABRICKS APPS (SIN MODIFICACIONES) ==="
$headers = Get-3CHeaders -Profile $Profile
if (-not $headers.ContainsKey("Authorization")) {
    Write-Warning "Sin Bearer OAuth. Verifique: databricks auth describe --profile $Profile"
}
$response = Invoke-3CRequest -Uri "$AppUrl/api/health" -Headers $headers
Write-Host "HTTP /api/health: $($response.Status)"
if ($response.Status -eq 503) {
    Write-Warning "La App o su gateway NO atiende /api/health: aun no es un fallo demostrado de Gemini/Sheets."
} elseif ($response.Status -eq 401 -or $response.Status -eq 403) {
    Write-Warning "Falta acceso/autorizacion Databricks Apps; compruebe OAuth y permisos."
} elseif ($response.Status -eq 200) {
    Write-Host "Backend responde 200. Continuar con Probar-Extremo3C.ps1." -ForegroundColor Green
} elseif ($response.Status -eq 0) {
    Write-Warning "Fallo DNS/TLS/transporte: $($response.Error)"
} else {
    Write-Warning "HTTP inesperado. Consulte estado y logs."
}
if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
    Write-Warning "No esta disponible Databricks CLI. Revise Databricks Apps > Overview/Deployments/Logs."
    exit 2
}
Write-Host "--- Informacion App ---"
try {
    $json = (& databricks apps get $AppName --profile $Profile --output json 2>$null) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "Databricks CLI apps get fallo" }
    $app = $json | ConvertFrom-Json
    $status = Get-SafeProperty $app "app_status"
    $compute = Get-SafeProperty $app "compute_status"
    Write-Host ("App: " + (Get-SafeProperty $app "name"))
    Write-Host ("URL registrada: " + (Get-SafeProperty $app "url"))
    Write-Host ("App status: " + (Get-SafeProperty $status "state"))
    Write-Host ("App message: " + (Get-SafeProperty $status "message"))
    Write-Host ("Compute status: " + (Get-SafeProperty $compute "state"))
} catch {
    Write-Warning "No fue posible obtener estado: $($_.Exception.Message)"
    Write-Host "Pruebe: databricks apps get $AppName --profile $Profile --output json"
}
Write-Host "--- Ultimo despliegue ---"
try {
    $json = (& databricks apps get-deployment $AppName latest --profile $Profile --output json 2>$null) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "Databricks CLI get-deployment fallo" }
    $deploy = $json | ConvertFrom-Json
    $status = Get-SafeProperty $deploy "status"
    $source = Get-SafeProperty $deploy "git_source"
    Write-Host ("Deployment id: " + (Get-SafeProperty $deploy "deployment_id"))
    Write-Host ("Deployment state: " + (Get-SafeProperty $status "state"))
    Write-Host ("Deployment message: " + (Get-SafeProperty $status "message"))
    Write-Host ("Source commit: " + (Get-SafeProperty $source "resolved_commit"))
} catch {
    Write-Warning "No fue posible obtener ultimo despliegue: $($_.Exception.Message)"
    Write-Host "Pruebe: databricks apps list-deployments $AppName --profile $Profile"
}
if ($MostrarLogs) {
    Write-Host "--- Ultimas 40 lineas (pueden contener datos sensibles: revisar antes de compartir) ---"
    & databricks apps logs $AppName --tail-lines 40 --profile $Profile
} else {
    Write-Host "--- Para consultar errores reales: ---"
    Write-Host "databricks apps logs $AppName --tail-lines 50 --profile $Profile"
    Write-Host "(Revise y oculte cualquier secreto antes de compartir logs)."
}
Write-Host "Si Compute/App esta STOPPED, la accion correctiva es:"
Write-Host "databricks apps start $AppName --profile $Profile"
Write-Host "Si esta FAILED o no levanta: primero revisar Logs y recursos Secret/Volume."
Write-Host "No se han modificado Apps, archivos, Google Sheets ni ESP32."
