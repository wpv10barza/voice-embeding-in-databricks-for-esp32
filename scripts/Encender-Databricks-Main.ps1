#requires -Version 5.1
# Una sola llamada inicia Databricks App y sincroniza con main del BACKEND.
# Parametros: -SoloMostrar, -SoloIniciar, -ForzarDespliegue, -AbrirApp.
[CmdletBinding()]
param(
    [string]$AppName = "asistente-cloud-erp",
    [string]$Profile = "asistente-cloud-erp",
    [switch]$SoloMostrar,
    [switch]$SoloIniciar,
    [switch]$ForzarDespliegue,
    [switch]$AbrirApp
)
$ErrorActionPreference = "Stop"
$repository = "wpv10barza/asistente-de-databricks--erp"
$repositoryUrl = "https://github.com/$repository"
$appUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com/"
function Get-MainCommit {
    try {
        $h = @{Accept="application/vnd.github+json"; "User-Agent"="Databricks-Main-Launcher"}
        $data = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/branches/main" -Headers $h -TimeoutSec 25
        $sha = [string]$data.commit.sha
        if ($sha -notmatch '^[0-9a-fA-F]{40}$') { throw "GitHub SHA invalido." }
        return $sha.ToLowerInvariant()
    } catch {
        Write-Warning "GitHub API fallo; probando git ls-remote HTTP/1.1..."
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "No se puede verificar main." }
        $list = @(& git -c http.version=HTTP/1.1 ls-remote "$repositoryUrl.git" refs/heads/main 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $list) { throw "Sin acceso a GitHub. No desplegare un commit sin verificar." }
        $sha = ([string]$list[0] -split '\s+')[0]
        if ($sha -notmatch '^[0-9a-fA-F]{40}$') { throw "SHA remoto invalido." }
        return $sha.ToLowerInvariant()
    }
}
function Run-DatabricksJson {
    param([Parameter(Mandatory)][string[]]$CliArgs)
    $lines = @(& databricks @CliArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Error Databricks CLI: $($CliArgs[0]) $($CliArgs[1]). Ejecuta: databricks auth describe --profile $Profile" }
    $json = ($lines | Out-String).Trim()
    if (-not $json) { throw "Databricks no devolvio JSON." }
    try { return ConvertFrom-Json -InputObject $json -ErrorAction Stop }
    catch { throw "No fue posible interpretar el JSON de la CLI." }
}
Write-Host "=== INICIAR DATABRICKS CON MAIN ===" -ForegroundColor Cyan
Write-Host "Repositorio BACKEND: $repository"
$head = Get-MainCommit
Write-Host "MAIN COMMIT: $head" -ForegroundColor Green
Write-Host "$repositoryUrl/commit/$head"
if ($SoloMostrar) { Write-Host "Consulta terminada; sin cambios."; return }
if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) { throw "No se encontro Databricks CLI en PATH." }
$app = Run-DatabricksJson -CliArgs @('apps','get',$AppName,'--profile',$Profile,'--output','json')
$gitUrl = [string]$app.git_repository.url
if ($gitUrl -and ($gitUrl.TrimEnd('/').Replace('.git','') -ne $repositoryUrl)) {
    throw "El origen Git de la App es distinto ($gitUrl). Operacion detenida."
}
$appState = [string]$app.app_status.state
$computeState = [string]$app.compute_status.state
Write-Host "Databricks App: $appState | Compute: $computeState"
$stopped = ($appState -match 'STOPPED|INACTIVE|ERROR') -or ($computeState -match 'STOPPED|INACTIVE|ERROR')
if ($stopped) {
    Write-Host "Encendiendo $AppName..." -ForegroundColor Yellow
    $null = Run-DatabricksJson -CliArgs @('apps','start',$AppName,'--profile',$Profile,'--timeout','10m','--output','json')
    Write-Host "[OK] App iniciada." -ForegroundColor Green
} else {
    Write-Host "La App no esta detenida; no se reinicia."
}
if ($SoloIniciar) {
    Write-Host "SoloIniciar: sin nuevo despliegue."
    Write-Host $appUrl
    if ($AbrirApp) { Start-Process $appUrl }
    return
}
$installed = [string]$app.active_deployment.git_source.resolved_commit
if (-not $installed) {
    try {
        $latest = Run-DatabricksJson -CliArgs @('apps','get-deployment',$AppName,'latest','--profile',$Profile,'--output','json')
        $installed = [string]$latest.git_source.resolved_commit
    } catch { Write-Warning "No se pudo leer SHA instalado; se verificara al desplegar." }
}
Write-Host "COMMIT INSTALADO: $(if ($installed) { $installed } else { 'sin identificar' })"
if ($installed -eq $head -and -not $ForzarDespliegue) {
    Write-Host "[OK] Databricks ya ejecuta el ultimo main; no se redepliega." -ForegroundColor Green
} else {
    Write-Host "Desplegando main $head..." -ForegroundColor Yellow
    $deployment = Run-DatabricksJson -CliArgs @('apps','deploy',$AppName,'--git-commit',$head,'--profile',$Profile,'--timeout','10m','--output','json')
    $state = [string]$deployment.status.state
    $actual = [string]$deployment.git_source.resolved_commit
    if ($state -and $state -ne 'SUCCEEDED') { throw "Despliegue no confirmado: $state" }
    if ($actual -and $actual -ne $head) { throw "El commit desplegado no coincide con MAIN." }
    Write-Host "[OK] Desplegado $head" -ForegroundColor Green
}
Write-Host "App: $appUrl"
Write-Host "No se enviaron cambios a Google Sheets."
if ($AbrirApp) { Start-Process $appUrl }
