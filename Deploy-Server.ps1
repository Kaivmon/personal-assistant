param(
    [string]$InstallDir = "C:\PersonalAssistant",
    [string]$RepoUrl = "https://github.com/Kaivmon/personal-assistant.git",
    [string]$OpenClawRepoUrl = "https://github.com/openclaw/openclaw.git",
    [string]$ServiceName = "PersonalAssistant",
    [string]$OllamaBaseUrl = "http://172.19.96.1:11434",
    [switch]$SkipOllamaHealthCheck
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Deploy-Server.ps1 must be run from an elevated PowerShell session. Right-click PowerShell and choose 'Run as administrator', then run this script again."
    }
}

function Ensure-Command {
    param([string]$Name, [string]$WingetId)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        winget install --id $WingetId --exact --silent --accept-package-agreements --accept-source-agreements
    }
}

function Resolve-Python {
    $Candidates = @(
        @{ Command = "py"; Args = @("-3.12") },
        @{ Command = "py"; Args = @("-3") },
        @{ Command = "python"; Args = @() }
    )
    foreach ($Candidate in $Candidates) {
        if (Get-Command $Candidate.Command -ErrorAction SilentlyContinue) {
            & $Candidate.Command @($Candidate.Args) --version | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $Candidate
            }
        }
    }
    throw "Python 3 was not found after installation. Open a new elevated PowerShell session and rerun this script."
}

function Resolve-Nssm {
    $Command = Get-Command nssm -ErrorAction SilentlyContinue
    if ($Command) {
        return $Command.Source
    }

    $SearchRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path $_) }
    if ($env:LOCALAPPDATA) {
        $WingetPackages = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
        if (Test-Path $WingetPackages) {
            $SearchRoots += $WingetPackages
        }
    }

    foreach ($Root in $SearchRoots) {
        $Match = Get-ChildItem -Path $Root -Recurse -Filter "nssm.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\win64\\|\\x64\\|nssm.exe$" } |
            Select-Object -First 1
        if ($Match) {
            return $Match.FullName
        }
    }

    throw "NSSM was installed but nssm.exe was not found. Open a new elevated PowerShell session and rerun this script."
}

function Stop-ExistingService {
    param([string]$Name)
    $Service = Get-Service $Name -ErrorAction SilentlyContinue
    if ($Service -and $Service.Status -ne "Stopped") {
        Stop-Service $Name -Force -ErrorAction SilentlyContinue
        $Service.WaitForStatus("Stopped", "00:00:20")
    }
}

function Reset-VenvIfBroken {
    param(
        [string]$VenvPath,
        [object]$PythonCommand
    )

    $VenvPythonPath = Join-Path $VenvPath "Scripts\python.exe"
    if (Test-Path $VenvPythonPath) {
        try {
            & $VenvPythonPath --version | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return
            }
        } catch {
            Write-Host "Existing virtualenv is not usable and will be recreated: $($_.Exception.Message)"
        }
    }

    if (Test-Path $VenvPath) {
        $ResolvedVenv = (Resolve-Path -LiteralPath $VenvPath).Path
        $ResolvedInstall = (Resolve-Path -LiteralPath $InstallDir).Path
        if (-not $ResolvedVenv.StartsWith($ResolvedInstall)) {
            throw "Refusing to remove venv outside install directory: $ResolvedVenv"
        }
        Remove-Item -LiteralPath $ResolvedVenv -Recurse -Force
    }

    & $PythonCommand.Command @($PythonCommand.Args) -m venv $VenvPath
    if ($LASTEXITCODE -ne 0) {
        throw "Python venv creation failed at $VenvPath"
    }
}

Assert-Administrator

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "data") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "data\reports") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "logs") | Out-Null

Ensure-Command -Name "git" -WingetId "Git.Git"
Ensure-Command -Name "python" -WingetId "Python.Python.3.12"
Ensure-Command -Name "nssm" -WingetId "NSSM.NSSM"

if ($RepoUrl -and -not (Test-Path (Join-Path $InstallDir "app\.git"))) {
    git clone $RepoUrl (Join-Path $InstallDir "app")
} elseif ($RepoUrl -and (Test-Path (Join-Path $InstallDir "app\.git"))) {
    Push-Location (Join-Path $InstallDir "app")
    git pull --ff-only
    Pop-Location
} elseif (-not (Test-Path (Join-Path $InstallDir "app"))) {
    Copy-Item -Recurse -Force "$PSScriptRoot" (Join-Path $InstallDir "app")
}

if (-not (Test-Path (Join-Path $InstallDir "openclaw\.git"))) {
    git clone $OpenClawRepoUrl (Join-Path $InstallDir "openclaw")
} else {
    Push-Location (Join-Path $InstallDir "openclaw")
    git pull --ff-only
    Pop-Location
}

