param(
    [string]$InstallDir = "C:\PersonalAssistant",
    [string]$OpenClawConfig = "$env:USERPROFILE\.openclaw\openclaw.json",
    [switch]$RestartGateway
)

$ErrorActionPreference = "Stop"

function Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "==== $Name ===="
}

function Save-Json {
    param(
        [object]$Value,
        [string]$Path
    )
    $Value | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 $Path
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

if (-not (Test-Path $OpenClawConfig)) {
    throw "OpenClaw config not found: $OpenClawConfig"
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = "$OpenClawConfig.backup-$Timestamp"
Copy-Item -LiteralPath $OpenClawConfig -Destination $Backup

Section "Backup"
Write-Host "Backed up OpenClaw config to $Backup"

$Config = Get-Content $OpenClawConfig -Raw | ConvertFrom-Json

Section "Before"
if ($Config.channels.discord) {
    Write-Host "channels.discord.groupPolicy: $($Config.channels.discord.groupPolicy)"
    Write-Host "channels.discord.allowFrom count: $(Count-Items $Config.channels.discord.allowFrom)"
    Write-Host "channels.discord.groupAllowFrom count: $(Count-Items $Config.channels.discord.groupAllowFrom)"
} else {
    Write-Host "channels.discord block not found."
}

if (-not $Config.channels) {
    $Config | Add-Member -NotePropertyName "channels" -NotePropertyValue ([pscustomobject]@{})
}
if (-not $Config.channels.discord) {
    $Config.channels | Add-Member -NotePropertyName "discord" -NotePropertyValue ([pscustomobject]@{})
}

$Config.channels.discord | Add-Member -NotePropertyName "groupPolicy" -NotePropertyValue "open" -Force

Save-Json $Config $OpenClawConfig

Section "After"
$Updated = Get-Content $OpenClawConfig -Raw | ConvertFrom-Json
Write-Host "channels.discord.groupPolicy: $($Updated.channels.discord.groupPolicy)"
Write-Host "channels.discord.allowFrom count: $(Count-Items $Updated.channels.discord.allowFrom)"
Write-Host "channels.discord.groupAllowFrom count: $(Count-Items $Updated.channels.discord.groupAllowFrom)"

Section "Personal Assistant Skill References In Active Config"
$ConfigText = Get-Content $OpenClawConfig -Raw
$Needles = @("personal-assistant", "assistant.skill.json", "127.0.0.1:8765", "/openclaw/message")
foreach ($Needle in $Needles) {
    if ($ConfigText.Contains($Needle)) {
        Write-Host "FOUND: $Needle"
    } else {
        Write-Host "MISSING: $Needle"
    }
}

Section "Doctor Fix"
try {
    openclaw doctor --fix
} catch {
    Write-Host "openclaw doctor --fix failed: $($_.Exception.Message)"
}

if ($RestartGateway) {
    Section "Restart Gateway"
    try {
        openclaw gateway restart
    } catch {
        Write-Host "openclaw gateway restart failed: $($_.Exception.Message)"
        Write-Host "If needed, restart the OpenClaw scheduled task or reboot the server."
    }
}

Section "Next"
Write-Host "Run .\Test-DiscordAssistantPath.ps1 again."
Write-Host "If personal assistant skill references are MISSING in active config, OpenClaw still has not registered the local assistant skill."
