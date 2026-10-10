# Voluntary foreground agent: physical ESP32 "DICTAR PC" -> Windows Realtek -> Gemini -> Databricks -> ESP32 editor.
# Never listens until the operator explicitly starts this foreground script. Ctrl+C stops it.
# No LAN listener, no extra password on touchscreen, no automatic 3C command/Sheets write.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][switch]$Iniciar,
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "",
    [int]$MicrofonoDispositivo = 1,
    [ValidateRange(5,20)][int]$Segundos = 10,
    [ValidateRange(2,15)][int]$IntervaloSegundos = 3,
    [ValidateRange(10,180)][int]$EsperaEntregaSegundos = 75
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "Python Launcher py no está instalado. Instala Python y sounddevice."
}
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    throw "Falta credencial de Device API en Windows. Configúrela privadamente; el panel NO la solicita."
}
$base = $AppUrl.TrimEnd("/")
$auth = Invoke-3CRequest -Uri "$base/api/device/v1/voice/health" -Headers $headers
if ($auth.Status -ne 200 -or $null -eq $auth.Data) {
    throw "Backend de voz no disponible HTTP $($auth.Status). Comprobar deployment/OAuth."
}
$agentPath = "$base/api/device/v1/voice/capture/next"
if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
    $agentPath += "?device_id=" + [uri]::EscapeDataString($DeviceId)
}
$recordScript = Join-Path $PSScriptRoot "Grabar-Microfono3C.py"
Write-Host "=== AGENTE EXPLICITO DE DICTADO: ESP32 -> WINDOWS -> GEMINI -> ESP32 ===" -ForegroundColor Cyan
Write-Host "PC: micrófono ID $MicrofonoDispositivo | $Segundos segundos cuando se pulse DICTAR PC."
Write-Host ("Destino: " + $(if ($DeviceId) { $DeviceId } else { "AUTO (unico ESP32 que solicita dictado)" }))
Write-Host "El equipo PC debe seguir encendido y esta consola abierta. Ctrl+C para detener."
Write-Host "Un toque al botón del ESP32 autoriza una sola grabación. No se modifican Sheets."
$previous = $env:ESP32_API_TOKEN
try {
    # Reuse the already authenticated session for local subprocesses; never log the secret.
    $env:ESP32_API_TOKEN = [string]$headers["X-3C-Device-Token"]
    while ($true) {
        try {
            $response = Invoke-3CRequest -Uri $agentPath -Headers $headers
            if ($response.Status -eq 404) {
                throw "Falta el endpoint /voice/capture/next: desplegar backend nuevo."
            }
            if ($response.Status -eq 409) {
                Write-Warning "Hay mas de un panel solicitando microfono. Ejecute con -DeviceId para elegir."
                Start-Sleep -Seconds $IntervaloSegundos
                continue
            }
            if ($response.Status -ne 200) {
                Write-Warning "Bandeja de captura: HTTP $($response.Status). Reintentando."
                Start-Sleep -Seconds $IntervaloSegundos
                continue
            }
            $capture = $response.Data.capture
            if ($null -eq $capture) {
                Start-Sleep -Seconds $IntervaloSegundos
                continue
            }
            $captureId = [string]$capture.id
            $targetDeviceId = [string]$capture.device_id
            if ($targetDeviceId -notmatch '^[A-Za-z0-9._:-]{1,96}$') {
                throw "Databricks devolvio un device_id invalido."
            }
            if ($DeviceId -and $targetDeviceId -ne $DeviceId) {
                throw "El device_id de la solicitud no coincide con el configurado."
            }
            if ($captureId -notmatch '^[0-9a-fA-F-]{36}$') { throw "ID de captura inválido." }
            Write-Host "[PANEL] Solicitud recibida desde $targetDeviceId. Microfono Realtek ID $MicrofonoDispositivo." -ForegroundColor Green
            $wav = Join-Path ([IO.Path]::GetTempPath()) ("voice-3c-" + [guid]::NewGuid().ToString("N") + ".wav")
            $success = $false
            try {
                $args = @($recordScript, "--seconds", [string]$Segundos, "--device",
                          [string]$MicrofonoDispositivo, "--output", $wav)
                & py @args
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $wav)) {
                    throw "Falló la grabación en Windows."
                }
                if ((Get-Item $wav).Length -gt 1MB) { throw "Audio WAV excede 1 MiB." }
                $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($wav))
                $voice = Invoke-3CRequest -Uri "$base/api/device/v1/voice/transcribe" -Headers $headers -Method POST -Body @{
                    audio_base64 = $encoded; mime_type = "audio/wav"
                }
                if ($voice.Status -ne 200 -or -not $voice.Data.transcript) {
                    Show-3CGeminiFailure -Response $voice
                    throw "Gemini no pudo transcribir esta captura."
                }
                $text = [string]$voice.Data.transcript
                Write-Host "[GEMINI] $text" -ForegroundColor Cyan
                # The capture UUID is the idempotent request ID for PC retries.
                $queued = Invoke-3CRequest -Uri "$base/api/device/v1/voice/drafts" -Headers $headers -Method POST -Body @{
                    device_id = $targetDeviceId; text = $text; request_id = "capture-$captureId"
                }
                if ($queued.Status -ne 202 -or -not $queued.Data.draft_id) {
                    throw "Databricks no pudo colocar el borrador en bandeja (HTTP $($queued.Status))."
                }
                $success = $true
                $draftId = [string]$queued.Data.draft_id
                Write-Host "[DATABRICKS] Borrador $draftId en cola. ESP32 debe abrir EDITAR ORDEN 3C."
            } catch {
                Write-Warning ("[DICTADO] " + $_.Exception.Message)
            } finally {
                Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
                $finish = Invoke-3CRequest -Uri "$base/api/device/v1/voice/capture/$captureId/complete" -Headers $headers -Method POST -Body @{
                    device_id = $targetDeviceId; success = $success
                }
                if ($finish.Status -ne 200) { Write-Warning "No se pudo confirmar captura: HTTP $($finish.Status)" }
            }
            if ($success) {
                $deadline = (Get-Date).AddSeconds($EsperaEntregaSegundos)
                $delivered = $false
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 3
                    # The draft status API requires a matching device_id.
                    $status = Invoke-3CRequest -Uri ("$base/api/device/v1/voice/drafts/$draftId" +
                        "?device_id=" + [uri]::EscapeDataString($targetDeviceId)) -Headers $headers
                    if ($status.Status -ne 200) {
                        Write-Warning "Consulta de entrega HTTP $($status.Status)"
                        break
                    }
                    if ($status.Data.status -eq "delivered_to_editor") {
                        Write-Host "[ESP32] RECIBIDO EN EDITOR: confirme el texto antes de enviar 3C." -ForegroundColor Green
                        $delivered = $true
                        break
                    }
                }
                if (-not $delivered) {
                    Write-Warning "[ESP32] SIN ACK: el texto quedó pendiente. Revisar voice_poll_http en serie."
                }
            }
        } catch {
            Write-Warning ("[AGENTE] " + $_.Exception.Message)
        }
        Start-Sleep -Seconds $IntervaloSegundos
    }
} finally {
    $env:ESP32_API_TOKEN = $previous
}
