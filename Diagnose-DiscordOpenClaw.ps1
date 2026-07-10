param(
    [string]$InstallDir = "C:\PersonalAssistant",
    [string]$AssistantUrl = "http://127.0.0.1:8765",
    [int]$GatewayPort = 18789,
    [int]$ProbeCount = 10,
    [int]$WaitSeconds = 180,
    [switch]$PushToGitHub,
    [switch]$SkipInteractiveProbe
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SafeComputer = ($env:COMPUTERNAME -replace "[^A-Za-z0-9_.-]", "_")
$DiagRoot = Join-Path $RepoRoot "diagnostics"
$RunDir = Join-Path $DiagRoot "$SafeComputer-$Stamp"
$TranscriptPath = Join-Path $RunDir "console-transcript.txt"

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Write-Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "==== $Name ===="
}

function Redact-Text {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) {
        return $null
    }

    $Output = $Text
    $Output = $Output -replace '(?i)(token|api[_-]?key|secret|password|authorization|bot[_-]?token)(\s*[:=]\s*)("[^"]+"|''[^'']+''|[^\s,}\]]+)', '$1$2<redacted>'
    $Output = $Output -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}', '$1<redacted>'
    $Output = $Output -replace '\bmfa\.[A-Za-z0-9_\-]{60,}\b', '<discord-token-redacted>'
    $Output = $Output -replace '\b[A-Za-z0-9_\-]{20,40}\.[A-Za-z0-9_\-]{5,12}\.[A-Za-z0-9_\-]{20,80}\b', '<discord-token-redacted>'
    $Output = $Output -replace '(?i)("discord[^"]*token"\s*:\s*)"[^"]+"', '$1"<redacted>"'
    $Output = $Output -replace '(?i)(DISCORD_[A-Z0-9_]*TOKEN\s*=\s*)[^\r\n]+', '$1<redacted>'
    return $Output
}

function Write-TextFile {
    param(
        [string]$Name,
        [AllowNull()][string]$Content
    )
    $Path = Join-Path $RunDir $Name
    Redact-Text $Content | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-Capture {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    Write-Section $Name
    $SafeName = ($Name -replace "[^A-Za-z0-9_.-]", "_") + ".txt"
    $Path = Join-Path $RunDir $SafeName
    try {
        $Output = & $Script 2>&1 | Out-String -Width 300
        $Output = Redact-Text $Output
        $Output | Tee-Object -FilePath $Path
    } catch {
        $Message = "FAILED: $($_.Exception.Message)"
        Write-Host $Message
        $Message | Set-Content -Path $Path -Encoding UTF8
    }
}

function ConvertTo-RedactedJson {
    param($Value)

    function Redact-Object {
        param($InputObject)
        if ($null -eq $InputObject) {
            return $null
        }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $Hash = [ordered]@{}
            foreach ($Key in $InputObject.Keys) {
                if ($Key -match '(?i)token|key|secret|password|authorization|credential') {
                    $Hash[$Key] = "<redacted>"
                } else {
                    $Hash[$Key] = Redact-Object $InputObject[$Key]
                }
            }
            return $Hash
        }
        if ($InputObject -is [pscustomobject]) {
            $Hash = [ordered]@{}
            foreach ($Prop in $InputObject.PSObject.Properties) {
                if ($Prop.Name -match '(?i)token|key|secret|password|authorization|credential') {
                    $Hash[$Prop.Name] = "<redacted>"
                } else {
                    $Hash[$Prop.Name] = Redact-Object $Prop.Value
                }
            }
            return $Hash
        }
        if ($InputObject -is [array]) {
            return @($InputObject | ForEach-Object { Redact-Object $_ })
        }
        return $InputObject
    }

    Redact-Object $Value | ConvertTo-Json -Depth 100
}

function Read-EnvFile {
    param([string]$Path)
    $Values = @{}
    if (-not (Test-Path $Path)) {
        return $Values
    }
    Get-Content $Path | ForEach-Object {
        $Line = $_.Trim()
        if (-not $Line -or $Line.StartsWith("#") -or -not $Line.Contains("=")) {
            return
        }
        $Name, $Value = $Line.Split("=", 2)
        $Values[$Name] = $Value
    }
    return $Values
}

