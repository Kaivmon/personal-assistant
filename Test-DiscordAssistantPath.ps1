param(
    [string]$InstallDir = "C:\PersonalAssistant",
    [int]$WaitSeconds = 90
)

$ErrorActionPreference = "Continue"

function Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "==== $Name ===="
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

function Invoke-AssistantJson {
    param(
        [string]$Url,
        [string]$Body
    )
    Invoke-RestMethod $Url -Method POST -ContentType "application/json" -Body $Body -TimeoutSec 10
}

function Test-NoteInDatabase {
    param(
        [string]$PythonPath,
        [string]$DbPath,
        [string]$Needle
    )

    $Code = @"
import json
import sqlite3
import sys

db_path = sys.argv[1]
needle = sys.argv[2]
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
row = conn.execute(
    "SELECT id, timestamp, category, event_type, subject, original_message FROM notes WHERE original_message LIKE ? ORDER BY id DESC LIMIT 1",
    (f"%{needle}%",),
).fetchone()
print(json.dumps(dict(row) if row else None))
"@
    $Result = & $PythonPath -c $Code $DbPath $Needle
    if ($LASTEXITCODE -ne 0 -or -not $Result) {
        return $null
    }
    return $Result | ConvertFrom-Json
}

function Show-OpenClawConfigSummary {
    $ConfigPath = Join-Path $env:USERPROFILE ".openclaw\openclaw.json"
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "OpenClaw config not found at $ConfigPath"
        return
    }

    try {
        $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Write-Host "Config: $ConfigPath"
        if ($Config.channels.discord) {
            $Discord = $Config.channels.discord
            Write-Host "Discord configured: yes"
            Write-Host "Discord token present: $([bool]$Discord.token)"
            Write-Host "Discord groupPolicy: $($Discord.groupPolicy)"
            Write-Host "Discord dmPolicy: $($Discord.dmPolicy)"
            Write-Host "Discord allowFrom count: $(Count-Items $Discord.allowFrom)"
            Write-Host "Discord groupAllowFrom count: $(Count-Items $Discord.groupAllowFrom)"
        } else {
            Write-Host "Discord configured: no channels.discord block found"
        }
        if ($Config.commands) {
            Write-Host "Command ownerAllowFrom count: $(Count-Items $Config.commands.ownerAllowFrom)"
        }
    } catch {
        Write-Host "Failed to parse OpenClaw config: $($_.Exception.Message)"
    }
}

function Count-Items {
    param($Value)
    if ($null -eq $Value) {
        return 0
    }
    if ($Value -is [array]) {
        return $Value.Count
    }
    return 1
}

function Search-OpenClawAssistantReferences {
    $Root = Join-Path $env:USERPROFILE ".openclaw"
    if (-not (Test-Path $Root)) {
        Write-Host "No ~/.openclaw directory found."
        return
    }

    $Patterns = @("personal-assistant", "personal_assistant", "127.0.0.1:8765", "/openclaw/message")
    foreach ($Pattern in $Patterns) {
        $Matches = Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 2MB } |
            Select-String -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -First 10 Path, LineNumber, Line
        Write-Host "-- pattern: $Pattern --"
        if ($Matches) {
            $Matches | Format-Table -AutoSize
        } else {
            Write-Host "<no matches>"
        }
    }
}

$EnvPath = Join-Path $InstallDir ".env"
$Env = Read-EnvFile $EnvPath
$AssistantHost = if ($Env["ASSISTANT_HOST"]) { $Env["ASSISTANT_HOST"] } else { "127.0.0.1" }
$AssistantPort = if ($Env["ASSISTANT_PORT"]) { $Env["ASSISTANT_PORT"] } else { "8765" }
$AssistantUrl = "http://$AssistantHost`:$AssistantPort"
$DbPath = if ($Env["ASSISTANT_DB_PATH"]) { $Env["ASSISTANT_DB_PATH"] } else { Join-Path $InstallDir "data\assistant.sqlite3" }
$PythonPath = Join-Path $InstallDir ".venv\Scripts\python.exe"

Section "Local Assistant"
Get-Service PersonalAssistant -ErrorAction SilentlyContinue | Format-List Name, Status, StartType
try {
    Invoke-RestMethod "$AssistantUrl/health" -Method GET -TimeoutSec 5 | ConvertTo-Json -Depth 5
} catch {
    Write-Host "Health failed: $($_.Exception.Message)"
}

Section "Direct Assistant Write"
$DirectProbe = "direct_probe_$([guid]::NewGuid().ToString('N'))"
try {
    $DirectBody = @{ message = "log $DirectProbe from powershell direct assistant check" } | ConvertTo-Json
    $DirectResult = Invoke-AssistantJson "$AssistantUrl/openclaw/message" $DirectBody
    $DirectResult | ConvertTo-Json -Depth 8
    $DirectRow = Test-NoteInDatabase $PythonPath $DbPath $DirectProbe
    if ($DirectRow) {
        Write-Host "DIRECT RESULT: PASS - local assistant writes to SQLite."
    } else {
        Write-Host "DIRECT RESULT: FAIL - endpoint responded but note was not found in SQLite."
    }
} catch {
    Write-Host "DIRECT RESULT: FAIL - $($_.Exception.Message)"
}

Section "OpenClaw Config Summary"
Show-OpenClawConfigSummary

Section "OpenClaw Assistant Skill References"
Search-OpenClawAssistantReferences

Section "OpenClaw Personal Assistant Plugin"
try {
    openclaw plugins inspect personal-assistant --runtime --json
} catch {
    Write-Host "openclaw plugins inspect personal-assistant --runtime --json failed: $($_.Exception.Message)"
}

Section "OpenClaw Doctor Signals"
try {
    $Doctor = & openclaw doctor 2>&1
    $Doctor | Select-String -Pattern "discord|message tool|groupPolicy|allowlist|allowFrom|plugin|skill|warning" -CaseSensitive:$false
} catch {
    Write-Host "openclaw doctor failed: $($_.Exception.Message)"
}

Section "Discord To Assistant Probe"
$DiscordProbe = "discord_probe_$([guid]::NewGuid().ToString('N'))"
Write-Host "Send this exact message in Discord now:"
Write-Host ""
Write-Host "log $DiscordProbe from discord assistant path check"
Write-Host ""
Write-Host "Waiting up to $WaitSeconds seconds for that exact text to appear in SQLite..."

$Deadline = (Get-Date).AddSeconds($WaitSeconds)
$Found = $null
while ((Get-Date) -lt $Deadline) {
    $Found = Test-NoteInDatabase $PythonPath $DbPath $DiscordProbe
    if ($Found) {
        break
    }
    Start-Sleep -Seconds 3
}

if ($Found) {
    Write-Host "DISCORD PATH RESULT: PASS - Discord/OpenClaw called PersonalAssistant."
    $Found | ConvertTo-Json -Depth 5
} else {
    Write-Host "DISCORD PATH RESULT: FAIL - probe did not appear in SQLite."
    Write-Host "If the bot replied in Discord anyway, it is responding through OpenClaw/model routing without calling the PersonalAssistant note skill."
}

Section "Recent Assistant Logs"
foreach ($Log in @("logs\service.err.log", "logs\service.log")) {
    $Path = Join-Path $InstallDir $Log
    Write-Host "-- $Path --"
    if (Test-Path $Path) {
        Get-Content $Path -Tail 60
    } else {
        Write-Host "<missing>"
    }
}
