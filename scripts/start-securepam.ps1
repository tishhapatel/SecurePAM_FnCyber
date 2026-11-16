<#
.SYNOPSIS
    SecurePAM environment startup script for Windows.
.DESCRIPTION
    Brings up the SecurePAM environment idempotently on Windows without side effects
    beyond starting services that are stopped.
.PARAMETER DryRun
    Show what would be started without executing.
.PARAMETER NoUnsealPrompt
    Never prompt to unseal OpenBao.
#>
param(
    [switch]$DryRun,
    [switch]$NoUnsealPrompt,
    [switch]$Help
)

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path
    exit 0
}

$ErrorActionPreference = "SilentlyContinue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Write-Info { param([string]$Msg) Write-Host "  .. $Msg" -ForegroundColor DarkGray }
function Write-Ok   { param([string]$Msg) Write-Host "  OK $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  !! $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "  XX $Msg" -ForegroundColor Red; exit 1 }
function Write-Step { param([string]$Msg) Write-Host "`n== $Msg" -ForegroundColor Cyan }

function Invoke-Action {
    param([string]$Desc, [scriptblock]$Action)
    if ($DryRun) {
        Write-Info "[dry-run] would: $Desc"
        return
    }
    Write-Info "$Desc"
    & $Action
}

Write-Step "Preflight"

# Check Node & Python
$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pyCmd) { Write-Fail "python is not found on PATH" }
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) { Write-Fail "node is not found on PATH" }
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npmCmd) { Write-Fail "npm is not found on PATH" }

Write-Ok "Python, Node.js, and npm are available"

# Check required folders
$requiredPaths = @(
    (Join-Path $RepoRoot "backend"),
    (Join-Path $RepoRoot "frontend"),
    (Join-Path $RepoRoot "policy-engine")
)

foreach ($p in $requiredPaths) {
    if (-not (Test-Path $p)) {
        Write-Fail "Required path not found: $p"
    }
}
Write-Ok "Repository workspace verified: $RepoRoot"

Write-Step "Checking Infrastructure Services"

# Docker Services
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $dockerVer = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($dockerVer) {
        Write-Ok "Docker daemon is running ($dockerVer)"
        $containers = @("securepam-keycloak-postgres", "securepam-keycloak", "guacamole-guac-postgres-1", "guacamole-guacd-1", "guacamole-guacamole-1", "browser-isolation-browser-isolation-1")
        foreach ($c in $containers) {
            $st = & docker inspect --format '{{.State.Status}}' $c 2>$null
            if ($st -and ($st -ne "running")) {
                Invoke-Action "Starting container $c" { & docker start $c }
            } elseif ($st -eq "running") {
                Write-Ok "Container $c is already running"
            }
        }
    } else {
        Write-Warn "Docker CLI is present but daemon is not running. If you use Docker Desktop, please start it."
    }
} else {
    Write-Info "Docker CLI not detected."
}

# Windows Native PostgreSQL
$pgService = Get-Service -Name "*postgres*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgService) {
    if ($pgService.Status -ne "Running") {
        Invoke-Action "Starting PostgreSQL Windows service: $($pgService.Name)" {
            Start-Service -Name $pgService.Name
        }
    } else {
        Write-Ok "PostgreSQL Windows service $($pgService.Name) is already running"
    }
}

# Windows Native Redis
$redisService = Get-Service -Name "*redis*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($redisService) {
    if ($redisService.Status -ne "Running") {
        Invoke-Action "Starting Redis Windows service: $($redisService.Name)" {
            Start-Service -Name $redisService.Name
        }
    } else {
        Write-Ok "Redis Windows service $($redisService.Name) is already running"
    }
}

Write-Step "Checking Applications"

# Check if Backend :8001 is running
$be8001Running = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:8001/health/ready" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $be8001Running = $true }
} catch {}

if ($be8001Running) {
    Write-Ok "Backend :8001 is already running and ready"
} else {
    Write-Info "Backend :8001 is not running. To start manually in a terminal:"
    Write-Host "     cd `"$RepoRoot\backend`"" -ForegroundColor DarkYellow
    Write-Host "     python -m uvicorn app.main:app --port 8001" -ForegroundColor DarkYellow
}

# Check if Frontend :3001 is running
$fe3001Running = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:3001/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $fe3001Running = $true }
} catch {}

if ($fe3001Running) {
    Write-Ok "Frontend :3001 is already running"
} else {
    Write-Info "Frontend :3001 is not running. To start manually in a terminal:"
    Write-Host "     cd `"$RepoRoot\frontend`"" -ForegroundColor DarkYellow
    Write-Host "     npm run dev -- --port 3001" -ForegroundColor DarkYellow
}

Write-Step "Status Summary"
& "$ScriptDir\status-securepam.ps1"