function Invoke-SqliteProbe {
    param(
        [string]$PythonPath,
        [string]$DbPath,
        [string[]]$Needles
    )

    if (-not (Test-Path $PythonPath)) {
        return "Python not found at $PythonPath"
    }
    if (-not (Test-Path $DbPath)) {
        return "SQLite database not found at $DbPath"
    }

    $NeedleJson = $Needles | ConvertTo-Json -Compress
    $Code = @"
import json
import sqlite3
import sys

db_path = sys.argv[1]
needles = json.loads(sys.argv[2])
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
out = {}
for needle in needles:
    row = conn.execute(
        "SELECT id, timestamp, category, event_type, subject, original_message FROM notes WHERE original_message LIKE ? ORDER BY id DESC LIMIT 1",
        (f"%{needle}%",),
    ).fetchone()
    out[needle] = dict(row) if row else None
print(json.dumps(out, indent=2))
"@
    & $PythonPath -c $Code $DbPath $NeedleJson 2>&1 | Out-String -Width 300
}

function Sanitize-DiagnosticFiles {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return
    }

    Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $Content = Get-Content $_.FullName -Raw -ErrorAction Stop
            $Redacted = Redact-Text $Content
            if ($Redacted -ne $Content) {
                Set-Content -Path $_.FullName -Value $Redacted -Encoding UTF8
            }
        } catch {
            $WarningPath = Join-Path $Path "sanitize-warnings.txt"
            "Could not sanitize $($_.FullName): $($_.Exception.Message)" | Add-Content -Path $WarningPath -Encoding UTF8
        }
    }
}

Start-Transcript -Path $TranscriptPath -Force | Out-Null

Write-Section "Diagnostic Run"
Write-Host "Run directory: $RunDir"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "InstallDir: $InstallDir"
Write-Host "AssistantUrl: $AssistantUrl"
Write-Host "GatewayPort: $GatewayPort"
Write-Host "Started: $(Get-Date -Format o)"

$EnvPath = Join-Path $InstallDir ".env"
$EnvValues = Read-EnvFile $EnvPath
$DbPath = if ($EnvValues["ASSISTANT_DB_PATH"]) { $EnvValues["ASSISTANT_DB_PATH"] } else { Join-Path $InstallDir "data\assistant.sqlite3" }
$PythonPath = Join-Path $InstallDir ".venv\Scripts\python.exe"

Invoke-Capture "Host Info" {
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        UserDomain = $env:USERDOMAIN
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        CurrentDirectory = (Get-Location).Path
        RepoRoot = $RepoRoot
        InstallDir = $InstallDir
        AssistantUrl = $AssistantUrl
        GatewayPort = $GatewayPort
        Timestamp = (Get-Date -Format o)
    } | Format-List
}

Invoke-Capture "IP Configuration" {
    ipconfig /all
}

Invoke-Capture "Relevant Services" {
    Get-Service PersonalAssistant -ErrorAction SilentlyContinue | Format-List *
    Get-Service *claw* -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType, DisplayName -AutoSize
}

Invoke-Capture "Scheduled Tasks" {
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match "openclaw|claw|assistant" -or $_.TaskPath -match "openclaw|claw|assistant" } |
        Select-Object TaskName, TaskPath, State, Author, Description |
        Format-List
}

Invoke-Capture "Gateway Port Listener" {
    $Conns = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue
    foreach ($Conn in $Conns) {
        $Proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($Conn.OwningProcess)" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            LocalAddress = $Conn.LocalAddress
            LocalPort = $Conn.LocalPort
            OwningProcess = $Conn.OwningProcess
            ProcessName = if ($Proc) { $Proc.Name } else { $null }
            CommandLine = if ($Proc) { $Proc.CommandLine } else { $null }
        }
    }
}

Invoke-Capture "Node Processes" {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine |
        Format-List
}

Invoke-Capture "Command Locations" {
    foreach ($Command in @("openclaw", "node", "npm", "npx", "git", "python", "pwsh", "powershell")) {
        $Found = Get-Command $Command -ErrorAction SilentlyContinue
        if ($Found) {
            "$Command -> $($Found.Source)"
            try {
                if ($Command -eq "powershell") {
                    & $Command -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
                } else {
                    & $Command --version
                }
            } catch {
                "$Command version failed: $($_.Exception.Message)"
            }
        } else {
            "$Command -> <not found>"
        }
        ""
    }
}

Invoke-Capture "Assistant Health" {
    Invoke-RestMethod "$AssistantUrl/health" -Method GET -TimeoutSec 8 | ConvertTo-Json -Depth 20
}

