# NetGate core library
# Generic per-application network control via Windows Firewall.
# This tool contains NO application-specific lists. The user chooses every path.
# Compatible with Windows PowerShell 5.1 (ASCII only, no ?? / ?. / ternary).

$script:NG_PREFIX = 'NG'
$script:NG_DESC_TAG = 'NetGate'
$script:NG_VERSION = '1.0.0'

function Test-NGAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NGHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $norm = $Path.Trim().ToLowerInvariant()
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
        $hash = [System.BitConverter]::ToString($md5.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        return $hash.Substring(0, 12)
    } finally {
        $md5.Dispose()
    }
}

function Get-NGRules {
    return @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "$($script:NG_PREFIX)-*" -or $_.DisplayName -like "$($script:NG_DESC_TAG) *"
    })
}

# Return an array of PSCustomObject: Path, Hash, Outbound, Inbound, Enabled
function Get-NGBlockedList {
    $rules = @(Get-NGRules)
    $map = @{}
    foreach ($r in $rules) {
        $hash = $null
        if ($r.Name -match "^$($script:NG_PREFIX)-([a-f0-9]{12})-(O|I)$") {
            $hash = $Matches[1]
        }
        if (-not $hash) { continue }
        $path = ''
        if ($r.Description -and $r.Description.StartsWith("$($script:NG_DESC_TAG)|")) {
            $path = $r.Description.Substring($script:NG_DESC_TAG.Length + 1)
        }
        if (-not $map.ContainsKey($hash)) {
            $map[$hash] = [pscustomobject]@{
                Hash     = $hash
                Path     = $path
                Outbound = $false
                Inbound  = $false
                Enabled  = $true
            }
        }
        $e = $map[$hash]
        if ($r.Direction -eq 'Outbound') { $e.Outbound = $true } else { $e.Inbound = $true }
        if ($r.Enabled -ne $true) { $e.Enabled = $false }
    }
    if ($map.Values.Count -eq 0) { return @() }
    return @($map.Values | Sort-Object -Property Path)
}

function Test-NGPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.exe') { return $false }
    return $true
}

function Add-NGBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$NoElevateCheck
    )
    if (-not $NoElevateCheck -and -not (Test-NGAdmin)) {
        throw 'ADMIN_REQUIRED'
    }
    if (-not (Test-NGPath -Path $Path)) {
        throw "INVALID_PATH: $Path"
    }
    $full = (Get-Item -LiteralPath $Path).FullName
    $hash = Get-NGHash -Path $full
    $desc = "$($script:NG_DESC_TAG)|$full"
    $okOut = $false; $okIn = $false; $errs = @()

    # Remove any existing rules for this same path first (idempotent)
    Remove-NGBlock -Path $full -NoElevateCheck | Out-Null

    try {
        New-NetFirewallRule -Name "$($script:NG_PREFIX)-$hash-O" -DisplayName "NetGate Block Out $hash" `
            -Description $desc -Direction Outbound -Action Block -Program $full `
            -Profile Any -Enabled True -ErrorAction Stop | Out-Null
        $okOut = $true
    } catch { $errs += "out: $($_.Exception.Message)" }

    try {
        New-NetFirewallRule -Name "$($script:NG_PREFIX)-$hash-I" -DisplayName "NetGate Block In $hash" `
            -Description $desc -Direction Inbound -Action Block -Program $full `
            -Profile Any -Enabled True -ErrorAction Stop | Out-Null
        $okIn = $true
    } catch { $errs += "in: $($_.Exception.Message)" }

    return [pscustomobject]@{
        Path     = $full
        Hash     = $hash
        Outbound = $okOut
        Inbound  = $okIn
        Errors   = $errs
    }
}

function Remove-NGBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$NoElevateCheck
    )
    if (-not $NoElevateCheck -and -not (Test-NGAdmin)) {
        throw 'ADMIN_REQUIRED'
    }
    $full = $Path
    if (Test-NGPath -Path $Path) {
        $full = (Get-Item -LiteralPath $Path).FullName
    }
    $hash = Get-NGHash -Path $full
    $targets = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq "$($script:NG_PREFIX)-$hash-O" -or $_.Name -eq "$($script:NG_PREFIX)-$hash-I"
    })
    foreach ($t in $targets) {
        Remove-NetFirewallRule -Name $t.Name -ErrorAction SilentlyContinue
    }
    return $targets.Count
}

function Set-NGBlockState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    if (-not (Test-NGAdmin)) { throw 'ADMIN_REQUIRED' }
    $hash = Get-NGHash -Path $Path
    $targets = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq "$($script:NG_PREFIX)-$hash-O" -or $_.Name -eq "$($script:NG_PREFIX)-$hash-I"
    })
    foreach ($t in $targets) {
        if ($Enabled) {
            Enable-NetFirewallRule -Name $t.Name -ErrorAction SilentlyContinue
        } else {
            Disable-NetFirewallRule -Name $t.Name -ErrorAction SilentlyContinue
        }
    }
    return $targets.Count
}

function Get-NGScan {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [switch]$Recurse,
        [int]$Limit = 2000
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "INVALID_DIRECTORY: $Directory"
    }
    if ($Recurse) {
        $items = Get-ChildItem -LiteralPath $Directory -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue
    } else {
        $items = Get-ChildItem -LiteralPath $Directory -Filter '*.exe' -File -ErrorAction SilentlyContinue
    }
    $list = @($items | Select-Object -First $Limit | ForEach-Object { $_.FullName } | Sort-Object)
    return $list
}

