<#
.SYNOPSIS
    Install paper-reading skill into any workspace.

.DESCRIPTION
    Clones or updates the paper-reading skill into .agents/skills/paper-reading/
    and sets up the api_key directory.

.PARAMETER WorkspaceRoot
    Target workspace root directory. Defaults to current directory.

.PARAMETER RepoUrl
    Git repository URL. Override for forks or private repos.

.PARAMETER Branch
    Git branch to clone. Defaults to main.

.EXAMPLE
    # Install into current workspace
    .\install.ps1

    # Install into a specific workspace
    .\install.ps1 -WorkspaceRoot "E:\my-project"

    # Remote one-liner (after publishing)
    # irm https://raw.githubusercontent.com/<user>/paper-reading-skill/main/install.ps1 | iex
#>

param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$RepoUrl = "",
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

# ── Paths ──────────────────────────────────────────────
$skillDir  = Join-Path $WorkspaceRoot ".agents\skills\paper-reading"
$keyDir    = Join-Path $skillDir "api_key"
$keyFile   = Join-Path $keyDir "key.txt"

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Paper-Reading Skill Installer          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  Target    : $skillDir"
Write-Host ""

# ── Step 1: Clone or Update ───────────────────────────
if (Test-Path (Join-Path $skillDir ".git")) {
    Write-Host "[1/3] Skill repo exists, pulling latest..." -ForegroundColor Yellow
    git -C $skillDir pull origin $Branch --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠️  Pull failed. You may have local changes. Try: git -C `"$skillDir`" status" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✅ Updated to latest version." -ForegroundColor Green
}
elseif (Test-Path (Join-Path $skillDir "SKILL.md")) {
    Write-Host "[1/3] Skill exists (non-git). Skipping clone." -ForegroundColor Yellow
    Write-Host "  ℹ️  To enable git updates, remove and re-install:" -ForegroundColor Gray
    Write-Host "      Remove-Item -Recurse `"$skillDir`"; .\install.ps1" -ForegroundColor Gray
}
else {
    if ([string]::IsNullOrEmpty($RepoUrl)) {
        Write-Host "[1/3] ERROR: No repo URL provided and skill not found." -ForegroundColor Red
        Write-Host "  Usage: .\install.ps1 -RepoUrl `"https://github.com/<user>/paper-reading-skill.git`"" -ForegroundColor Gray
        exit 1
    }
    Write-Host "[1/3] Cloning skill repo..." -ForegroundColor Yellow
    git clone --branch $Branch --single-branch $RepoUrl $skillDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Clone failed. Check repo URL and network." -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✅ Cloned successfully." -ForegroundColor Green
}

# ── Step 2: Setup api_key ─────────────────────────────
Write-Host "[2/3] Checking API key..." -ForegroundColor Yellow

if (-not (Test-Path $keyDir)) {
    New-Item -Path $keyDir -ItemType Directory -Force | Out-Null
}

if ((-not (Test-Path $keyFile)) -or ((Get-Item $keyFile).Length -eq 0)) {
    # Check environment variable as fallback
    if ($env:MINERU_API_TOKEN) {
        Set-Content -Path $keyFile -Value $env:MINERU_API_TOKEN -NoNewline
        Write-Host "  ✅ API key set from `$env:MINERU_API_TOKEN." -ForegroundColor Green
    }
    else {
        New-Item -Path $keyFile -ItemType File -Force | Out-Null
        Write-Host "  ⚠️  API key not configured!" -ForegroundColor Red
        Write-Host "  →  Option A: Set env var MINERU_API_TOKEN and re-run" -ForegroundColor Gray
        Write-Host "  →  Option B: Paste your token into: $keyFile" -ForegroundColor Gray
    }
}
else {
    Write-Host "  ✅ API key already configured." -ForegroundColor Green
}

# ── Step 3: Verify ────────────────────────────────────
Write-Host "[3/3] Verifying installation..." -ForegroundColor Yellow

$checks = @(
    @{ Path = Join-Path $skillDir "SKILL.md";                         Name = "SKILL.md" },
    @{ Path = Join-Path $skillDir "scripts\mineru_convert.py";        Name = "mineru_convert.py" },
    @{ Path = Join-Path $skillDir "scripts\quality_check.py";         Name = "quality_check.py" },
    @{ Path = Join-Path $skillDir "templates\reading_guide_template.md"; Name = "reading_guide_template.md" },
    @{ Path = Join-Path $skillDir "templates\report_template.md";     Name = "report_template.md" }
)

$allGood = $true
foreach ($check in $checks) {
    if (Test-Path $check.Path) {
        Write-Host "  ✓ $($check.Name)" -ForegroundColor Green
    }
    else {
        Write-Host "  ✗ $($check.Name) MISSING" -ForegroundColor Red
        $allGood = $false
    }
}

Write-Host ""
if ($allGood) {
    Write-Host "══════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  ✅ paper-reading skill installed!" -ForegroundColor Green
    Write-Host "  Use: /paper-reading <pdf_path>" -ForegroundColor Green
    Write-Host "══════════════════════════════════════════" -ForegroundColor Green
}
else {
    Write-Host "══════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  ⚠️  Installation incomplete. Check errors above." -ForegroundColor Red
    Write-Host "══════════════════════════════════════════" -ForegroundColor Red
}
Write-Host ""
