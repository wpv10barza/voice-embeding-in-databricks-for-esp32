# Read-only on-device voice diagnostics; safe for Windows PowerShell 5.1.
# Example: .\scripts\Diagnosticar-PanelESP32.ps1 -PanelUrl http://192.168.1.23
[CmdletBinding()]
param(
    [string]$PanelUrl = "",
    [string]$ExpectedDeviceId = "panel-4848s040-3c-01",
    [string]$ExpectedCommit = "",
    [int]$WaitSeconds = 12
)
$ErrorActionPreference = "Stop"
# The cloud mirror does not require the panel's DHCP address.
if (-not $PanelUrl -or $PanelUrl -match '(?i)(IP_REAL_DEL_ESP32|IP_LOCAL_DEL_ESP32|IP_DEL_ESP32)') {
    Write-Warning "No se indico la IP real del ESP32. Se consultara el espejo Databricks (solo lectura)."
    & (Join-Path $PSScriptRoot "Diagnosticar-Mirror3C.ps1") -DeviceId $ExpectedDeviceId
    return
}
$base = $PanelUrl.TrimEnd("/")
if ($base -notmatch '^http://[^/]+$') {
    throw "PanelUrl debe ser http://IP_LOCAL_DEL_ESP32, sin credenciales ni rutas."
}
function Read-PanelStatus {
    try {
        $result = Invoke-RestMethod -Method GET -Uri "$base/health" -TimeoutSec 6
        if ($result.ok -ne $true) { throw "El endpoint no devolvio ok=true." }
        return $result
    } catch {
        throw "ESP32 sin respuesta en $base/health. Verifica Wi-Fi 2.4 GHz, IP local, cable USB y firmware. $($_.Exception.Message)"
    }
}
Write-Host "=== Diagnostico REAL del ESP32 (solo GET) ==="
$first = Read-PanelStatus
Write-Host "Firmware: $($first.fw_version)"
Write-Host "Commit instalado: $($first.fw_commit)"
Write-Host "Device ID: $($first.device_id)"
Write-Host "Wi-Fi: $($first.wifi) | Backend reconocido: $($first.backend)"

if ($first.PSObject.Properties.Name -notcontains "voice_poll_count") {
    Write-Warning "No existe telemetria de voz: el panel ejecuta una version antigua del firmware o no tiene el commit de diagnostico instalado. Una compilacion SUCCESS no prueba el upload."
    exit 2
}
if ($first.device_id -ne $ExpectedDeviceId) {
    Write-Warning "Device ID diferente. El borrador de PowerShell se dirige a $ExpectedDeviceId y este ESP32 se identifica como $($first.device_id)."
}
if ($ExpectedCommit -and $first.fw_commit -ne $ExpectedCommit) {
    Write-Warning "El firmware instalado no coincide con el commit esperado."
}
if ($first.wifi -ne $true) {
    Write-Warning "Wi-Fi desconectado. Verifica configuracion Nokia C3 (2.4 GHz) en NVS/local_config; no muestres ni envies su clave."
}
Write-Host "Consultas iniciales: $($first.voice_poll_count) | Ultimo HTTP: $($first.voice_poll_http)"
Write-Host "Borradores abiertos en editor: $($first.voice_editor_deliveries)"
Write-Host "Ultimo ACK HTTP: $($first.voice_ack_http) | ACK pendiente: $($first.voice_ack_pending)"

$wait = [Math]::Max(10,[Math]::Min(30,$WaitSeconds))
Write-Host "Esperando $wait segundos para comprobar que el ESP32 sigue consultando Databricks..."
Start-Sleep -Seconds $wait
$second = Read-PanelStatus
Write-Host "Consultas posteriores: $($second.voice_poll_count) | HTTP: $($second.voice_poll_http)"
if ([int]$second.voice_poll_count -le [int]$first.voice_poll_count) {
    Write-Warning "No aumentaron las consultas. Revisar tarea HTTPS, Wi-Fi o borrador abierto/ACK pendiente."
} else {
    Write-Host "[PASS] La tarea de consulta de voz esta activa." -ForegroundColor Green
}
switch ([int]$second.voice_poll_http) {
    200 { Write-Host "[PASS] El ESP32 accede al endpoint de voz de Databricks." -ForegroundColor Green }
    0 { Write-Warning "Aun no existe resultado de consulta: comprobar version y acceso a la red." }
    -10 { Write-Warning "VOICE POLL: Wi-Fi desconectado." }
    -11 { Write-Warning "VOICE POLL: no fue posible autenticarse por OAuth M2M en Databricks." }
    -12 { Write-Warning "VOICE POLL: URL no valida." }
    401 { Write-Warning "VOICE POLL HTTP 401: verificar ESP32_API_TOKEN, o el OAuth de Databricks." }
    403 { Write-Warning "VOICE POLL HTTP 403: falta permiso en Databricks Apps." }
    404 { Write-Warning "VOICE POLL HTTP 404: falta desplegar la ruta de bandeja de voz en Databricks." }
    default { Write-Warning "VOICE POLL HTTP $($second.voice_poll_http): revisar monitor serie y logs de Databricks." }
}
if ([int]$second.voice_editor_deliveries -gt 0) {
    Write-Host "[PASS] Se han abierto borradores en el editor 3C." -ForegroundColor Green
}
if ($second.voice_ack_pending -eq $true) {
    Write-Warning "El ESP32 tiene un ACK pendiente y lo reintentara cada 6 segundos."
}
if ([int]$second.voice_ack_http -ge 400) {
    Write-Warning "ACK HTTP $($second.voice_ack_http): revisar endpoint /voice/drafts/{id}/ack en Databricks."
}
Write-Host "Ninguna modificacion realizada en Google Sheets."
