# Send a PC audio or text draft to Databricks. Never writes Sheets.
[CmdletBinding(DefaultParameterSetName="Text")]
param(
    [Parameter(ParameterSetName="Text",Mandatory)][string]$Texto,
    [Parameter(ParameterSetName="AudioFile",Mandatory)][string]$AudioFile,
    [Parameter(ParameterSetName="Microphone",Mandatory)][switch]$Microfono,
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-01",
    [int]$TiempoMaxSegundos = 15,
    [switch]$ConfirmarSinPregunta,
    [switch]$VistaPreviaIA,
    [switch]$EsperarEntrega,
    [ValidateRange(10,180)][int]$EsperaSegundos = 60
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    throw "Se requiere ESP32_API_TOKEN en Databricks y en esta sesión."
}
$base = $AppUrl.TrimEnd("/")
Write-Host "[CLOUD] Consultando Databricks: asistente-cloud-erp..."
$cloud = Invoke-3CRequest -Uri "$base/api/device/v1/voice/health" -Headers $headers
if ($cloud.Status -ne 200 -or -not $cloud.Data.ok) {
    throw "Databricks Voz 3C no esta listo. HTTP $($cloud.Status). Prueba Probar-Extremo3C.ps1."
}
Write-Host ("[CLOUD] LISTO: bandeja de voz disponible. Gemini configurado: " + $cloud.Data.model_configured) -ForegroundColor Green
Write-Host "[INFO] El estado LISTO confirma la API, no una inferencia Gemini real."

