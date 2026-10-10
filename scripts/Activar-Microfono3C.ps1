# Alternative voice engines for Windows -> Databricks -> ESP32 3C drafts.
# Gemini: records WAV locally, transcribes with Databricks Gemini API.
# Wispr: Wispr Flow inserts text in focused PowerShell prompt, then queues it.
# Windows: legacy Windows Speech engine (fallback only).
# Every draft requires confirmation; no Sheet writes.
[CmdletBinding()]
param(
    [ValidateSet("Gemini", "Wispr", "Windows")][string]$Motor = "Gemini",
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-01",
    [ValidateRange(5, 25)][int]$TiempoMaxSegundos = 10,
    [ValidateRange(10, 180)][int]$EsperaSegundos = 60,
    [int]$MicrofonoDispositivo = -1
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
Write-Host "Modelo Gemini configurado: $($health.Data.transcription_model)"
Write-Host "Configuracion Gemini disponible: $($health.Data.model_configured) (inferencia aun no probada)"
Write-Host "Motor seleccionado: $Motor"
Write-Host "Destino: $DeviceId"
Write-Host "Deja EDITAR ORDEN 3C abierto en el ESP32; no envies el texto sin revisarlo."
if ($Motor -eq "Gemini") {
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw "Necesitas el lanzador Python de Windows 'py' para grabar WAV. No se usa el reconocedor de voz Windows."
    }
    Write-Host "[GEMINI] Validando inferencia real de modelo antes de grabar (puede consumir cuota)..."
    $probe = Invoke-3CRequest -Uri "$base/api/device/v1/voice/probe" -Headers $headers -Method POST
    if ($probe.Status -eq 404) {
        throw "Falta el endpoint /voice/probe. Despliegue el backend Gemini actualizado antes de grabar."
    }
    if ($probe.Status -ne 200 -or -not $probe.Data.inference_confirmed) {
        Show-3CGeminiFailure -Response $probe
        throw "Gemini no esta listo para una inferencia real. No se iniciara grabacion."
    }
    Write-Host "[GEMINI] INFERENCIA REAL OK: $($probe.Data.model)" -ForegroundColor Green
    Write-Host "[GEMINI] El PC graba WAV y Databricks hace la transcripcion real."
    Write-Host "[MIC] Comprueba la fuente real antes de dictar:"
    Write-Host "  .\scripts\Probar-Captura3C.ps1 -Listar"
    Write-Host "  .\scripts\Probar-Captura3C.ps1 -MicrofonoDispositivo ID"
    Write-Host "[MIC] Seleccion: $($(if ($MicrofonoDispositivo -ge 0) { $MicrofonoDispositivo } else { 'predeterminado de Windows' }))"
    Write-Host "[PRIMER USO] Si falta sounddevice: py -m pip install sounddevice"
} elseif ($Motor -eq "Wispr") {
    Write-Host "[WISPR FLOW] Inicia Wispr Flow en Windows y manten el foco en la consola al dictar."
    Write-Host "Activa Wispr con Ctrl+Win (atajo predeterminado, puede haber cambiado)."
    Write-Host "Si el dictado no aparece: Shift+Alt+Z = pegar ultima transcripcion (Windows)."
    Write-Host "Alternativa: Shift+Alt+X = copiar ultima transcripcion, luego Ctrl+V."
    Write-Host "PowerShell espera TEXTO PEGADO; NO graba ni transcribe audio usando Wispr."
    Write-Host "Wispr debe estar instalado y ejecutandose; no se usa API Wispr en Databricks."
} else {
    Write-Warning "Se usa el reconocedor local de Windows que genero transcripciones incorrectas."
}
$previous = $env:ESP32_API_TOKEN
try {
    $env:ESP32_API_TOKEN = [string]$headers["X-3C-Device-Token"]
    while ($true) {
        $choice = Read-Host "ENTER = DICTAR CON $Motor / X = salir"
        if ($choice -in @("x", "X", "salir", "SALIR")) { break }
        if ($choice -ne "") { continue }
        try {
            if ($Motor -eq "Wispr") {
                Write-Host "En el siguiente prompt, use el atajo de Wispr Flow; revise la frase y pulse ENTER."
                $dictado = Read-Host "WISPR FLOW - dicta aqui tu orden 3C"
                if ([string]::IsNullOrWhiteSpace($dictado)) {
                    Write-Warning "Wispr no inserto texto. No significa que Databricks este caido."
                    Write-Host "Comprueba que Wispr Flow este ABIERTO y que el cursor este en el prompt."
                    Write-Host "Prueba Shift+Alt+Z para pegar el ultimo dictado, o Shift+Alt+X seguido de Ctrl+V."
                    $dictado = Read-Host "RECUPERAR WISPR - pega la frase aqui (ENTER vacio para cancelar)"
                    if ([string]::IsNullOrWhiteSpace($dictado)) {
                        Write-Host "Cancelado; no se envio ningun borrador."
                        continue
                    }
                }
                Write-Host "[WISPR] Texto capturado: $dictado"
                & (Join-Path $PSScriptRoot "Enviar-Voz3C.ps1") -Texto $dictado -AppUrl $base -Profile $Profile -DeviceId $DeviceId -EsperarEntrega -EsperaSegundos $EsperaSegundos
            } elseif ($Motor -eq "Windows") {
                & (Join-Path $PSScriptRoot "Enviar-Voz3C.ps1") -Microfono -AppUrl $base -Profile $Profile -DeviceId $DeviceId -TiempoMaxSegundos $TiempoMaxSegundos -EsperarEntrega -EsperaSegundos $EsperaSegundos
            } else {
                $wav = Join-Path ([IO.Path]::GetTempPath()) ("orden3c-" + [Guid]::NewGuid().ToString("N") + ".wav")
                try {
                    $args = @((Join-Path $PSScriptRoot "Grabar-Microfono3C.py"), "--seconds", [string]$TiempoMaxSegundos, "--output", $wav)
                    if ($MicrofonoDispositivo -ge 0) { $args += @("--device", [string]$MicrofonoDispositivo) }
                    & py @args
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $wav)) {
                        throw "No se pudo grabar el microfono. Si falta la libreria: py -m pip install sounddevice"
                    }
                    & (Join-Path $PSScriptRoot "Enviar-Voz3C.ps1") -AudioFile $wav -AppUrl $base -Profile $Profile -DeviceId $DeviceId -EsperarEntrega -EsperaSegundos $EsperaSegundos
                } finally {
                    if (Test-Path -LiteralPath $wav) {
                        Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {
            Write-Warning "Orden no completada: $($_.Exception.Message)"
        }
        Write-Host "Listo para otra orden. Presiona ENTER o X para salir."
    }
} finally {
    if ($null -eq $previous) {
        Remove-Item Env:ESP32_API_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:ESP32_API_TOKEN = $previous
    }
}
Write-Host "Sesion cerrada. No se modifico Google Sheets."
