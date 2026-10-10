# Interactive Windows microphone: Enter to speak, X to exit.
# Windows Speech Recognition transcribes locally, Databricks queues a draft,
# ESP32 displays it for manual confirmation. No Sheets writes.
[CmdletBinding()]
param(
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-01",
    [ValidateRange(5,40)][int]$TiempoMaxSegundos = 15,
    [ValidateRange(10,180)][int]$EsperaSegundos = 60
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    throw "ESP32_API_TOKEN requerido para usar voz en Databricks."
}
$base = $AppUrl.TrimEnd("/")
$health = Invoke-3CRequest -Uri "$base/api/device/v1/voice/health" -Headers $headers
if ($health.Status -ne 200 -or -not $health.Data.ok) {
    throw "Databricks no esta listo: API Voz 3C HTTP $($health.Status)."
}
Write-Host "[DATABRICKS] LISTO - API voz 3C accesible" -ForegroundColor Green
Write-Host "Gemini configurado: $($health.Data.model_configured) (sin inferencia probada)"
Write-Host "Micrófono: PC Windows, dictado local de Windows."
Write-Host "Dispositivo destino: $DeviceId"
Write-Host "Deja EDITAR ORDEN 3C abierto. NO pulses ENVIAR 3C antes de revisar el texto."
Write-Host "Este script no modifica Google Sheets."
$previous = $env:ESP32_API_TOKEN
try {
    $env:ESP32_API_TOKEN = [string]$headers["X-3C-Device-Token"]
    while ($true) {
        $choice = Read-Host "ENTER = ACTIVAR MICROFONO / X = salir"
        if ($choice -in @("x", "X", "salir", "SALIR")) { break }
        if ($choice -ne "") { continue }
        try {
            & (Join-Path $PSScriptRoot "Enviar-Voz3C.ps1") -Microfono -AppUrl $base -Profile $Profile -DeviceId $DeviceId -TiempoMaxSegundos $TiempoMaxSegundos -EsperarEntrega -EsperaSegundos $EsperaSegundos
            Write-Host "Listo para otra orden. Presiona ENTER cuando quieras hablar."
        } catch {
            Write-Warning "Orden no completada: $($_.Exception.Message)"
            Write-Host "Puedes intentar otra vez sin cerrar PowerShell."
        }
    }
} finally {
    if ($null -eq $previous) {
        Remove-Item Env:ESP32_API_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:ESP32_API_TOKEN = $previous
    }
}
Write-Host "Sesion de dictado cerrada. No se modifico Sheets."
