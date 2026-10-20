# Optional physical E2E probe: harmless draft to ESP32 edit screen.
# Never POSTs to /api/device/v1/commands or Google Sheets.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][switch]$EjecutarPrueba,
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-ota-2f26ec3f",
    [int]$TimeoutSeconds = 45,
    [string]$PanelUrl = ""
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) { throw "ESP32_API_TOKEN requerido." }
$base = $AppUrl.TrimEnd("/")
Write-Host "La prueba llenará EDITAR ORDEN 3C con texto de demostración. NO lo envíes ni apruebes."
$answer = Read-Host "¿Iniciar prueba en dispositivo? [S/n]"
if ($answer -notin @("S","s","si","SI","Sí","sí")) { Write-Host "Cancelado"; exit 0 }
$body = @{
 device_id = $DeviceId
 request_id = "probe-" + [Guid]::NewGuid().ToString("N")
 text = "PRUEBA DE CONEXION VOZ 3C - NO ENVIAR, NO MODIFICAR GOOGLE SHEETS"
}
$create = Invoke-3CRequest -Uri "$base/api/device/v1/voice/drafts" -Headers $headers -Method POST -Body $body
if ($create.Status -ne 202 -or -not $create.Data.draft_id) { throw "Borrador no creado: HTTP $($create.Status)" }
$id = [string]$create.Data.draft_id
Write-Host "Esperando confirmación de recepción por el ESP32. draft_id=$id"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $path = "/api/device/v1/voice/drafts/$id" + "?device_id=" + [uri]::EscapeDataString($DeviceId)
    $status = Invoke-3CRequest -Uri "$base$path" -Headers $headers
    if ($status.Status -eq 200 -and $status.Data.status -eq "delivered_to_editor") {
        Write-Host "[PASS] ESP32 reconoció y abrió el borrador. Google Sheets NO cambió." -ForegroundColor Green
        exit 0
    }
    if ($status.Status -ne 200) {
        Write-Warning "Consulta de estado HTTP $($status.Status)"
        break
    }
    Write-Host ("Estado: " + $status.Data.status)
}
Write-Warning "El borrador quedo en queued_for_editor. Es entrega no confirmada, no un error de Google Sheets."
if ($PanelUrl) {
    Write-Host "Diagnostico adicional de firmware y tarea de voz del ESP32:"
    & (Join-Path $PSScriptRoot "Diagnosticar-PanelESP32.ps1") -PanelUrl $PanelUrl -ExpectedDeviceId $DeviceId
} else {
    Write-Host "Para localizar la causa, ejecute Diagnosticar-PanelESP32.ps1 -PanelUrl http://IP_DEL_ESP32"
}
exit 2
