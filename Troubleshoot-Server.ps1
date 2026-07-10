param(
    [string]$InstallDir = "C:\PersonalAssistant",
    [string]$AssistantUrl = "http://127.0.0.1:8765"
)

$ErrorActionPreference = "Continue"

function Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "==== $Name ===="
}

function Mask-Value {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "<empty>"
    }
    if ($Value.Length -le 8) {
        return "<set>"
    }
    return "$($Value.Substring(0, 4))...$($Value.Substring($Value.Length - 4))"
}

Section "Host"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "InstallDir: $InstallDir"

Section "Assistant Service"
Get-Service PersonalAssistant -ErrorAction SilentlyContinue | Format-List Name, Status, StartType, ServiceName, DisplayName

Section "Assistant Health"
try {
    Invoke-RestMethod "$AssistantUrl/health" -Method GET -TimeoutSec 5 | ConvertTo-Json -Depth 5
} catch {
    Write-Host "Assistant health failed: $($_.Exception.Message)"
}

Section "Assistant Message Endpoint"
try {
    Invoke-RestMethod "$AssistantUrl/openclaw/message" -Method POST -ContentType "application/json" -Body '{"message":"diagnostic note from server"}' -TimeoutSec 5 | ConvertTo-Json -Depth 8
} catch {
    Write-Host "Assistant message endpoint failed: $($_.Exception.Message)"
}

Section "Environment File"
$EnvPath = Join-Path $InstallDir ".env"
if (Test-Path $EnvPath) {
    Get-Content $EnvPath | ForEach-Object {
        if (-not $_.Trim() -or $_.Trim().StartsWith("#")) {
            return
        }
        $Name, $Value = $_.Split("=", 2)
        if ($Name -match "TOKEN|KEY|SECRET|PASSWORD|CODE") {
            Write-Host "$Name=$(Mask-Value $Value)"
        } else {
            Write-Host $_
        }
    }
} else {
    Write-Host "Missing $EnvPath"
}

Section "Node And NPM"
foreach ($Command in @("node", "npm", "npx", "openclaw")) {
    $Found = Get-Command $Command -ErrorAction SilentlyContinue
    if ($Found) {
        Write-Host "$Command -> $($Found.Source)"
        try {
            & $Command --version
        } catch {
            Write-Host "$Command version failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host "$Command -> <not found>"
    }
}

Section "OpenClaw Services And Processes"
Get-Service *claw* -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType, DisplayName
Get-Process *claw* -ErrorAction SilentlyContinue | Select-Object ProcessName, Id, Path | Format-Table

Section "Likely OpenClaw Paths"
$Paths = @(
    (Join-Path $InstallDir "openclaw"),
    (Join-Path $env:USERPROFILE ".openclaw"),
    (Join-Path $env:APPDATA "openclaw"),
    (Join-Path $env:LOCALAPPDATA "openclaw"),
    (Join-Path $env:APPDATA "npm")
)
foreach ($Path in $Paths) {
    if ($Path -and (Test-Path $Path)) {
        Write-Host "Exists: $Path"
        Get-ChildItem $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 20 FullName
    } else {
        Write-Host "Missing: $Path"
    }
}

Section "OpenClaw Doctor"
try {
    npx -y openclaw@latest doctor
} catch {
    Write-Host "npx openclaw doctor failed: $($_.Exception.Message)"
}

Section "OpenClaw Gateway Status"
try {
    npx -y openclaw@latest gateway status
} catch {
    Write-Host "npx openclaw gateway status failed: $($_.Exception.Message)"
}

Section "Recent Assistant Logs"
foreach ($Log in @("logs\service.err.log", "logs\service.log")) {
    $Path = Join-Path $InstallDir $Log
    Write-Host "-- $Path --"
    if (Test-Path $Path) {
        Get-Content $Path -Tail 80
    } else {
        Write-Host "<missing>"
    }
}