Invoke-Capture "Assistant Direct Write Probe" {
    $Probe = "direct_diag_$([guid]::NewGuid().ToString('N'))"
    $Body = @{ message = "log $Probe from diagnostic direct assistant probe" } | ConvertTo-Json
    $Result = Invoke-RestMethod "$AssistantUrl/openclaw/message" -Method POST -ContentType "application/json" -Body $Body -TimeoutSec 15
    "Probe: $Probe"
    $Result | ConvertTo-Json -Depth 20
    Invoke-SqliteProbe -PythonPath $PythonPath -DbPath $DbPath -Needles @($Probe)
}

Invoke-Capture "Assistant SQLite Recent Notes" {
    if (-not (Test-Path $PythonPath)) {
        "Python not found at $PythonPath"
        return
    }
    if (-not (Test-Path $DbPath)) {
        "SQLite database not found at $DbPath"
        return
    }
    $Code = @"
import json
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.row_factory = sqlite3.Row
rows = conn.execute(
    "SELECT id, timestamp, category, event_type, subject, confidence, original_message FROM notes ORDER BY id DESC LIMIT 25"
).fetchall()
print(json.dumps([dict(r) for r in rows], indent=2))
"@
    & $PythonPath -c $Code $DbPath 2>&1 | Out-String -Width 300
}

$OpenClawCommands = @(
    @{ Name = "OpenClaw Version"; Args = @("--version") },
    @{ Name = "OpenClaw Gateway Status"; Args = @("gateway", "status") },
    @{ Name = "OpenClaw Status"; Args = @("status") },
    @{ Name = "OpenClaw Status Usage"; Args = @("status", "--usage") },
    @{ Name = "OpenClaw Doctor"; Args = @("doctor") },
    @{ Name = "OpenClaw Models Status"; Args = @("models", "status") },
    @{ Name = "OpenClaw Model Fallbacks"; Args = @("models", "fallbacks", "list") },
    @{ Name = "OpenClaw Ollama Models"; Args = @("models", "list", "--provider", "ollama") },
    @{ Name = "OpenClaw Auth OpenAI"; Args = @("models", "auth", "list", "--provider", "openai") },
    @{ Name = "OpenClaw Plugins Enabled"; Args = @("plugins", "list", "--enabled", "--verbose") },
    @{ Name = "OpenClaw Discord Plugin Runtime"; Args = @("plugins", "inspect", "discord", "--runtime", "--json") },
    @{ Name = "OpenClaw Ollama Plugin Runtime"; Args = @("plugins", "inspect", "ollama", "--runtime", "--json") },
    @{ Name = "OpenClaw Personal Assistant Plugin Runtime"; Args = @("plugins", "inspect", "personal-assistant", "--runtime", "--json") },
    @{ Name = "OpenClaw Channels List"; Args = @("channels", "list", "--all") },
    @{ Name = "OpenClaw Recent Sessions"; Args = @("sessions", "list", "--limit", "20") }
)

foreach ($Item in $OpenClawCommands) {
    Invoke-Capture $Item.Name {
        & openclaw @($Item.Args) 2>&1 | Out-String -Width 300
    }
}

Invoke-Capture "OpenClaw Redacted Config" {
    $ConfigPath = Join-Path $env:USERPROFILE ".openclaw\openclaw.json"
    if (-not (Test-Path $ConfigPath)) {
        "OpenClaw config not found at $ConfigPath"
        return
    }
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    ConvertTo-RedactedJson $Config
}

Invoke-Capture "OpenClaw Assistant References" {
    $Root = Join-Path $env:USERPROFILE ".openclaw"
    if (-not (Test-Path $Root)) {
        "No ~/.openclaw directory found."
        return
    }
    foreach ($Pattern in @("personal-assistant", "personal_assistant", "127.0.0.1:8765", "/openclaw/message", "message tool", "discord")) {
        "-- pattern: $Pattern --"
        Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 2MB } |
            Select-String -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -First 30 Path, LineNumber, Line |
            Format-Table -AutoSize
        ""
    }
}

