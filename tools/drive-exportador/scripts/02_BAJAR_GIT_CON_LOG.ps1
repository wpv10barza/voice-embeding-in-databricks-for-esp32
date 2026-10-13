#requires -Version 5.1
<# Obtiene SOLO el código del exportador desde la rama publicada.
   No descarga MP4 ni modifica Drive. Ejecutar:
   powershell -NoProfile -ExecutionPolicy Bypass -File .\02_BAJAR_GIT_CON_LOG.ps1
#>
[CmdletBinding()]
param(
  [string]$Destino = 'D:\118102025\Downloads\Exportador_MP4_Cloud',
  [string]$Repositorio = 'wpv10barza/voice-embeding-in-databricks-for-esp32',
  [string]$Rama = 'feature/exportador-mp4-drive-2020-2025'
)
$ErrorActionPreference = 'Stop'
$logs = Join-Path $env:LOCALAPPDATA 'ExportadorMP4\Logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$log = Join-Path $logs ('git_pull_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $log -Force | Out-Null
$code = 0
try {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'No se encontro Git for Windows en PATH.' }
  $url = 'https://github.com/' + $Repositorio + '.git'
  if (-not (Test-Path -LiteralPath $Destino)) {
    $parent = Split-Path -Parent $Destino
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    & git clone --filter=blob:none --no-checkout --branch $Rama $url $Destino
    if ($LASTEXITCODE -ne 0) { throw 'Fallo git clone.' }
    & git -C $Destino sparse-checkout init --cone
    if ($LASTEXITCODE -ne 0) { throw 'Fallo git sparse-checkout init.' }
    & git -C $Destino sparse-checkout set tools/drive-exportador .github/workflows
    if ($LASTEXITCODE -ne 0) { throw 'Fallo git sparse-checkout set.' }
    & git -C $Destino checkout $Rama
    if ($LASTEXITCODE -ne 0) { throw 'Fallo git checkout.' }
  } else {
    if (-not (Test-Path -LiteralPath (Join-Path $Destino '.git'))) { throw 'Destino existe, pero no es repositorio Git.' }
    $origin = (& git -C $Destino remote get-url origin)
    if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'voice-embeding-in-databricks-for-esp32(\.git)?$') { throw 'Origen Git no autorizado.' }
    $dirty = @(& git -C $Destino status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Hay cambios locales; se cancela pull.' }
    & git -C $Destino checkout $Rama
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo seleccionar la rama.' }
    & git -C $Destino pull --ff-only origin $Rama
    if ($LASTEXITCODE -ne 0) { throw 'git pull fallo.' }
  }
  & git -C $Destino log -1 --format='%H%n%s%n%ad' --date=iso
  if ($LASTEXITCODE -ne 0) { throw 'Fallo git log.' }
  Write-Host ('CODIGO_RECUPERADO: '+(Join-Path $Destino 'tools\drive-exportador')) -ForegroundColor Green
} catch {
  $code = 1
  Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red
} finally {
  Write-Host ('Log: '+$log)
  Stop-Transcript | Out-Null
}
exit $code