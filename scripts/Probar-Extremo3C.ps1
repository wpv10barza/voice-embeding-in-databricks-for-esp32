# Diagnóstico de extremo a extremo, solamente GET/read-only.
# Windows PowerShell 5.1 o PowerShell 7.
[CmdletBinding()]
param(
    [string]$AppUrl = "https://asistente-cloud-erp-7474651957738908.aws.databricksapps.com",
    [string]$Profile = "asistente-cloud-erp",
    [string]$DeviceId = "panel-4848s040-3c-ota-2f26ec3f",
    [string]$ExpectedSheetId = "1tLNo0_xjtmWKM9Y7PcChFut8S0w0kMKeAvFi9zg52gA",
    [string]$ExpectedTab = "Data",
    [int]$ExpectedHeaderRow = 4,
    [string]$PanelUrl = ""
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common3C.ps1")
$AppUrl = $AppUrl.TrimEnd("/")
# /api/health needs no Device API token. Check the entire App BEFORE
# asking for a private secret or blaming Sheets/Gemini for upstream 503.
$headers = Get-3CHeaders -Profile $Profile
$preflight = Invoke-3CRequest -Uri "$AppUrl/api/health" -Headers $headers
if ($preflight.Status -ne 200) {
    Write-Host "=== PREFLIGHT BLOQUEADO: /api/health HTTP $($preflight.Status) ===" -ForegroundColor Red
    Write-Host "No es posible confirmar Google Sheets ni voz mientras Databricks no responda."
    & (Join-Path $PSScriptRoot "Diagnosticar-App503.ps1") -AppUrl $AppUrl -Profile $Profile
    exit 2
}
$headers = Get-3CHeaders -Profile $Profile -PromptDeviceToken
$passed = 0
$failed = 0

function Check-3C {
    param([string]$Name, [string]$Path, [scriptblock]$Validate)
    $r = Invoke-3CRequest -Uri "$AppUrl$Path" -Headers $headers
    $ok = $false
    if ($r.Status -eq 200 -and $null -ne $r.Data) {
        try { $ok = [bool](& $Validate $r.Data) } catch { $ok = $false }
    }
    if ($ok) {
        $script:passed++
        Write-Host ("[PASS] {0} (HTTP {1})" -f $Name, $r.Status) -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host ("[FAIL] {0} (HTTP {1})" -f $Name, $r.Status) -ForegroundColor Red
        if ($r.Status -eq 401) { Write-Host "  Revisa ESP32_API_TOKEN. No copies su valor en el chat." }
        elseif ($r.Status -eq 403) { Write-Host "  Revisa acceso OAuth/permisos a Databricks Apps." }
        elseif ($r.Status -eq 404) { Write-Host "  El commit desplegado NO contiene esta ruta o la URL es incorrecta." }
        elseif ($r.Status -eq 502) { Write-Host "  Falló lectura real de Google Sheets; comprobar clave SA y compartir la hoja." }
        elseif ($r.Status -eq 409) { Write-Host "  Se leyó la hoja, pero los encabezados no coinciden." }
        elseif ($r.Status -eq 0) { Write-Host "  $($r.Error)" }
        elseif ($r.Status -eq 503) { Write-Host "  Ruta 503: verificar detalle de la API; no implica que Gemini/Sheets hayan fallado." }
        elseif ($null -eq $r.Data) { Write-Host "  Respuesta no es JSON, posible portal de login." }
    }
    return $r
}

Write-Host "=== DIAGNOSTICO DATABRICKS + SHEETS + ESP32 (SOLO LECTURA) ==="
if (-not $headers.ContainsKey("Authorization")) {
    Write-Warning "No se obtuvo Bearer de Databricks Apps. Define DATABRICKS_ACCESS_TOKEN si la app requiere OAuth."
}
if (-not $headers.ContainsKey("X-3C-Device-Token")) {
    Write-Warning "No se obtuvo ESP32_API_TOKEN. Las rutas protegidas deben fallar cerradas."
}
$backend = Check-3C "Backend Databricks" "/api/health" {
    param($j) $j.ok -eq $true -and $j.service -eq "asistente-databricks-erp"
}
$device = Check-3C "Device API + confirmacion humana" "/api/device/v1/health" {
    param($j) $j.ok -eq $true -and $j.accepts_commands -eq $true -and
        $j.requires_human_confirmation -eq $true
}
$sheet = Check-3C "Google Sheets: acceso REAL y esquema" "/api/device/v1/cloud/verify" {
    param($j)
    $j.ok -eq $true -and $j.google_sheets.connected -eq $true -and
        $j.google_sheets.spreadsheet_id -eq $ExpectedSheetId -and
        $j.google_sheets.sheet_name -eq $ExpectedTab -and
        [int]$j.google_sheets.header_row -eq $ExpectedHeaderRow -and
        $j.google_sheets.verified_by -eq "live_google_sheets_api_read"
}
if ($sheet.Status -eq 200 -and $sheet.Data) {
    $v = $sheet.Data.google_sheets
    Write-Host "  Hoja: $($v.sheet_name), encabezado: $($v.header_row), auth: $($v.auth_mode)"
    Write-Host "  Escritura habilitada: $($sheet.Data.sheet_write_enabled)"
    if ($sheet.Data.sheet_write_enabled -eq $true) {
        Write-Warning "ALLOW_SHEET_WRITE=true. Este diagnóstico no modifica celdas."
    }
}
$voice = Check-3C "Modelo IA/voz y bandeja" "/api/device/v1/voice/health" {
    param($j) $j.ok -eq $true -and $j.module -eq "voice-3c" -and
       $j.model_configured -eq $true -and
       $j.local_confirmation_required -eq $true
}
$inbox = Check-3C "Bandeja ESP32 accesible" ("/api/device/v1/voice/inbox?device_id=" + [uri]::EscapeDataString($DeviceId)) {
    param($j) $null -ne $j.PSObject.Properties["draft"]
}
if ($PanelUrl) {
    $panel = Invoke-3CRequest -Uri ($PanelUrl.TrimEnd("/") + "/health") -Headers @{}
    if ($panel.Status -eq 200 -and $panel.Data -and $panel.Data.ok -eq $true -and
        $panel.Data.wifi -eq $true -and $panel.Data.backend -eq $true) {
        $passed++
        Write-Host "[PASS] Panel ESP32 detectado en red local, Wi-Fi y backend activos" -ForegroundColor Green
    } else {
        $failed++
        Write-Host "[FAIL] Panel ESP32 no confirmó Wi-Fi y backend (HTTP $($panel.Status))" -ForegroundColor Red
    }
} else {
    Write-Host "[INFO] Sin -PanelUrl solo se comprueban servicios cloud, NO la entrega fisica al ESP32."
}
Write-Host ("RESULTADO: {0} OK / {1} FAIL" -f $passed, $failed)
Write-Host "Ningun POST ni modificacion de Google Sheets ejecutada."
if ($failed -gt 0) { exit 2 }
exit 0
