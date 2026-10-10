# Read-only status of the ESP32's existing HTTPS polling in Databricks.
# Does not require the panel LAN IP; never submits a command or edits Sheets.
[CmdletBinding()]
param(
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-01"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    throw "ESP32_API_TOKEN requerido. No copie el token en el chat."
}
$url = $AppUrl.TrimEnd("/") + "/api/device/v1/voice/sync?device_id=" + [uri]::EscapeDataString($DeviceId)
$r = Invoke-3CRequest -Uri $url -Headers $headers
if ($r.Status -eq 404) {
    throw "La App Databricks todavia no tiene /voice/sync: despliegue el backend con cloud mirror."
}
if ($r.Status -eq 503) {
    throw "El espejo persistente o la App no estan disponibles (HTTP 503); revise permisos del Volume."
}
if ($r.Status -ne 200 -or $null -eq $r.Data) {
    throw "No se pudo consultar estado del panel desde Databricks (HTTP $($r.Status)): $($r.Error)"
}
$j = $r.Data
Write-Host "=== DATAbRICKS: ESTADO DE VOZ 3C (sin IP local) ==="
Write-Host "Dispositivo: $($j.device_id)"
Write-Host "Espejo: $($j.mirror_mode) | Persiste reinicios: $($j.durable_across_restarts)"
Write-Host "Consultas recientes recibidas: $($j.panel_seen_recently)"
Write-Host "Segundos desde ultima consulta: $($j.seconds_since_panel_poll)"
Write-Host "Borradores pendientes: $($j.queued_for_editor)"
Write-Host "Borradores entregados: $($j.delivered_to_editor)"
if ($null -ne $j.capture_status) { Write-Host "Ultima solicitud de microfono Windows: $($j.capture_status)" }
if ($j.panel_seen_recently -eq $true) {
    Write-Host "[PASS] Databricks ha recibido consultas HTTPS recientes del ESP32." -ForegroundColor Green
} else {
    Write-Warning "Sin consulta HTTPS reciente. Revisar Wi-Fi, firmware instalado, OAuth M2M y Device API token."
}
if ($j.mirror_mode -eq "memory_only") {
    Write-Warning "Modo temporal. Para guardar entre reinicios configure VOICE_DRAFT_STORE_PATH en un Volume Databricks escribible."
}
Write-Host "Esta prueba no escribe Google Sheets ni envia ordenes."
