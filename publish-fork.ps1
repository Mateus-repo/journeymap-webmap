# Publishes the fork to your GitHub account, once you have authenticated gh.
#
#   1. gh auth login          (one-time, opens a browser)
#   2. powershell -File publish-fork.ps1
#
# Creates a real GitHub fork of TeamJM/journeymap-webmap (so "Sync fork" and
# upstream PRs keep working), then pushes the patched branch and opens a PR.

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
    Write-Host "creating fork of $UPSTREAM ..."
    & $gh repo fork $UPSTREAM --clone=false --remote=false
    if ($LASTEXITCODE -ne 0) { throw 'fork creation failed' }
    Write-Host "created $forkFull"
}

# --- remotes ------------------------------------------------------------------
Push-Location $root
try {
    $remotes = git remote
    if ($remotes -match '^fork$') {
        git remote set-url fork "https://github.com/$forkFull.git"
        Write-Host 'remote "fork" updated'
    }
    else {
        git remote add fork "https://github.com/$forkFull.git"
        Write-Host 'remote "fork" added'
    }

    git push -u fork $BRANCH
    if ($LASTEXITCODE -ne 0) { throw 'push failed' }

    # carry the full branch list too, so the fork is a real fork not a one-branch copy
    git push fork 'refs/remotes/origin/26.3:refs/heads/26.3' 2>&1 | Out-Null

    Write-Host ''
    Write-Host '=== PR ===' -ForegroundColor Green
    & $gh pr create --repo $forkFull --base 26.3 --head $BRANCH `
        --title 'Chunk grid toggle, settings persistence, zoom buttons' `
        --body-file 'FORK-NOTES.md'
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'PR creation skipped (you may already have one open).'
    }

    Write-Host ''
    Write-Host "done: https://github.com/$forkFull" -ForegroundColor Green
}
finally { Pop-Location }