$AppDir = Join-Path $InstallDir "app"
$Venv = Join-Path $InstallDir ".venv"
$Python = Resolve-Python
Stop-ExistingService -Name $ServiceName
Reset-VenvIfBroken -VenvPath $Venv -PythonCommand $Python
$VenvPython = Join-Path $Venv "Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    throw "Python venv was not created at $Venv. Open a new elevated PowerShell session and rerun this script."
}
& $VenvPython -m pip install --upgrade pip
& $VenvPython -m pip install -e $AppDir

$EnvPath = Join-Path $InstallDir ".env"
if (-not (Test-Path $EnvPath)) {
@"
ASSISTANT_HOST=127.0.0.1
ASSISTANT_PORT=8765
ASSISTANT_DB_PATH=$InstallDir\data\assistant.sqlite3
ASSISTANT_REPORT_DIR=$InstallDir\data\reports
ASSISTANT_REPORT_TTL_SECONDS=7200
OPENCLAW_BASE_URL=http://127.0.0.1:3210
OPENCLAW_PROFILE=personal-assistant
OPENCLAW_DISCORD_ENABLED=true
OPENCLAW_DISCORD_BOT_TOKEN=
OPENCLAW_ALLOWED_DISCORD_USER_IDS=
OPENCLAW_CHATGPT_OAUTH_PROFILE=default
CHATGPT_USAGE_LIMIT_PER_WINDOW=80
CHATGPT_USAGE_USED=0
CHATGPT_WARN_REMAINING=20,5
OLLAMA_BASE_URL=$OllamaBaseUrl
OLLAMA_MODEL=llama3.1:8b
"@ | Set-Content -Encoding UTF8 $EnvPath
}

& (Join-Path $Venv "Scripts\personal-assistant.exe") init-db

$ServiceScript = Join-Path $InstallDir "Run-Service.ps1"
@"
Get-Content '$EnvPath' | Where-Object { `$_.Trim() -and -not `$_.StartsWith('#') } | ForEach-Object {
    `$name, `$value = `$_.Split('=', 2)
    [Environment]::SetEnvironmentVariable(`$name, `$value, 'Process')
}
& '$Venv\Scripts\personal-assistant.exe' serve
"@ | Set-Content -Encoding UTF8 $ServiceScript

if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service $ServiceName -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

$Nssm = Resolve-Nssm
$ServiceLog = Join-Path $InstallDir "logs\service.log"
$ServiceErr = Join-Path $InstallDir "logs\service.err.log"
& $Nssm install $ServiceName "powershell.exe"
& $Nssm set $ServiceName AppParameters "-NoProfile -ExecutionPolicy Bypass -File `"$ServiceScript`""
& $Nssm set $ServiceName AppDirectory $InstallDir
& $Nssm set $ServiceName DisplayName "Personal Assistant"
& $Nssm set $ServiceName Start SERVICE_AUTO_START
& $Nssm set $ServiceName AppStdout $ServiceLog
& $Nssm set $ServiceName AppStderr $ServiceErr
& $Nssm set $ServiceName AppRotateFiles 1
Start-Service $ServiceName
Start-Sleep -Seconds 3

$Health = Invoke-RestMethod -Uri "http://127.0.0.1:8765/health" -Method GET
if (-not $Health.ok) {
    throw "Health check failed"
}

if (-not $SkipOllamaHealthCheck) {
    try {
        $OllamaHealth = Invoke-RestMethod -Uri "$OllamaBaseUrl/api/tags" -Method GET -TimeoutSec 10
        if ($null -eq $OllamaHealth.models) {
            throw "Ollama responded but did not return a models list."
        }
    } catch {
        throw @"
Ollama health check failed at $OllamaBaseUrl.

The Personal Assistant service is installed, but the Windows Server cannot reach Beelink Ollama.

On the Beelink, run:
  Get-NetIPConfiguration | Where-Object { `$_.IPv4DefaultGateway } | Select-Object -ExpandProperty IPv4Address
  Invoke-RestMethod http://127.0.0.1:11434/api/tags

On the Windows Server, test:
  Invoke-RestMethod $OllamaBaseUrl/api/tags

If the Beelink IP is different, rerun:
  .\Deploy-Server.ps1 -OllamaBaseUrl "http://BEELINK-LAN-IP:11434"

To finish server deployment without verifying Ollama yet, rerun:
  .\Deploy-Server.ps1 -SkipOllamaHealthCheck

Original error: $($_.Exception.Message)
"@
    }
}

Write-Host "Personal Assistant service is healthy at http://127.0.0.1:8765"
if ($SkipOllamaHealthCheck) {
    Write-Host "Skipped Ollama fallback health check."
} else {
    Write-Host "Ollama fallback is reachable at $OllamaBaseUrl"
}
Write-Host "Configure OpenClaw Discord/OAuth using $InstallDir\app\config\openclaw.assistant.example.json and $InstallDir\app\openclaw\assistant.skill.json"
