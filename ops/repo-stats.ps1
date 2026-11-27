# NetGate repository analytics
# Pulls GitHub-native metrics via gh CLI and writes a Markdown report.
# Usage:
#   .\repo-stats.ps1
#   .\repo-stats.ps1 -Repo "owner/name" -OutFile .\report.md
#   .\repo-stats.ps1 -Json
# Requires: gh CLI authenticated (gh auth login).
# NOTE: ASCII only - Windows PowerShell 5.1 misreads UTF-8 no-BOM CJK text.

param(
    [string]$Repo = 'jiucheng-lin/netgate',
    [string]$OutFile = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# Locate gh CLI (may not be on PATH in restricted shells)
$script:GH = $null
$cmd = Get-Command gh -ErrorAction SilentlyContinue
if ($cmd) {
    $script:GH = $cmd.Source
} else {
    foreach ($candidate in @(
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe",
        "C:\Program Files\GitHub CLI\gh.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) { $script:GH = $candidate; break }
    }
}
if (-not $script:GH) { throw 'gh CLI not found. Install from https://cli.github.com' }

function Invoke-Gh($endpoint) {
    $raw = & $script:GH api $endpoint 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $s = ($raw -join "`n").Trim()
    if (-not $s) { return $null }
    try { return ($s | ConvertFrom-Json) } catch { return $null }
}

function Num($v) { if ($null -eq $v) { return 0 } else { return [int]$v } }

$meta   = Invoke-Gh "repos/$Repo"
if ($null -eq $meta) { throw "Cannot read repo $Repo. Check name and gh auth." }
$views  = Invoke-Gh "repos/$Repo/traffic/views"
$clones = Invoke-Gh "repos/$Repo/traffic/clones"
$refs   = Invoke-Gh "repos/$Repo/traffic/popular/referrers"
$paths  = Invoke-Gh "repos/$Repo/traffic/popular/paths"
$rels   = Invoke-Gh "repos/$Repo/releases"
$issues = Invoke-Gh "repos/$Repo/issues?state=all&per_page=100"

$downloads = 0
foreach ($r in @($rels)) {
    foreach ($a in @($r.assets)) { $downloads += Num $a.download_count }
}

$openIssues = 0
$closedIssues = 0
foreach ($i in @($issues)) {
    if ($i.pull_request) { continue }
    if ($i.state -eq 'open') { $openIssues++ } else { $closedIssues++ }
}

$stat = [ordered]@{
    repo          = $Repo
    generated     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    stars         = Num $meta.stargazers_count
    forks         = Num $meta.forks_count
    watchers      = Num $meta.subscribers_count
    open_issues   = $openIssues
    closed_issues = $closedIssues
    releases      = @($rels).Count
    downloads     = $downloads
    views_14d     = Num $views.count
    views_unique  = Num $views.uniques
    clones_14d    = Num $clones.count
    clones_unique = Num $clones.uniques
}

if ($Json) {
    ConvertTo-Json -InputObject $stat -Depth 6
    exit 0
}

$lines = @()
$lines += '# NetGate Repository Analytics'
$lines += ''
$lines += "Repository: $Repo"
$lines += "Generated:  $($stat.generated)"
$lines += ''
$lines += '## Core Metrics'
$lines += ''
$lines += '| Metric | Value |'
$lines += '|---|---|'
$lines += "| Stars | $($stat.stars) |"
$lines += "| Forks | $($stat.forks) |"
$lines += "| Watchers | $($stat.watchers) |"
$lines += "| Open Issues | $($stat.open_issues) |"
$lines += "| Closed Issues | $($stat.closed_issues) |"
$lines += "| Releases | $($stat.releases) |"
$lines += "| Release Downloads | $($stat.downloads) |"
$lines += ''
$lines += '## Traffic (last 14 days)'
$lines += ''
$lines += '| Metric | Total | Unique |'
$lines += '|---|---|'
$lines += "| Page views | $($stat.views_14d) | $($stat.views_unique) |"
$lines += "| Clones | $($stat.clones_14d) | $($stat.clones_unique) |"
$lines += ''

if ($refs -and @($refs).Count -gt 0) {
    $lines += '## Top Referrers'
    $lines += ''
    $lines += '| Source | Views |'
    $lines += '|---|---|'
    foreach ($r in @($refs) | Select-Object -First 10) {
        $lines += "| $($r.referrer) | $(Num $r.count) |"
    }
    $lines += ''
}

if ($paths -and @($paths).Count -gt 0) {
    $lines += '## Top Paths'
    $lines += ''
    $lines += '| Path | Views |'
    $lines += '|---|---|'
    foreach ($p in @($paths) | Select-Object -First 10) {
        $lines += "| $($p.path) | $(Num $p.count) |"
    }
    $lines += ''
}

$lines += '---'
$lines += ''
$lines += 'GitHub traffic data is a rolling 14-day window, updated daily by GitHub.'
$lines += 'This report covers repository-level public metrics only; it does not include in-app feature usage.'

$text = $lines -join "`n"
if ($OutFile) {
    [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "Report written: $OutFile"
} else {
    Write-Output $text
}
