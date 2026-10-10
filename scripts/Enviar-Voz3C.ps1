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
    [switch]$VistaPreviaIA
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    throw "Se requiere ESP32_API_TOKEN en Databricks y en esta sesión."
}
$base = $AppUrl.TrimEnd("/")

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
        Write-Host "Hable ahora (máximo $TiempoMaxSegundos segundos)."
        $heard = $engine.Recognize([TimeSpan]::FromSeconds($TiempoMaxSegundos))
        if (-not $heard -or -not $heard.Text) { throw "Windows no reconoció voz." }
        $Texto = $heard.Text
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
    $r = Invoke-3CRequest -Uri "$base/api/device/v1/voice/transcribe" -Headers $headers -Method POST -Body $body
    if ($r.Status -ne 200 -or -not $r.Data.transcript) {
        throw "Transcripción Databricks fallida (HTTP $($r.Status))."
    }
    $Texto = [string]$r.Data.transcript
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
