<#
.SYNOPSIS
    SecurePAM status report for Windows environments.
.DESCRIPTION
    READ-ONLY health report for the whole SecurePAM environment on Windows.
    Changes nothing: no start/stop/restart, no writes, no secrets read or printed.
    Every row is a real check (HTTP/TCP protocol response or Windows service/Docker container state).
.PARAMETER NoColor
    Disable colored ANSI output.
#>
param(
    [switch]$NoColor,
    [switch]$Help
)

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path
    exit 0
}

$ErrorActionPreference = "SilentlyContinue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$global:BadCount = 0

function Write-StateRow {
    param(
        [string]$Name,
        [string]$State,
        [string]$Detail,
        [bool]$Managed = $true
    )

    $padName = $Name.PadRight(35)
    $padState = $State.PadRight(10)

    if ($NoColor) {
        Write-Host "$padName $padState $Detail"
    } else {
        $color = switch ($State.ToLower()) {
            "healthy"  { "Green" }
            "stopped"  { "Red" }
            "sealed"   { "Magenta" }
            "degraded" { "Yellow" }
            default    { "DarkGray" }
        }
        Write-Host -NoNewline $padName
        Write-Host -NoNewline " "
        Write-Host -NoNewline -ForegroundColor $color $padState
        Write-Host " $Detail"
    }

    if ($Managed -and ($State -ne "healthy")) {
        $global:BadCount++
    }
}

function Test-TcpPort {
    param([string]$Address = "127.0.0.1", [int]$Port, [int]$TimeoutMs = 1500)
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($Address, $Port, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $wait) {
            $tcpClient.Close()
            return $false
        }
        $tcpClient.EndConnect($connect)
        $tcpClient.Close()
        return $true
    } catch {
        return $false
    }
}

function Test-HttpEndpoint {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $resp = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return @{ StatusCode = $resp.StatusCode; Content = $resp.Content }
    } catch {
        if ($_.Exception.Response) {
            return @{ StatusCode = [int]$_.Exception.Response.StatusCode; Content = "" }
        }
        return $null
    }
}

Write-Host "SecurePAM Status (Windows) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("-" * 85)
Write-Host "Infrastructure"

# 1. Docker engine
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-StateRow "Docker engine" "unknown" "docker CLI not found in PATH" $true
} else {
    try {
        $dockerVer = & docker info --format '{{.ServerVersion}}' 2>$null
        if ($dockerVer) {
            Write-StateRow "Docker engine" "healthy" "engine $dockerVer" $true
        } else {
            Write-StateRow "Docker engine" "stopped" "Docker daemon is not running" $true
        }
    } catch {
        Write-StateRow "Docker engine" "stopped" "Docker daemon is not answering" $true
    }
}

# 2. PostgreSQL
$pgPortOpen = Test-TcpPort -Port 5432
$pgService = Get-Service -Name "*postgres*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgPortOpen) {
    $detail = "accepting TCP connections on 5432"
    if ($pgService) { $detail += " (Service: $($pgService.Name) is $($pgService.Status))" }
    Write-StateRow "PostgreSQL (port 5432)" "healthy" $detail $true
} elseif ($pgService) {
    Write-StateRow "PostgreSQL (port 5432)" "stopped" "Windows service $($pgService.Name) status: $($pgService.Status)" $true
} else {
    Write-StateRow "PostgreSQL (port 5432)" "stopped" "Port 5432 closed; no native service detected" $true
}

# 3. Redis
$redisPortOpen = Test-TcpPort -Port 6379
$redisService = Get-Service -Name "*redis*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($redisPortOpen) {
    $detail = "accepting TCP connections on 6379"
    if ($redisService) { $detail += " (Service: $($redisService.Name) is $($redisService.Status))" }
    Write-StateRow "Redis (port 6379)" "healthy" $detail $true
} elseif ($redisService) {
    Write-StateRow "Redis (port 6379)" "stopped" "Windows service $($redisService.Name) status: $($redisService.Status)" $true
} else {
    Write-StateRow "Redis (port 6379)" "stopped" "Port 6379 closed; no native service detected" $true
}

# 4. OpenBao staging (:18210)
$baoPortOpen = Test-TcpPort -Port 18210
if ($baoPortOpen) {
    Write-StateRow "OpenBao staging :18210 (TLS)" "healthy" "port 18210 listening" $true
} else {
    Write-StateRow "OpenBao staging :18210 (TLS)" "stopped" "port 18210 closed" $true
}

# 5. Keycloak (:8080)
$kcHttp = Test-HttpEndpoint -Url "http://localhost:8080/realms/securepam" -TimeoutSec 3
if ($kcHttp -and ($kcHttp.StatusCode -eq 200)) {
    Write-StateRow "Keycloak :8080" "healthy" "realm 'securepam' answers (HTTP 200)" $true
} elseif (Test-TcpPort -Port 8080) {
    Write-StateRow "Keycloak :8080" "degraded" "port 8080 open but realm URL returned HTTP $($kcHttp.StatusCode)" $true
} else {
    Write-StateRow "Keycloak :8080" "stopped" "port 8080 closed" $true
}

# 6. Guacamole guacd (:4822) & web app (:8081)
if (Test-TcpPort -Port 4822) {
    Write-StateRow "guacd :4822" "healthy" "accepts connections on 4822" $true
} else {
    Write-StateRow "guacd :4822" "stopped" "port 4822 closed" $true
}

