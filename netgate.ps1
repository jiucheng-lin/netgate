# NetGate CLI
# Usage examples:
#   .\netgate.ps1 -Action status
#   .\netgate.ps1 -Action list
#   .\netgate.ps1 -Action block -Path "C:\Apps\foo.exe"
#   .\netgate.ps1 -Action unblock -Path "C:\Apps\foo.exe"
#   .\netgate.ps1 -Action scan -Directory "C:\Apps" -Recurse
#   .\netgate.ps1 -Action export -File .\rules.json
#   .\netgate.ps1 -Action import -File .\rules.json
#   .\netgate.ps1 -Action reset
# Requires administrator for write actions; self-elevates when needed.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'list', 'discover', 'block', 'unblock', 'enable', 'disable', 'scan', 'export', 'import', 'reset')]
    [string]$Action,
    [string]$Path,
    [string]$Directory,
    [switch]$Recurse,
    [string]$File
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'netgate-lib.ps1')

$writeActions = @('block', 'unblock', 'enable', 'disable', 'import', 'reset')

function Out-Json($obj) {
    # -InputObject (not pipeline) preserves empty arrays as [] in PS 5.1
    ConvertTo-Json -InputObject $obj -Depth 8 -Compress
}

# Self-elevate for write actions when not admin
if ($writeActions -contains $Action -and -not (Test-NGAdmin)) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action"
    if ($Path)      { $args += " -Path `"$Path`"" }
    if ($Directory) { $args += " -Directory `"$Directory`"" }
    if ($Recurse)   { $args += ' -Recurse' }
    if ($File)      { $args += " -File `"$File`"" }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args -Verb RunAs
    Write-Output '{"elevated":true}'
    exit 0
}

try {
    switch ($Action) {
        'status' {
            Out-Json (Get-NGStatus)
        }
        'list' {
            Out-Json (Get-NGBlockedList)
        }
        'discover' {
            $apps = @(Get-NGDiscover)
            $arr = if ($apps.Count -eq 0) { ,@() } else { $apps }
            Out-Json ([pscustomobject]@{ count = $apps.Count; apps = $arr })
        }
        'block' {
            if (-not $Path) { throw 'MISSING_PATH' }
            $r = Add-NGBlock -Path $Path
            Out-Json ([pscustomobject]@{ ok = ($r.Outbound -and $r.Inbound); path = $r.Path; hash = $r.Hash; outbound = $r.Outbound; inbound = $r.Inbound; errors = $r.Errors })
        }
        'unblock' {
            if (-not $Path) { throw 'MISSING_PATH' }
            $n = Remove-NGBlock -Path $Path
            Out-Json ([pscustomobject]@{ ok = $true; removed = $n })
        }
        'enable' {
            if (-not $Path) { throw 'MISSING_PATH' }
            $n = Set-NGBlockState -Path $Path -Enabled $true
            Out-Json ([pscustomobject]@{ ok = $true; affected = $n })
        }
        'disable' {
            if (-not $Path) { throw 'MISSING_PATH' }
            $n = Set-NGBlockState -Path $Path -Enabled $false
            Out-Json ([pscustomobject]@{ ok = $true; affected = $n })
        }
        'scan' {
            if (-not $Directory) { throw 'MISSING_DIRECTORY' }
            $list = @(Get-NGScan -Directory $Directory -Recurse:$Recurse)
            $arr = if ($list.Count -eq 0) { ,@() } else { $list }
            Out-Json ([pscustomobject]@{ count = $list.Count; paths = $arr })
        }
        'export' {
            if (-not $File) { throw 'MISSING_FILE' }
            $n = Export-NGRules -Path $File
            Out-Json ([pscustomobject]@{ ok = $true; exported = $n; file = $File })
        }
        'import' {
            if (-not $File) { throw 'MISSING_FILE' }
            $r = Import-NGRules -Path $File
            Out-Json ([pscustomobject]@{ ok = $true; added = $r.Added; skipped = $r.Skipped; errors = $r.Errors })
        }
        'reset' {
            $n = Reset-NGRules
            Out-Json ([pscustomobject]@{ ok = $true; removed = $n })
        }
    }
} catch {
    $msg = $_.Exception.Message
    Out-Json ([pscustomobject]@{ ok = $false; error = $msg })
    exit 1
}
