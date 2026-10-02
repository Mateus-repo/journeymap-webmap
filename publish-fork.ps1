# Publishes the fork to your GitHub account, once you have authenticated gh.
#
#   1. gh auth login          (one-time, opens a browser)
#   2. powershell -File publish-fork.ps1
#   3. powershell -File publish-fork.ps1 -OpenPr    (also opens a PR upstream)
#
# Creates a real GitHub fork of TeamJM/journeymap-webmap (so "Sync fork" and
# upstream PRs keep working), then pushes the patched branch.
#
# The upstream PR is opt-in on purpose: a fork is private to your account, but a
# pull request is a public request to another person, so it is not something to
# send unless you asked for it.

param(
    [switch]$OpenPr
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$UPSTREAM = 'TeamJM/journeymap-webmap'
$BRANCH   = 'custom/chunk-grid-toggle'

function Find-Gh {
    $c = Get-Command gh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\GitHub CLI\gh.exe",
                     "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw 'gh not found. Install: winget install --id GitHub.cli'
}

$gh = Find-Gh

# git writes ordinary progress ("Everything up-to-date", "remote:") to stderr, and with
# $ErrorActionPreference = 'Stop' Windows PowerShell turns that into a terminating error.
# Run every git call with the preference relaxed and judge success by the exit code.
function Invoke-Git {
    param([string[]]$GitArgs, [switch]$Quiet)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
        if (-not $Quiet) { $out | ForEach-Object { Write-Host $_ } }
        return $code
    }
    finally { $ErrorActionPreference = $prev }
}

# --- auth ---------------------------------------------------------------------
$authed = $false
try { & $gh auth status 2>&1 | Out-Null; $authed = $true } catch { $authed = $false }

if (-not $authed) {
    Write-Host 'Not authenticated. Starting gh login (it will open a browser)...' -ForegroundColor Yellow
    & $gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw 'gh auth login failed' }
}

$login = (& $gh api user --jq .login).Trim()
Write-Host "authenticated as: $login"

# --- fork ---------------------------------------------------------------------
$forkName = 'journeymap-webmap'
$forkFull = "$login/$forkName"

$exists = $false
try { & $gh api "repos/$forkFull" 2>&1 | Out-Null; $exists = ($LASTEXITCODE -eq 0) } catch { }

if ($exists) {
    Write-Host "fork already exists: $forkFull"
}
else {
    # Use the REST API rather than `gh repo fork`: with a repository argument gh
    # rejects --remote, and the flag semantics have moved between versions.
    Write-Host "creating fork of $UPSTREAM ..."
    & $gh api -X POST "repos/$UPSTREAM/forks" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fork creation failed' }

    # the API is eventually consistent, so wait for the fork to show up
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        & $gh api "repos/$forkFull" | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "fork $forkFull did not appear" }

    $parent = (& $gh api "repos/$forkFull" --jq .parent.full_name)
    if (-not $parent) { throw "fork $forkFull has no upstream parent - it is not a real fork" }
    Write-Host "created $forkFull (parent: $parent)"
}

# --- remotes ------------------------------------------------------------------
Push-Location $root
try {
    $remotes = git remote
    if ($remotes -match '^fork$') {
        Invoke-Git @('remote', 'set-url', 'fork', "https://github.com/$forkFull.git") | Out-Null
        Write-Host 'remote "fork" updated'
    }
    else {
        Invoke-Git @('remote', 'add', 'fork', "https://github.com/$forkFull.git") | Out-Null
        Write-Host 'remote "fork" added'
    }

    $code = Invoke-Git @('push', '-u', 'fork', $BRANCH)
    if ($code -ne 0) { throw 'push failed' }

    # Keep the rest of the upstream branches so the fork stays a usable fork rather
    # than a one-branch copy. Already there when the fork was created, so this is
    # usually just "Everything up-to-date".
    Invoke-Git @('push', 'fork', 'refs/remotes/origin/26.3:refs/heads/26.3') -Quiet | Out-Null

    Write-Host ''
    Write-Host "fork: https://github.com/$forkFull" -ForegroundColor Green
    Write-Host "branch: $BRANCH" -ForegroundColor Green

    if ($OpenPr) {
        Write-Host ''
        Write-Host '=== opening PR upstream ===' -ForegroundColor Yellow
        & $gh pr create --repo $forkFull --base 26.3 --head $BRANCH `
            --title 'Chunk grid toggle, settings persistence, zoom buttons' `
            --body-file 'FORK-NOTES.md'
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'PR creation skipped (you may already have one open).'
        }
    }
    else {
        Write-Host ''
        Write-Host 'No PR opened. Re-run with -OpenPr if you want one upstream.' -ForegroundColor DarkGray
    }
}
finally { Pop-Location }