$guacHttp = Test-HttpEndpoint -Url "http://127.0.0.1:8081/guacamole/" -TimeoutSec 3
if ($guacHttp -and ($guacHttp.StatusCode -eq 200)) {
    Write-StateRow "Guacamole :8081" "healthy" "web app answers (HTTP 200)" $true
} elseif (Test-TcpPort -Port 8081) {
    Write-StateRow "Guacamole :8081" "degraded" "port 8081 open but /guacamole/ returned HTTP $($guacHttp.StatusCode)" $true
} else {
    Write-StateRow "Guacamole :8081" "stopped" "port 8081 closed" $true
}

# 7. Browser isolation (:6090)
$isoHttp = Test-HttpEndpoint -Url "http://127.0.0.1:6090/health" -TimeoutSec 2
if ($isoHttp -and ($isoHttp.StatusCode -eq 200)) {
    Write-StateRow "Browser isolation :6090" "healthy" "daemon /health answers OK" $true
} elseif (Test-TcpPort -Port 6090) {
    Write-StateRow "Browser isolation :6090" "degraded" "port 6090 open but /health not reporting 200" $true
} else {
    Write-StateRow "Browser isolation :6090" "stopped" "port 6090 closed" $true
}

Write-Host "Applications"

# 8. Backend :8000 (standard dev port)
$be8000 = Test-HttpEndpoint -Url "http://127.0.0.1:8000/health/ready" -TimeoutSec 3
if ($be8000 -and ($be8000.StatusCode -eq 200)) {
    Write-StateRow "Backend :8000 (dev api)" "healthy" "/health/ready ok" $true
} elseif (Test-TcpPort -Port 8000) {
    Write-StateRow "Backend :8000 (dev api)" "degraded" "port 8000 open but /health/ready returned $($be8000.StatusCode)" $true
} else {
    Write-StateRow "Backend :8000 (dev api)" "stopped" "nothing listening on 8000" $true
}

# 9. Frontend :3000 (standard dev port)
$fe3000 = Test-HttpEndpoint -Url "http://127.0.0.1:3000/" -TimeoutSec 3
if ($fe3000 -and ($fe3000.StatusCode -eq 200)) {
    Write-StateRow "Frontend :3000 -> 8000" "healthy" "Vite app page loads on 3000" $true
} elseif (Test-TcpPort -Port 3000) {
    Write-StateRow "Frontend :3000 -> 8000" "degraded" "port 3000 open but returned $($fe3000.StatusCode)" $true
} else {
    Write-StateRow "Frontend :3000 -> 8000" "stopped" "nothing listening on 3000" $true
}

# 10. Backend :8001 (optional staging)
$be8001 = Test-HttpEndpoint -Url "http://127.0.0.1:8001/health/ready" -TimeoutSec 2
if ($be8001 -and ($be8001.StatusCode -eq 200)) {
    Write-StateRow "Backend :8001 (dev login)" "healthy" "/health/ready ok" $false
} elseif (Test-TcpPort -Port 8001) {
    Write-StateRow "Backend :8001 (dev login)" "degraded" "port 8001 open" $false
} else {
    Write-StateRow "Backend :8001 (dev login)" "stopped" "optional staging instance" $false
}

# 11. Frontend :3001 (optional staging)
$fe3001 = Test-HttpEndpoint -Url "http://127.0.0.1:3001/" -TimeoutSec 2
if ($fe3001 -and ($fe3001.StatusCode -eq 200)) {
    Write-StateRow "Frontend :3001 -> 8001" "healthy" "Vite app page loads on 3001" $false
} elseif (Test-TcpPort -Port 3001) {
    Write-StateRow "Frontend :3001 -> 8001" "degraded" "port 3001 open" $false
} else {
    Write-StateRow "Frontend :3001 -> 8001" "stopped" "optional staging instance" $false
}

# 10. Backend :8002
$be8002 = Test-HttpEndpoint -Url "http://127.0.0.1:8002/health/ready" -TimeoutSec 3
if ($be8002 -and ($be8002.StatusCode -eq 200)) {
    Write-StateRow "Backend :8002 (Keycloak MFA)" "healthy" "/health/ready ok" $true
} elseif (Test-TcpPort -Port 8002) {
    Write-StateRow "Backend :8002 (Keycloak MFA)" "degraded" "port 8002 open but /health/ready returned $($be8002.StatusCode)" $true
} else {
    Write-StateRow "Backend :8002 (Keycloak MFA)" "stopped" "nothing listening on 8002" $true
}

# 11. Frontend :3002
$fe3002 = Test-HttpEndpoint -Url "http://127.0.0.1:3002/" -TimeoutSec 3
if ($fe3002 -and ($fe3002.StatusCode -eq 200)) {
    Write-StateRow "Frontend :3002 -> 8002" "healthy" "Vite app page loads on 3002" $true
} elseif (Test-TcpPort -Port 3002) {
    Write-StateRow "Frontend :3002 -> 8002" "degraded" "port 3002 open but returned $($fe3002.StatusCode)" $true
} else {
    Write-StateRow "Frontend :3002 -> 8002" "stopped" "nothing listening on 3002" $true
}

Write-Host "Informational"
$baoDevHttp = Test-HttpEndpoint -Url "http://127.0.0.1:18200/v1/sys/health" -TimeoutSec 2
if ($baoDevHttp -and ($baoDevHttp.StatusCode -eq 200)) {
    Write-StateRow "OpenBao dev :18200" "healthy" "dev instance answering" $false
} else {
    Write-StateRow "OpenBao dev :18200" "stopped" "not running (optional dev instance)" $false
}

Write-Host ("-" * 85)
if ($global:BadCount -eq 0) {
    Write-Host "All managed components are healthy." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($global:BadCount) managed component(s) not healthy. Start with: .\scripts\start-securepam.ps1" -ForegroundColor Yellow
    exit 1
}