function Export-NGRules {
    param([Parameter(Mandatory = $true)][string]$Path)
    $list = @(Get-NGBlockedList)
    $obj = [ordered]@{
        tool     = 'NetGate'
        version  = $script:NG_VERSION
        exported = (Get-Date).ToString('o')
        rules    = @($list | ForEach-Object {
            [ordered]@{ path = $_.Path; enabled = [bool]$_.Enabled }
        })
    }
    $json = $obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $list.Count
}

function Import-NGRules {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$NoElevateCheck
    )
    if (-not $NoElevateCheck -and -not (Test-NGAdmin)) { throw 'ADMIN_REQUIRED' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "INVALID_PATH: $Path" }
    $raw = [System.IO.File]::ReadAllText($Path)
    $data = $raw | ConvertFrom-Json
    $added = 0; $skipped = 0; $errors = @()
    foreach ($r in @($data.rules)) {
        $p = [string]$r.path
        if (-not (Test-NGPath -Path $p)) { $skipped++; continue }
        try {
            Add-NGBlock -Path $p -NoElevateCheck | Out-Null
            if ($r.enabled -eq $false) {
                Set-NGBlockState -Path $p -Enabled $false | Out-Null
            }
            $added++
        } catch { $errors += "$p : $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Added = $added; Skipped = $skipped; Errors = $errors }
}

function Reset-NGRules {
    if (-not (Test-NGAdmin)) { throw 'ADMIN_REQUIRED' }
    $rules = @(Get-NGRules)
    foreach ($r in $rules) {
        Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
    }
    return $rules.Count
}

function Get-NGStatus {
    $blocked = @(Get-NGBlockedList)
    return [pscustomobject]@{
        Version      = $script:NG_VERSION
        IsAdmin      = [bool](Test-NGAdmin)
        BlockedCount = $blocked.Count
        RuleCount    = @(Get-NGRules).Count
    }
}

# Discover programs without requiring the user to type a full path.
# Sources: running processes (with Path), uninstall registry entries,
# and top-level exes in Program Files folders.
function Get-NGDiscover {
    param([int]$Limit = 400)

    $map = @{}
    # Exe names that are helpers, not the app the user actually wants to control.
    $junkPattern = '(?i)(uninstall|unins|setup|set-up|install|remove|repair|update|updater|crwindowsclientservice|crlogtransport|crash|coresync|ipcbroker|notification|licensing|helper|service|advert|tqcache)'

    # 1. Running processes that expose an executable path
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path }
    foreach ($p in $procs) {
        $fp = $p.Path
        if ([string]::IsNullOrWhiteSpace([string]$fp)) { continue }
        if (-not $map.ContainsKey($fp)) {
            $map[$fp] = [pscustomobject]@{
                Path   = $fp
                Name   = [System.IO.Path]::GetFileNameWithoutExtension($fp)
                Source = 'running'
            }
        }
    }

    # 2. Uninstall registry entries (DisplayIcon gives the exe)
    $keys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -and ($_.DisplayIcon -or $_.InstallLocation)
    }
    foreach ($a in $apps) {
        $exe = ''
        $iconCandidate = ''
        if ($a.DisplayIcon) {
            $candidate = ($a.DisplayIcon -split ',')[0].Trim('"')
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                (Test-Path -LiteralPath $candidate -PathType Leaf) -and
                [System.IO.Path]::GetExtension($candidate).ToLowerInvariant() -eq '.exe') {
                $iconCandidate = $candidate
            }
        }
        # Prefer a non-helper exe from the icon's directory or InstallLocation.
        $searchDir = ''
        if ($iconCandidate -and $iconCandidate -notmatch $junkPattern) {
            $exe = $iconCandidate
        } else {
            if ($iconCandidate) { $searchDir = Split-Path -Parent $iconCandidate }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$a.InstallLocation) -and
                    (Test-Path -LiteralPath $a.InstallLocation -PathType Container)) {
                $searchDir = $a.InstallLocation
            }
            if ($searchDir) {
                $cands = @(Get-ChildItem -LiteralPath $searchDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
                $good = @($cands | Where-Object { $_.Name -notmatch $junkPattern } | Sort-Object Length -Descending)
                if ($good.Count -gt 0) { $exe = $good[0].FullName }
                elseif ($iconCandidate) { $exe = $iconCandidate }
            }
        }
        if (-not $exe) { continue }
        if (-not $map.ContainsKey($exe)) {
            $map[$exe] = [pscustomobject]@{
                Path   = $exe
                Name   = [string]$a.DisplayName
                Source = 'installed'
            }
        }
    }

    # 3. Top-level exes in Program Files (non-recursive, fast)
    $dirs = @(
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}"
    )
    foreach ($d in $dirs) {
        if ([string]::IsNullOrWhiteSpace([string]$d)) { continue }
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $subs = Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue
        foreach ($s in $subs) {
            $exes = @(Get-ChildItem -LiteralPath $s.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch $junkPattern } | Sort-Object Length -Descending | Select-Object -First 1)
            foreach ($e in $exes) {
                if (-not $map.ContainsKey($e.FullName)) {
                    $map[$e.FullName] = [pscustomobject]@{
                        Path   = $e.FullName
                        Name   = [System.IO.Path]::GetFileNameWithoutExtension($e.FullName)
                        Source = 'programfiles'
                    }
                }
            }
        }
    }

    $list = @($map.Values | Sort-Object -Property Name | Select-Object -First $Limit)
    return $list
}
