# NetGate local web server
# Binds to 127.0.0.1 only - not reachable from the network.
# Minimal HTTP over TcpListener so no URL ACL / admin reservation is needed.
# Must be started elevated for write actions (START.bat handles this).

param(
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'netgate-lib.ps1')

$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "NetGate listening on http://127.0.0.1:$Port"
Write-Host "Press Ctrl+C to stop."

function Read-Request($stream) {
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
    $line = $reader.ReadLine()
    if (-not $line) { return $null }
    $parts = $line.Split(' ')
    $method = $parts[0]
    $url = $parts[1]
    $headers = @{}
    while ($true) {
        $h = $reader.ReadLine()
        if ($null -eq $h -or $h -eq '') { break }
        $idx = $h.IndexOf(':')
        if ($idx -gt 0) {
            $key = $h.Substring(0, $idx).Trim().ToLowerInvariant()
            $val = $h.Substring($idx + 1).Trim()
            $headers[$key] = $val
        }
    }
    $body = ''
    if ($headers.ContainsKey('content-length')) {
        $len = [int]$headers['content-length']
        if ($len -gt 0 -and $len -lt 20000000) {
            $buf = New-Object char[] $len
            $read = $reader.Read($buf, 0, $len)
            if ($read -gt 0) { $body = New-Object string($buf, 0, $read) }
        }
    }
    return [pscustomobject]@{ Method = $method; Url = $url; Body = $body }
}

function Write-Response($stream, [int]$code, [string]$contentType, [string]$body) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $reason = switch ($code) { 200 { 'OK' } 400 { 'Bad Request' } 404 { 'Not Found' } 500 { 'Internal Server Error' } default { 'OK' } }
    $head = "HTTP/1.1 $code $reason`r`n" +
            "Content-Type: $contentType`r`n" +
            "Content-Length: $($bytes.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($headBytes, 0, $headBytes.Length)
    if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
    $stream.Flush()
}

function Json($obj) {
    # -InputObject preserves empty arrays as [] in PS 5.1
    return (ConvertTo-Json -InputObject $obj -Depth 10 -Compress)
}

# ---- Optional telemetry (same storage as ops/telemetry.ps1) ----
$script:OptCfgFile = Join-Path $env:LOCALAPPDATA 'NetGate\telemetry.json'
$script:OptQueueFile = Join-Path $env:LOCALAPPDATA 'NetGate\telemetry-queue.jsonl'
$script:OptFunnelFile = Join-Path $env:LOCALAPPDATA 'NetGate\funnel.json'
$script:OptVersion = '1.0.0'

function Get-FunnelState {
    if (Test-Path -LiteralPath $script:OptFunnelFile) {
        try { return ([System.IO.File]::ReadAllText($script:OptFunnelFile) | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ firstOpen = ''; firstBlock = ''; lastOpen = ''; blockMonth = ''; blockCount = 0 }
}
function Set-FunnelState($s) {
    $dir = Split-Path -Parent $script:OptFunnelFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $j = ConvertTo-Json -InputObject $s -Depth 4 -Compress
    [System.IO.File]::WriteAllText($script:OptFunnelFile, $j, (New-Object System.Text.UTF8Encoding($false)))
}
# Called on every status poll. Records first_open and 7-day return (local only).
function Track-OpenFunnel {
    $cfg = Get-OptCfg
    if (-not $cfg.enabled) { return }
    $f = Get-FunnelState
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (-not $f.firstOpen) {
        $f.firstOpen = $today
        Record-OptEvent 'first_open' $true
    }
    if ($f.lastOpen -and $f.lastOpen -ne $today) {
        $days = ((Get-Date) - [datetime]::ParseExact($f.lastOpen, 'yyyy-MM-dd', $null)).Days
        if ($days -ge 7) { Record-OptEvent 'return_7d' $true }
    }
    $f.lastOpen = $today
    Set-FunnelState $f
}

function Get-OptCfg {
    if (Test-Path -LiteralPath $script:OptCfgFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:OptCfgFile)
            return ($raw | ConvertFrom-Json)
        } catch {}
    }
    return [pscustomobject]@{ enabled = $false; anonId = ''; endpoint = '' }
}

