# NetGate optional anonymous telemetry client
# DEFAULT: DISABLED. Nothing is collected or sent until the user opts in.
# ASCII only - Windows PowerShell 5.1 compatible.
#
# This module NEVER records executable paths, filenames, usernames,
# machine names, or IP addresses. Only coarse event counters.
#
# Usage:
#   .\telemetry.ps1 -Action status
#   .\telemetry.ps1 -Action optin  -Endpoint "https://your-worker.example.com/ingest"
#   .\telemetry.ps1 -Action optout
#   .\telemetry.ps1 -Action event  -Event block -Success
#   .\telemetry.ps1 -Action flush

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'optin', 'optout', 'event', 'flush')]
    [string]$Action,
    [string]$Endpoint = '',
    [string]$Event = '',
    [switch]$Success
)

$ErrorActionPreference = 'Stop'

$cfgDir  = Join-Path $env:LOCALAPPDATA 'NetGate'
$cfgFile = Join-Path $cfgDir 'telemetry.json'
$queueFile = Join-Path $cfgDir 'telemetry-queue.jsonl'
$version = '1.0.0'

function Ensure-Dir {
    if (-not (Test-Path -LiteralPath $cfgDir)) {
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    }
}

function Read-Config {
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($cfgFile)
            return ($raw | ConvertFrom-Json)
        } catch {}
    }
    return [pscustomobject]@{
        enabled  = $false
        anonId   = ''
        endpoint = ''
    }
}

function Write-Config($cfg) {
    Ensure-Dir
    $json = ConvertTo-Json -InputObject $cfg -Depth 4 -Compress
    [System.IO.File]::WriteAllText($cfgFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AnonymousId {
    $cfg = Read-Config
    if (-not $cfg.anonId) {
        $cfg.anonId = [guid]::NewGuid().ToString('N')
        Write-Config $cfg
    }
    return $cfg.anonId
}

function Get-OsInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { return "$($os.MajorVersion).$($os.MinorVersion).$($os.BuildNumber)" }
    return 'unknown'
}

function Emit($obj) {
    ConvertTo-Json -InputObject $obj -Depth 6 -Compress
}

switch ($Action) {
    'status' {
        $cfg = Read-Config
        $qCount = 0
        if (Test-Path -LiteralPath $queueFile) {
            $qCount = @(Get-Content -LiteralPath $queueFile -ErrorAction SilentlyContinue).Count
        }
        Emit ([pscustomobject]@{
            enabled      = [bool]$cfg.enabled
            hasId        = [bool]$cfg.anonId
            endpointSet  = [bool]$cfg.endpoint
            queuedEvents = $qCount
            note         = 'Telemetry is off by default. No data leaves this machine unless enabled.'
        })
    }

    'optin' {
        if (-not $Endpoint) { throw 'ENDPOINT_REQUIRED' }
        $cfg = Read-Config
        $cfg.enabled = $true
        $cfg.endpoint = $Endpoint
        $id = Get-AnonymousId
        Write-Config $cfg
        Emit ([pscustomobject]@{ ok = $true; enabled = $true; note = 'Anonymous telemetry enabled.' })
    }

    'optout' {
        $cfg = Read-Config
        $cfg.enabled = $false
        $cfg.anonId = ''
        $cfg.endpoint = ''
        Write-Config $cfg
        if (Test-Path -LiteralPath $queueFile) { Remove-Item -LiteralPath $queueFile -Force -ErrorAction SilentlyContinue }
        Emit ([pscustomobject]@{ ok = $true; enabled = $false; note = 'Telemetry disabled and local data cleared.' })
    }

    'event' {
        $cfg = Read-Config
        if (-not $cfg.enabled) {
            Emit ([pscustomobject]@{ ok = $true; recorded = $false; note = 'Telemetry disabled, nothing recorded.' })
            return
        }
        if (-not $Event) { throw 'EVENT_REQUIRED' }
        $allowed = @('app_start','block','unblock','enable','disable','scan','export','import','reset','error')
        if ($allowed -notcontains $Event) { throw 'INVALID_EVENT' }
        $evt = [pscustomobject]@{
            v  = $version
            id = $cfg.anonId
            e  = $Event
            t  = [int][double]::Parse((Get-Date -UFormat %s))
            os = Get-OsInfo
            r  = if ($Success) { 1 } else { 0 }
        }
        Ensure-Dir
        $line = ConvertTo-Json -InputObject $evt -Depth 4 -Compress
        [System.IO.File]::AppendAllText($queueFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Emit ([pscustomobject]@{ ok = $true; recorded = $true })
    }

    'flush' {
        $cfg = Read-Config
        if (-not $cfg.enabled) {
            Emit ([pscustomobject]@{ ok = $true; sent = 0; note = 'Telemetry disabled, nothing sent.' })
            return
        }
        if (-not $cfg.endpoint) { throw 'ENDPOINT_NOT_CONFIGURED' }
        if (-not (Test-Path -LiteralPath $queueFile)) {
            Emit ([pscustomobject]@{ ok = $true; sent = 0 })
            return
        }
        $lines = @(Get-Content -LiteralPath $queueFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) {
            Emit ([pscustomobject]@{ ok = $true; sent = 0 })
            return
        }
        $batch = '[' + ($lines -join ',') + ']'
        try {
            $resp = Invoke-RestMethod -Uri $cfg.endpoint -Method Post -Body $batch `
                -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
            Remove-Item -LiteralPath $queueFile -Force -ErrorAction SilentlyContinue
            Emit ([pscustomobject]@{ ok = $true; sent = $lines.Count })
        } catch {
            Emit ([pscustomobject]@{ ok = $false; sent = 0; note = 'Flush failed, queue kept for retry.' })
        }
    }
}
