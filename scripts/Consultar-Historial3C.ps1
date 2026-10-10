# Read-only status and audit of real Databricks 3C proposals and Google Sheets attempts.
[CmdletBinding()]
param(
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-01",
    [ValidateRange(1,20)][int]$Limit = 20
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
if (-not $headers.ContainsKey("X-3C-Device-Token")) { throw "ESP32_API_TOKEN requerido" }
$url = $AppUrl.TrimEnd("/") + "/api/device/v1/history?device_id=" +
    [uri]::EscapeDataString($DeviceId) + "&limit=$Limit"
Write-Host "=== HISTORIAL REAL 3C / GOOGLE SHEETS (SOLO GET) ==="
$result = Invoke-3CRequest -Uri $url -Headers $headers
if ($result.Status -ne 200 -or -not $result.Data) {
    throw "No se pudo consultar historial: HTTP $($result.Status)."
}
$data = $result.Data
if ($data.PSObject.Properties.Name -notcontains "summary") {
    Write-Warning "Backend antiguo: faltan contadores auditados. Despliega version actualizada antes de interpretar los registros."
} else {
    $cnt = $data.summary
    Write-Host "APROBADAS: $($cnt.approved) | RECHAZADAS: $($cnt.rejected) | PENDIENTES: $($cnt.pending)"
    Write-Host "INTENTOS SHEETS: $($cnt.apply_attempts) | APLICADOS: $($cnt.applied) | BLOQUEADOS: $($cnt.blocked)"
}
Write-Host "ALCANCE DEL HISTORIAL: $($data.scope)"
if ($data.persistent -ne $true) {
    Write-Warning "Solo se conservan eventos de la sesion del proceso Databricks. Cero registros NO significa cero historico."
}
Write-Host "ORDENES 3C (solo dispositivo: $DeviceId)"
if ($data.orders -and @($data.orders).Count -gt 0) {
    $data.orders | Select-Object @{N="Fecha";E={$_.updated_at}},status,text,command_id |
        Format-Table -Wrap -AutoSize
} else {
    Write-Host "No existen ordenes conservadas para este dispositivo en el historial consultado."
}
Write-Host "DECISIONES E INTENTOS (todos los dispositivos y propuestas web)"
if ($data.PSObject.Properties.Name -contains "sheet_activity" -and
    $data.sheet_activity -and @($data.sheet_activity).Count -gt 0) {
    $data.sheet_activity | ForEach-Object {
        [pscustomobject]@{
            Fecha = $_.at
            Estado = $_.status
            Fila = $_.row
            Propuesta = $_.proposal_id
            Cambios = ((@($_.changes) | ForEach-Object { "$($_.cell)=$($_.value)" }) -join "; ")
            Motivo = $_.reason
        }
    } | Format-Table -Wrap -AutoSize
} else {
    Write-Host "No hay decisiones ni intentos conservados en la sesion consultada."
}
Write-Host "CONFIRMACIONES REALES DE ESCRITURA SHEETS"
if ($data.sheet_changes -and @($data.sheet_changes).Count -gt 0) {
    $data.sheet_changes | Select-Object at,status,row,proposal_id | Format-Table -AutoSize
} else {
    Write-Host "Ninguna confirmacion de escritura en el historial CONSERVADO (no se infiere el pasado)."
}
Write-Host "Solo lectura: no se ha solicitado ninguna modificacion de Google Sheets."
