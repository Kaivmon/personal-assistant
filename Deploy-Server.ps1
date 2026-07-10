param(
    [string]$InstallDir = "C:\PersonalAssistant",
    [string]$RepoUrl = "https://github.com/Kaivmon/personal-assistant.git",
    [string]$OpenClawRepoUrl = "https://github.com/openclaw/openclaw.git",
    [string]$ServiceName = "PersonalAssistant",
    [string]$OllamaBaseUrl = "http://172.19.96.1:11434"
)

$ErrorActionPreference = "Stop"

function Ensure-Command {
    param([string]$Name, [string]$WingetId)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        winget install --id $WingetId --exact --silent --accept-package-agreements --accept-source-agreements
    }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "data") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "data\reports") | Out-Null

Ensure-Command -Name "git" -WingetId "Git.Git"
Ensure-Command -Name "python" -WingetId "Python.Python.3.12"

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
python -m venv $Venv
& (Join-Path $Venv "Scripts\python.exe") -m pip install --upgrade pip
& (Join-Path $Venv "Scripts\python.exe") -m pip install -e $AppDir

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

$BinaryPath = "powershell.exe -ExecutionPolicy Bypass -File `"$ServiceScript`""
New-Service -Name $ServiceName -BinaryPathName $BinaryPath -DisplayName "Personal Assistant" -StartupType Automatic
Start-Service $ServiceName
Start-Sleep -Seconds 3

$Health = Invoke-RestMethod -Uri "http://127.0.0.1:8765/health" -Method GET
if (-not $Health.ok) {
    throw "Health check failed"
}

$OllamaHealth = Invoke-RestMethod -Uri "$OllamaBaseUrl/api/tags" -Method GET
if ($null -eq $OllamaHealth.models) {
    throw "Ollama health check failed at $OllamaBaseUrl"
}

Write-Host "Personal Assistant service is healthy at http://127.0.0.1:8765"
Write-Host "Ollama fallback is reachable at $OllamaBaseUrl"
Write-Host "Configure OpenClaw Discord/OAuth using $InstallDir\app\config\openclaw.assistant.example.json and $InstallDir\app\openclaw\assistant.skill.json"