if (-not $SkipInteractiveProbe) {
    Write-Section "Discord Interactive Probe"
    $Needles = @()
    for ($i = 1; $i -le $ProbeCount; $i++) {
        $Needles += "discord_diag_${Stamp}_${i}"
    }
    $ProbePath = Join-Path $RunDir "discord-probe-messages.txt"
    $Needles | ForEach-Object { "log $_ from discord intermittent response diagnostic" } | Set-Content -Path $ProbePath -Encoding UTF8

    Write-Host "Send these $ProbeCount messages in Discord as separate messages, ideally 3-5 seconds apart:"
    Write-Host ""
    Get-Content $ProbePath | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Host "Waiting $WaitSeconds seconds, then checking SQLite for which messages reached the personal assistant plugin."
    Start-Sleep -Seconds $WaitSeconds

    Invoke-Capture "Discord Probe SQLite Results" {
        Invoke-SqliteProbe -PythonPath $PythonPath -DbPath $DbPath -Needles $Needles
    }
} else {
    Write-Host "Skipping interactive Discord probe because -SkipInteractiveProbe was supplied."
}

Invoke-Capture "Assistant Logs Tail" {
    foreach ($Relative in @("logs\service.log", "logs\service.err.log")) {
        $Path = Join-Path $InstallDir $Relative
        "-- $Path --"
        if (Test-Path $Path) {
            Get-Content $Path -Tail 300
        } else {
            "<missing>"
        }
        ""
    }
}

Invoke-Capture "OpenClaw Log Tails" {
    $Roots = @(
        (Join-Path $env:USERPROFILE ".openclaw"),
        (Join-Path $env:APPDATA "openclaw"),
        (Join-Path $env:LOCALAPPDATA "openclaw")
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($Root in $Roots) {
        "-- scanning $Root --"
        Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -lt 10MB -and (
                    $_.Name -match '\.log$|\.jsonl$|gateway|discord|doctor|error|stderr|stdout'
                )
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 20 FullName, LastWriteTime, Length |
            Format-Table -AutoSize
        ""
    }

    foreach ($Root in $Roots) {
        $Files = Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -lt 10MB -and (
                    $_.Name -match '\.log$|\.jsonl$|gateway|discord|doctor|error|stderr|stdout'
                )
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 10
        foreach ($File in $Files) {
            "-- tail $($File.FullName) --"
            try {
                Get-Content $File.FullName -Tail 160 -ErrorAction Stop
            } catch {
                "Could not read $($File.FullName): $($_.Exception.Message)"
            }
            ""
        }
    }
}

Invoke-Capture "Recent Windows Events" {
    $Since = (Get-Date).AddHours(-8)
    foreach ($LogName in @("Application", "System")) {
        "-- $LogName since $Since --"
        Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = $Since } -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProviderName -match "OpenClaw|Node|node|PowerShell|NSSM|Service Control Manager|Application Error|Windows Error Reporting|PersonalAssistant"
            } |
            Select-Object -First 80 TimeCreated, ProviderName, Id, LevelDisplayName, Message |
            Format-List
    }
}

Invoke-Capture "Git State Before Optional Push" {
    git status --short --branch
    git remote -v
}

Write-TextFile "README.txt" @"
Diagnostic bundle created by Diagnose-DiscordOpenClaw.ps1

Computer: $env:COMPUTERNAME
User: $env:USERNAME
Started: $Stamp
InstallDir: $InstallDir
AssistantUrl: $AssistantUrl
GatewayPort: $GatewayPort

Primary files to inspect first:
- OpenClaw_Doctor.txt
- OpenClaw_Status.txt
- OpenClaw_Models_Status.txt
- OpenClaw_Model_Fallbacks.txt
- OpenClaw_Discord_Plugin_Runtime.txt
- OpenClaw_Personal_Assistant_Plugin_Runtime.txt
- Discord_Probe_SQLite_Results.txt
- OpenClaw_Log_Tails.txt
- Gateway_Port_Listener.txt
"@

Stop-Transcript | Out-Null
Sanitize-DiagnosticFiles -Path $RunDir

if ($PushToGitHub) {
    Write-Host ""
    Write-Host "==== GitHub Upload ===="
    Push-Location $RepoRoot
    try {
        git add -- "diagnostics/$SafeComputer-$Stamp"
        git commit -m "Add Discord OpenClaw diagnostic bundle $SafeComputer $Stamp"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "git commit did not create a commit. Check git status output below."
        }
        git push origin HEAD
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Uploaded diagnostic bundle to GitHub."
        } else {
            Write-Host "git push failed. Diagnostic bundle remains at $RunDir"
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host ""
    Write-Host "Diagnostic bundle written to $RunDir"
    Write-Host "Run with -PushToGitHub to commit and push it."
}
