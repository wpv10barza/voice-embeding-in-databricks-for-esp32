# Common authenticated REST helpers. Dot-source; no execution on import.
Set-StrictMode -Version Latest

function Get-3CHeaders {
    param([string]$Profile = "asistente-cloud-erp", [switch]$PromptDeviceToken)
    $bearer = $env:DATABRICKS_ACCESS_TOKEN
    if (-not $bearer) { $bearer = $env:DATABRICKS_TOKEN }
    if (-not $bearer -and (Get-Command databricks -ErrorAction SilentlyContinue)) {
        try {
            $output = & databricks auth token --profile $Profile --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $output) {
                $result = ($output -join "`n") | ConvertFrom-Json
                $bearer = [string]$result.access_token
            }
        } catch { }
    }
    $deviceToken = $env:ESP32_API_TOKEN
    if (-not $deviceToken -and $PromptDeviceToken) {
        $secret = Read-Host "ESP32_API_TOKEN (oculto)" -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
        try { $deviceToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    $h = @{ Accept = "application/json" }
    if ($bearer) { $h["Authorization"] = "Bearer $bearer" }
    if ($deviceToken) { $h["X-3C-Device-Token"] = $deviceToken }
    return $h
}

function Invoke-3CRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [ValidateSet("GET","POST")][string]$Method = "GET",
        [object]$Body = $null
    )
    $args = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        UseBasicParsing = $true
        TimeoutSec = 25
        ErrorAction = "Stop"
    }
    if ($null -ne $Body) {
        $args["ContentType"] = "application/json; charset=utf-8"
        $args["Body"] = ConvertTo-Json -InputObject $Body -Depth 12 -Compress
    }
    try {
        $response = Invoke-WebRequest @args
        $statusCode = [int]$response.StatusCode
        $raw = [string]$response.Content
    } catch {
        $statusCode = 0
        $raw = ""
        $errorDetailMessage = $_.ErrorDetails.Message
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    try { $raw = $reader.ReadToEnd() }
                    finally { $reader.Dispose() }
                }
            } catch {}
        }
        if (-not $statusCode) {
            return [pscustomobject]@{ Status = 0; Data = $null; Error = "Fallo DNS/TLS/red: $($_.Exception.Message)" }
        }
    }
    # Windows PowerShell may consume the HTTP error response stream before
    # GetResponseStream(); ErrorDetails.Message retains JSON when available.
    if (-not $raw -and $statusCode -ge 400 -and $null -ne $errorDetailMessage) {
        $raw = [string]$errorDetailMessage
    }
    $payload = $null
    if ($raw) {
        try { $payload = $raw | ConvertFrom-Json -ErrorAction Stop }
        catch { $payload = $null }
    }
    return [pscustomobject]@{
        Status = $statusCode
        Data = $payload
        Error = if ($statusCode -ge 400) { "HTTP $statusCode" } else { "" }
    }
}


function Show-3CGeminiFailure {
    param([Parameter(Mandatory)]$Response)
    Write-Warning ("Transcripcion Gemini fallida. HTTP Databricks: " + $Response.Status)
    if ($null -ne $Response.Data -and $null -ne $Response.Data.detail) {
        $detail = $Response.Data.detail
        if ($detail -is [string]) {
            # Previous backend returned a generic 503 with no provider details.
            Write-Host "Backend anterior: detalle generico. Despliegue el backend con /voice/probe."
        } elseif ($detail.error -in @("GEMINI_UPSTREAM_ERROR", "GEMINI_NOT_CONFIGURED", "GEMINI_EMPTY_RESPONSE")) {
            Write-Host ("Codigo: " + [string]$detail.error)
            if ($detail.provider_http) { Write-Host ("Gemini HTTP real: " + $detail.provider_http) }
            if ($detail.provider_status) { Write-Host ("Estado Gemini: " + $detail.provider_status) }
            if ($detail.hint) { Write-Host ("Accion sugerida: " + $detail.hint) }
        }
    }
    if ($Response.Status -eq 503) {
        Write-Host "Ejecute .\scripts\Probar-Gemini3C.ps1 para separar permiso/cuota/modelo de problemas de audio."
    }
}