if ($PSCmdlet.ParameterSetName -eq "Microphone") {
    if ($env:OS -ne "Windows_NT") { throw "-Microfono requiere Windows." }
    Add-Type -AssemblyName System.Speech -ErrorAction Stop
    $recognizers = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
    $locale = $recognizers | Where-Object { $_.Culture.Name -like "es-*" } | Select-Object -First 1
    if (-not $locale) {
        throw "No hay reconocedor español instalado. Use -AudioFile WAV grabado en Windows."
    }
    $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($locale)
    try {
        $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        $engine.SetInputToDefaultAudioDevice()
        Write-Host "[MICROFONO WINDOWS] ACTIVO. Hable ahora (maximo $TiempoMaxSegundos segundos)."
        $heard = $engine.Recognize([TimeSpan]::FromSeconds($TiempoMaxSegundos))
        if (-not $heard -or -not $heard.Text) { throw "Windows no reconoció voz." }
        $Texto = $heard.Text
        Write-Host "[DICTADO WINDOWS] Texto reconocido: $Texto"
    } finally { $engine.Dispose() }
} elseif ($PSCmdlet.ParameterSetName -eq "AudioFile") {
    $source = (Resolve-Path -LiteralPath $AudioFile -ErrorAction Stop).Path
    $ext = [IO.Path]::GetExtension($source).ToLowerInvariant()
    $mime = switch ($ext) {
        ".wav" { "audio/wav" }
        ".mp3" { "audio/mpeg" }
        ".ogg" { "audio/ogg" }
        default { throw "Solo se admiten archivos WAV, MP3 u OGG." }
    }
    $file = Get-Item -LiteralPath $source
    if ($file.Length -gt 1MB) { throw "Audio mayor a 1 MiB. Grabe una orden corta." }
    $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
    $body = @{ audio_base64 = $encoded; mime_type = $mime }
    Write-Host "[DATABRICKS/GEMINI] Procesando audio y transcribiendo..."
    $r = Invoke-3CRequest -Uri "$base/api/device/v1/voice/transcribe" -Headers $headers -Method POST -Body $body
    if ($r.Status -ne 200 -or -not $r.Data.transcript) {
        Show-3CGeminiFailure -Response $r
        throw "Transcripción Gemini no disponible (HTTP $($r.Status)). Comprueba diagnóstico con Probar-Gemini3C.ps1."
    }
    $Texto = [string]$r.Data.transcript
    Write-Host "[GEMINI] Transcripcion recibida: $Texto"
    $encoded = $null
}
$Texto = ($Texto -replace '[\x00-\x1F\x7F]', ' ' -replace '\s+', ' ').Trim()
if (-not $Texto) { throw "No hay texto para el editor 3C." }
if ([Text.Encoding]::UTF8.GetByteCount($Texto) -gt 230) {
    throw "La orden supera los 230 bytes permitidos en el editor del ESP32."
}
Write-Host "--- VISTA PREVIA DE VOZ (NO MODIFICA SHEETS) ---"
Write-Host $Texto
if ($VistaPreviaIA) {
    $previewBody = @{ text = $Texto; detectedHeaders = @{}; detectedCatalogs = @{} }
    $preview = Invoke-3CRequest -Uri "$base/api/extract" -Headers $headers -Method POST -Body $previewBody
    if ($preview.Status -eq 200 -and $preview.Data) {
        Write-Host "--- INTERPRETACIÓN IA (PROPUESTA SIN APLICAR) ---"
        $preview.Data | ConvertTo-Json -Depth 7
    } else {
        Write-Warning "Interpretación opcional HTTP $($preview.Status); no se cambió Sheets."
    }
}
if (-not $ConfirmarSinPregunta) {
    $answer = Read-Host "¿Enviar borrador a EDITAR ORDEN 3C del ESP32? [S/n]"
    if ($answer -notin @("S","s","SI","Si","si","Sí","sí")) {
        Write-Host "Cancelado; no se creó ningún borrador."
        exit 0
    }
}
$requestId = "voice-" + [Guid]::NewGuid().ToString("N")
$body = @{ device_id = $DeviceId; request_id = $requestId; text = $Texto }
$post = Invoke-3CRequest -Uri "$base/api/device/v1/voice/drafts" -Headers $headers -Method POST -Body $body
if ($post.Status -ne 202 -or -not $post.Data.draft_id) {
    throw "No se pudo enviar el borrador (HTTP $($post.Status))."
}
Write-Host "Borrador enviado a Databricks: $($post.Data.draft_id)" -ForegroundColor Green
Write-Host "Estado: $($post.Data.status). El ESP32 debe abrirlo en EDITAR ORDEN 3C."
Write-Host "No se ha enviado una orden 3C final ni modificado Google Sheets."
if ($EsperarEntrega) {
    $draftId = [string]$post.Data.draft_id
    $deadline = (Get-Date).AddSeconds($EsperaSegundos)
    Write-Host "[ENTREGA] Esperando al ESP32 (device_id=$DeviceId, maximo $EsperaSegundos segundos)..."
    $lastStatus = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $statusPath = "/api/device/v1/voice/drafts/" + $draftId +
            "?device_id=" + [uri]::EscapeDataString($DeviceId)
        $state = Invoke-3CRequest -Uri "$base$statusPath" -Headers $headers
        if ($state.Status -ne 200 -or -not $state.Data) {
            Write-Warning "No se pudo consultar la entrega: HTTP $($state.Status)."
            exit 2
        }
        $now = [string]$state.Data.status
        if ($now -ne $lastStatus) {
            Write-Host "[ENTREGA] $now"
            $lastStatus = $now
        }
        if ($now -eq "delivered_to_editor") {
            Write-Host "[ESP32] RECIBIDO: el panel confirmo que abrio la orden en EDITAR ORDEN 3C." -ForegroundColor Green
            Write-Host "Revisa el texto en pantalla; no se ha enviado la orden final ni modificado Sheets."
            exit 0
        }
    }
    Write-Warning "El ESP32 no confirmo la entrega. El borrador sigue pendiente en Databricks."
    Write-Host "Comprueba firmware, IP local, Wi-Fi, device_id y voice_poll_http con Diagnosticar-PanelESP32.ps1."
    exit 2
}

