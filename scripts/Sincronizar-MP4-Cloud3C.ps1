#requires -Version 5.1
# Sincroniza main y procesa el MP4 de la falla del dictado 3C.
# No publica MP4 en GitHub, no escribe Google Sheets ni flashea firmware.
[CmdletBinding()]
param(
    [string]$VideoPath = '',
    [string]$VolumeDir = '',
    [ValidateRange(0,7200)][int]$InicioSegundos = 0,
    [ValidateRange(2,15)][int]$DuracionSegundos = 10,
    [string]$Profile = 'asistente-cloud-erp',
    [switch]$DesplegarCloud,
    [switch]$EnviarAudioCloud,
    [switch]$SubirMp4Cloud
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Requerir([string]$Nombre) {
    if (-not (Get-Command $Nombre -ErrorAction SilentlyContinue)) {
        throw "Falta $Nombre en PATH."
    }
}
function Comprobar([string]$Nombre, [string[]]$Argumentos) {
    & $Nombre @Argumentos
    if ($LASTEXITCODE -ne 0) { throw "$Nombre fallo (codigo $LASTEXITCODE)." }
}
function EncontrarVideo([string]$Elegido) {
    if ($Elegido) {
        if (-not (Test-Path -LiteralPath $Elegido -PathType Leaf)) { throw "No existe $Elegido" }
        return (Resolve-Path -LiteralPath $Elegido).Path
    }
    $nombre = '20261010-2216-55.3668577.mp4'
    $rutas = @(
        (Join-Path $env:USERPROFILE "Downloads\$nombre"),
        (Join-Path $env:USERPROFILE "Desktop\$nombre"),
        (Join-Path $env:USERPROFILE "Videos\$nombre")
    )
    $hallados = @($rutas | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($hallados.Count -ne 1) {
        throw "Descarga el video del chat y usa -VideoPath 'C:\ruta\$nombre'. Coincidencias: $($hallados.Count)"
    }
    return (Resolve-Path -LiteralPath $hallados[0]).Path
}
Requerir 'git'
Push-Location $repo
try {
    $origin = (& git remote get-url origin | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $origin -notmatch '(?i)github\.com[:/]+wpv10barza/voice-embeding-in-databricks-for-esp32(?:\.git)?/?$') {
        throw "Esta carpeta no corresponde al repo de voz 3C: $origin"
    }
    $cambios = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $cambios.Count -gt 0) {
        throw "Hay cambios locales. Primero revisa git status; no se sobrescriben."
    }
    Write-Host '=== GIT: actualizar main sin perder cambios ==='
    Comprobar 'git' @('-c','http.version=HTTP/1.1','fetch','origin','main')
    Comprobar 'git' @('switch','main')
    Comprobar 'git' @('-c','http.version=HTTP/1.1','pull','--ff-only','origin','main')
    $sha = (& git rev-parse HEAD | Out-String).Trim()
    Write-Host "GIT OK: $sha" -ForegroundColor Green
} finally {
    Pop-Location
}
if ($DesplegarCloud) {
    Requerir 'databricks'
    $encender = Join-Path $repo 'scripts\Encender-Databricks-Main.ps1'
    if (-not (Test-Path -LiteralPath $encender)) { throw "Falta $encender" }
    & $encender -Profile $Profile
    if (-not $?) { throw 'El despliegue Databricks no fue confirmado.' }
}
if ($EnviarAudioCloud -or $SubirMp4Cloud) {
    $video = EncontrarVideo $VideoPath
    if ([IO.Path]::GetExtension($video).ToLowerInvariant() -ne '.mp4') {
        throw 'Se esperaba un archivo MP4.'
    }
    Write-Host "MP4: $video"
    Write-Host "SHA256: $((Get-FileHash -LiteralPath $video -Algorithm SHA256).Hash)"
}
if ($SubirMp4Cloud) {
    Requerir 'databricks'
    $dir = $VolumeDir.TrimEnd('/')
    if ($dir -notmatch '^dbfs:/Volumes/[^/]+/[^/]+/[^/]+(?:/.+)?$') {
        throw 'Indica un Volume EXISTENTE: -VolumeDir dbfs:/Volumes/CATALOGO/ESQUEMA/VOLUMEN/evidencias'
    }
    Write-Warning 'Verifica que el video no muestre claves, tokens o informacion privada.'
    $ok = Read-Host "Subir MP4 completo a $dir ? [S/N]"
    if ($ok -notin @('S','s','SI','si','Si','Sí','sí')) { throw 'Subida cancelada.' }
    Comprobar 'databricks' @('fs','ls',$dir,'--profile',$Profile)
    $destino = "$dir/$([IO.Path]::GetFileName($video))"
    Comprobar 'databricks' @('fs','cp',$video,$destino,'--profile',$Profile)
    Comprobar 'databricks' @('fs','ls',$dir,'--profile',$Profile)
    Write-Host "MP4 SUBIDO: $destino" -ForegroundColor Green
}
if ($EnviarAudioCloud) {
    Requerir 'ffmpeg'
    $wav = Join-Path ([IO.Path]::GetTempPath()) ("clip-3c-" + [Guid]::NewGuid().ToString('N') + '.wav')
    try {
        Write-Host 'Extrayendo AUDIO del MP4; Gemini no acepta este MP4 por el script actual...'
        Comprobar 'ffmpeg' @('-nostdin','-hide_banner','-loglevel','error','-y',
            '-ss',[string]$InicioSegundos,'-i',$video,'-map','0:a:0','-vn',
            '-ac','1','-ar','16000','-c:a','pcm_s16le','-t',[string]$DuracionSegundos,$wav)
        $bytes = (Get-Item -LiteralPath $wav).Length
        if ($bytes -le 44 -or $bytes -gt 1048576) {
            throw "WAV vacio o mayor a 1 MiB ($bytes bytes)."
        }
        Write-Host "WAV: $bytes bytes"
        $ok = Read-Host 'Probar Gemini y enviar transcripcion como BORRADOR al ESP32? [S/N]'
        if ($ok -notin @('S','s','SI','si','Si','Sí','sí')) { throw 'Transcripcion cancelada.' }
        & (Join-Path $repo 'scripts\Probar-Gemini3C.ps1') -Profile $Profile
        if (-not $?) { throw 'La prueba de Gemini no paso.' }
        & (Join-Path $repo 'scripts\Enviar-Voz3C.ps1') -AudioFile $wav -Profile $Profile -EsperarEntrega
        if (-not $?) { throw 'La recepcion del ESP32 no se confirmo.' }
    } finally {
        Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
    }
}
Write-Host 'Proceso terminado. Ningun cambio escrito en Google Sheets ni MP4 publicado en GitHub.' -ForegroundColor Green