function Set-OptCfg($cfg) {
    $dir = Split-Path -Parent $script:OptCfgFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $j = ConvertTo-Json -InputObject $cfg -Depth 4 -Compress
    [System.IO.File]::WriteAllText($script:OptCfgFile, $j, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-OsVersion {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { return "$($os.MajorVersion).$($os.MinorVersion).$($os.BuildNumber)" }
    return 'unknown'
}

function Record-OptEvent([string]$name, [bool]$success) {
    $cfg = Get-OptCfg
    if (-not $cfg.enabled) { return }
    if (-not $cfg.anonId) {
        $cfg.anonId = [guid]::NewGuid().ToString('N')
        Set-OptCfg $cfg
    }
    $evt = [pscustomobject]@{
        v = $script:OptVersion
        id = $cfg.anonId
        e = $name
        t = [int][double]::Parse((Get-Date -UFormat %s))
        os = Get-OsVersion
        r = if ($success) { 1 } else { 0 }
    }
    $line = ConvertTo-Json -InputObject $evt -Depth 4 -Compress
    $dir = Split-Path -Parent $script:OptQueueFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::AppendAllText($script:OptQueueFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Flush-OptEvents {
    $cfg = Get-OptCfg
    if (-not $cfg.enabled -or -not $cfg.endpoint) { return }
    if (-not (Test-Path -LiteralPath $script:OptQueueFile)) { return }
    $lines = @(Get-Content -LiteralPath $script:OptQueueFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return }
    $batch = '[' + ($lines -join ',') + ']'
    try {
        Invoke-RestMethod -Uri $cfg.endpoint -Method Post -Body $batch `
            -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $script:OptQueueFile -Force -ErrorAction SilentlyContinue
    } catch {
        # keep queue for retry
    }
}

function Get-BodyParam($req, [string]$key) {
    if (-not $req.Body) { return $null }
    try {
        $o = $req.Body | ConvertFrom-Json
        $p = $o.$key
        if ($null -eq $p) { return $null }
        return [string]$p
    } catch { return $null }
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $req = Read-Request $stream
            if (-not $req) { continue }
            $path = $req.Url.Split('?')[0]
            $method = $req.Method.ToUpperInvariant()

            if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                $htmlPath = Join-Path $here 'web\index.html'
                if (Test-Path -LiteralPath $htmlPath) {
                    $html = [System.IO.File]::ReadAllText($htmlPath)
                    Write-Response $stream 200 'text/html; charset=utf-8' $html
                } else {
                    Write-Response $stream 404 'text/plain; charset=utf-8' 'index.html missing'
                }
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/status') {
                Track-OpenFunnel
                $st = Get-NGStatus
                $f = Get-FunnelState
                $stLocal = [pscustomobject]@{
                    Version = $st.Version
                    IsAdmin = $st.IsAdmin
                    BlockedCount = $st.BlockedCount
                    RuleCount = $st.RuleCount
                    MonthBlockCount = [int]$f.blockCount
                }
                Write-Response $stream 200 'application/json; charset=utf-8' (Json $stLocal)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/list') {
                $l = @(Get-NGBlockedList)
                $payload = if ($l.Count -eq 0) { '[]' } else { Json $l }
                Write-Response $stream 200 'application/json; charset=utf-8' $payload
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/telemetry/status') {
                $cfg = Get-OptCfg
                $q = 0
                if (Test-Path -LiteralPath $script:OptQueueFile) {
                    $q = @(Get-Content -LiteralPath $script:OptQueueFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
                }
                Write-Response $stream 200 'application/json; charset=utf-8' (Json ([pscustomobject]@{
                    enabled = [bool]$cfg.enabled
                    endpointSet = [bool]$cfg.endpoint
                    queued = $q
                }))
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/telemetry/optin') {
                $ep = Get-BodyParam $req 'endpoint'
                if (-not $ep) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'ENDPOINT_REQUIRED' }); continue }
                $cfg = Get-OptCfg
                $cfg.enabled = $true
                $cfg.endpoint = $ep
                if (-not $cfg.anonId) { $cfg.anonId = [guid]::NewGuid().ToString('N') }
                Set-OptCfg $cfg
                Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true })
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/telemetry/optout') {
                $cfg = Get-OptCfg
                $cfg.enabled = $false
                $cfg.anonId = ''
                $cfg.endpoint = ''
        Set-OptCfg $cfg
        if (Test-Path -LiteralPath $script:OptQueueFile) {
            [System.IO.File]::WriteAllText($script:OptQueueFile, '', (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true })
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/ai-suggest') {
                try {
                    $sug = @(Get-NGAISuggestions)
                    $arr = if ($sug.Count -eq 0) { ,@() } else { $sug }
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json ([pscustomobject]@{ count = $sug.Count; apps = $arr }))
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/ai-parse') {
                $text = Get-BodyParam $req 'text'
                if (-not $text) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_TEXT' }); continue }
                try {
                    $m = @(Get-NGNLParse -Text $text)
                    $arr = if ($m.Count -eq 0) { ,@() } else { $m }
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json ([pscustomobject]@{ ok = $true; count = $m.Count; matches = $arr }))
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/suggestions') {
                try {
                    $managed = @(Get-NGBlockedList | ForEach-Object { $_.Path.ToLowerInvariant() })
                    $all = @(Get-NGDiscover)
                    $running = @($all | Where-Object {
                        $_.Source -eq 'running' -and $managed -notcontains $_.Path.ToLowerInvariant()
                    } | Select-Object -First 8)
                    $arr = if ($running.Count -eq 0) { ,@() } else { $running }
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json ([pscustomobject]@{ count = $running.Count; apps = $arr }))
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/discover') {
                try {
                    $apps = @(Get-NGDiscover)
                    $payload = if ($apps.Count -eq 0) { '[]' } else { Json $apps }
                    Write-Response $stream 200 'application/json; charset=utf-8' $payload
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/block') {
                $p = Get-BodyParam $req 'path'
                if (-not $p) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_PATH' }); continue }
                try {
                    $r = Add-NGBlock -Path $p
                    $good = ($r.Outbound -and $r.Inbound)
                    Record-OptEvent 'block' $good
                    if ($good) {
                        $f = Get-FunnelState
                        $thisMonth = (Get-Date).ToString('yyyy-MM')
                        if ($f.blockMonth -ne $thisMonth) { $f.blockMonth = $thisMonth; $f.blockCount = 0 }
                        $f.blockCount = [int]$f.blockCount + 1
                        if (-not $f.firstBlock) {
                            $f.firstBlock = (Get-Date).ToString('yyyy-MM-dd')
                            Record-OptEvent 'first_block' $true
                        }
                        Set-FunnelState $f
                    }
                    Flush-OptEvents
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $good; path = $r.Path; outbound = $r.Outbound; inbound = $r.Inbound; errors = $r.Errors })
                } catch {
                    Record-OptEvent 'block' $false
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/unblock') {
                $p = Get-BodyParam $req 'path'
                if (-not $p) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_PATH' }); continue }
                try {
                    $n = Remove-NGBlock -Path $p
                    Record-OptEvent 'unblock' $true
                    Flush-OptEvents
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true; removed = $n })
                } catch {
                    Record-OptEvent 'unblock' $false
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and ($path -eq '/api/enable' -or $path -eq '/api/disable')) {
                $p = Get-BodyParam $req 'path'
                if (-not $p) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_PATH' }); continue }
                try {
                    $en = ($path -eq '/api/enable')
                    $n = Set-NGBlockState -Path $p -Enabled $en
                    $ev = if ($en) { 'enable' } else { 'disable' }
                    Record-OptEvent $ev $true
                    Flush-OptEvents
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true; affected = $n })
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/scan') {
                $d = Get-BodyParam $req 'directory'
                if (-not $d) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_DIRECTORY' }); continue }
                try {
                    $rec = $false
                    if ($req.Body) { $o = $req.Body | ConvertFrom-Json; $rec = [bool]$o.recurse }
                    $list = @(Get-NGScan -Directory $d -Recurse:$rec)
                    Record-OptEvent 'scan' $true
                    Flush-OptEvents
                    $arr = if ($list.Count -eq 0) { ,@() } else { $list }
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true; count = $list.Count; paths = $arr })
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/export') {
                try {
                    $list = @(Get-NGBlockedList)
                    $obj = [ordered]@{
                        tool = 'NetGate'; version = $script:NG_VERSION
                        exported = (Get-Date).ToString('o')
                        rules = @($list | ForEach-Object { [ordered]@{ path = $_.Path; enabled = [bool]$_.Enabled } })
                    }
                    Record-OptEvent 'export' $true
                    Flush-OptEvents
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json $obj)
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/import') {
                if (-not $req.Body) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'EMPTY_BODY' }); continue }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("netgate-import-$([guid]::NewGuid().ToString('N')).json")
                try {
                    [System.IO.File]::WriteAllText($tmp, $req.Body, (New-Object System.Text.UTF8Encoding($false)))
                    $r = Import-NGRules -Path $tmp
                    Record-OptEvent 'import' $true
                    Flush-OptEvents
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true; added = $r.Added; skipped = $r.Skipped; errors = $r.Errors })
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                } finally {
                    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/reset') {
                try {
                    $n = Reset-NGRules
                    Record-OptEvent 'reset' $true
                    Flush-OptEvents
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true; removed = $n })
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            Write-Response $stream 404 'application/json; charset=utf-8' (Json @{ error = 'NOT_FOUND'; path = $path })
        } catch {
            try { Write-Response $stream 500 'application/json' (Json @{ error = $_.Exception.Message }) } catch {}
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
