# Local-only audio capture audit for Gemini/PowerShell.
# Lists input devices, records a short clip, plays it back, deletes it.
# No Databricks request, no order submission, no Google Sheets access.
[CmdletBinding()]
param(
  [switch]$Listar,
  [int]$MicrofonoDispositivo = -1,
  [ValidateRange(2,20)][int]$Segundos = 6
)
$ErrorActionPreference = "Stop"
$recorder = Join-Path $PSScriptRoot "Grabar-Microfono3C.py"
if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "No se encontro Python Launcher 'py' en Windows."
}
if ($Listar) {
    & py $recorder --list
    if ($LASTEXITCODE -ne 0) { throw "Error al listar micrófonos." }
    return
}
$wav = Join-Path ([IO.Path]::GetTempPath()) ("probar-mic-3c-" + [guid]::NewGuid().ToString("N") + ".wav")
try {
    $arguments = @($recorder, "--seconds", [string]$Segundos, "--output", $wav)
    if ($MicrofonoDispositivo -ge 0) {
        $arguments += @("--device", [string]$MicrofonoDispositivo)
    }
    Write-Host "=== PRUEBA LOCAL DEL MICROFONO (SIN DATABRICKS) ==="
    & py @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $wav)) {
        throw "No se pudo grabar. Instala la dependencia: py -m pip install sounddevice"
    }
    Write-Host "REPRODUCIENDO la captura para verificar que grabó su voz, NO el audio del PC..."
    $player = [System.Media.SoundPlayer]::new($wav)
    try {
        $player.Load()
        $player.PlaySync()
    } finally {
        $player.Dispose()
    }
    Write-Host "[OK] Prueba local completa. Si se oye otra voz o tutorial, cambie el micrófono." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
}
Write-Host "Ninguna orden 3C enviada; sin cambios en Google Sheets."
