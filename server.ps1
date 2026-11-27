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
                Write-Response $stream 200 'application/json; charset=utf-8' (Json (Get-NGStatus))
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/list') {
                $l = @(Get-NGBlockedList)
                $payload = if ($l.Count -eq 0) { '[]' } else { Json $l }
                Write-Response $stream 200 'application/json; charset=utf-8' $payload
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/block') {
                $p = Get-BodyParam $req 'path'
                if (-not $p) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_PATH' }); continue }
                try {
                    $r = Add-NGBlock -Path $p
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = ($r.Outbound -and $r.Inbound); path = $r.Path; outbound = $r.Outbound; inbound = $r.Inbound; errors = $r.Errors })
                } catch {
                    Write-Response $stream 500 'application/json; charset=utf-8' (Json @{ ok = $false; error = $_.Exception.Message })
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/unblock') {
                $p = Get-BodyParam $req 'path'
                if (-not $p) { Write-Response $stream 400 'application/json' (Json @{ ok = $false; error = 'MISSING_PATH' }); continue }
                try {
                    $n = Remove-NGBlock -Path $p
                    Write-Response $stream 200 'application/json; charset=utf-8' (Json @{ ok = $true; removed = $n })
                } catch {
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
