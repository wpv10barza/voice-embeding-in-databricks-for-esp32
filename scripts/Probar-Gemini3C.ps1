# Authorized live Gemini inference probe: no audio, no Sheets writes.
# Use after the backend update that adds /api/device/v1/voice/probe.
[CmdletBinding()]
param(
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    throw "Se requiere ESP32_API_TOKEN para la prueba."
}
$base = $AppUrl.TrimEnd("/")
Write-Host "=== PROBAR GEMINI EN DATABRICKS (inferencia real de texto) ==="
Write-Host "No se usa microfono, no se envia orden 3C y no se modifican Google Sheets."
$health = Invoke-3CRequest -Uri "$base/api/device/v1/voice/health" -Headers $headers
if ($health.Status -ne 200 -or -not $health.Data.ok) {
    throw "Health Voz 3C no disponible: HTTP $($health.Status)."
}
Write-Host "Modelo configurado: $($health.Data.transcription_model)"
Write-Host "Clave enlazada: $($health.Data.model_configured)"
Write-Host "Solicitando inferencia REAL de prueba (puede consumir cuota Gemini)..."
$result = Invoke-3CRequest -Uri "$base/api/device/v1/voice/probe" -Headers $headers -Method POST
if ($result.Status -eq 200 -and $result.Data.inference_confirmed -eq $true) {
    Write-Host "[PASS] Gemini responde mediante Databricks. Modelo: $($result.Data.model)" -ForegroundColor Green
    Write-Host "La prueba NO verifica transcripcion de audio: haga una segunda prueba con -Motor Gemini."
    exit 0
}
if ($result.Status -eq 404) {
    Write-Warning "La aplicacion desplegada no contiene /voice/probe; despliegue el nuevo commit del backend."
} else {
    Show-3CGeminiFailure -Response $result
}
Write-Host "[FAIL] Gemini no ha confirmado inferencia real."
exit 2
