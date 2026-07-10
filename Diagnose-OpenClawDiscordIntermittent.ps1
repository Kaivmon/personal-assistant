param(
    [string]$Mention = "@Cortana",
    [int]$ProbeCount = 10,
    [int]$WaitSeconds = 240,
    [int]$GatewayPort = 18789,
    [switch]$PushToGitHub
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SafeComputer = ($env:COMPUTERNAME -replace "[^A-Za-z0-9_.-]", "_")
$RunDir = Join-Path (Join-Path $RepoRoot "diagnostics") "$SafeComputer-openclaw-discord-$Stamp"
$TranscriptPath = Join-Path $RunDir "console-transcript.txt"
$OpenClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$SessionsRoot = Join-Path $OpenClawRoot "agents\main\sessions"

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Write-Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "==== $Name ===="
}

function Redact-Text {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
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
    param([string]$Name, [AllowNull()][string]$Content)
    $Path = Join-Path $RunDir $Name
    Redact-Text $Content | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-Capture {
    param([string]$Name, [scriptblock]$Script)
    Write-Section $Name
    $FileName = ($Name -replace "[^A-Za-z0-9_.-]", "_") + ".txt"
    $Path = Join-Path $RunDir $FileName
    try {
        $Output = & $Script 2>&1 | Out-String -Width 320
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
        if ($null -eq $InputObject) { return $null }
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

function Sanitize-DiagnosticFiles {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $Content = Get-Content $_.FullName -Raw -ErrorAction Stop
            $Redacted = Redact-Text $Content
            if ($Redacted -ne $Content) {
                Set-Content -Path $_.FullName -Value $Redacted -Encoding UTF8
            }
        } catch {
            "Could not sanitize $($_.FullName): $($_.Exception.Message)" |
                Add-Content -Path (Join-Path $Path "sanitize-warnings.txt") -Encoding UTF8
        }
    }
}

function Get-SessionFileSnapshot {
    if (-not (Test-Path $SessionsRoot)) { return @() }
    Get-ChildItem $SessionsRoot -Recurse -File -Include *.jsonl,*.trajectory.jsonl -ErrorAction SilentlyContinue |
        Select-Object FullName, LastWriteTimeUtc, Length
}

function Search-ProbesInOpenClawFiles {
    param([string[]]$Needles)

    $Roots = @(
        $SessionsRoot,
        (Join-Path $OpenClawRoot "logs")
    ) | Where-Object { $_ -and (Test-Path $_) }

    $Files = foreach ($Root in $Roots) {
        Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 25MB -and ($_.Extension -in @(".jsonl", ".log", ".txt", ".json") -or $_.Name -match "gateway|discord|session|trajectory") }
    }

    $Rows = foreach ($Needle in $Needles) {
        $Matches = foreach ($File in $Files) {
            Select-String -Path $File.FullName -Pattern $Needle -SimpleMatch -ErrorAction SilentlyContinue |
                Select-Object -First 20
        }
        [pscustomobject]@{
            Probe = $Needle
            MatchCount = @($Matches).Count
            Files = (@($Matches) | Select-Object -ExpandProperty Path -Unique) -join "; "
            FirstLines = (@($Matches) | Select-Object -First 6 | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n"
        }
    }
    $Rows | Format-List
}

function Summarize-ProbeTurns {
    param([string[]]$Needles)

    if (-not (Test-Path $SessionsRoot)) {
        "Sessions root not found: $SessionsRoot"
        return
    }

    $Files = Get-ChildItem $SessionsRoot -Recurse -File -Include *.jsonl,*.trajectory.jsonl -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 50MB } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 40

    foreach ($Needle in $Needles) {
        "---- $Needle ----"
        $Found = $false
        foreach ($File in $Files) {
            $Lines = Select-String -Path $File.FullName -Pattern $Needle -SimpleMatch -Context 8,20 -ErrorAction SilentlyContinue
            foreach ($Match in $Lines) {
                $Found = $true
                "FILE: $($File.FullName)"
                "LINE: $($Match.LineNumber)"
                ($Match.Context.PreContext + $Match.Line + $Match.Context.PostContext) |
                    Select-String -Pattern "was_mentioned|inbound_event_kind|task_started|task_complete|agent_message|NO_REPLY|error|rate_limit|rate_limits|message_id|sender|content|body|final_answer" -CaseSensitive:$false |
                    ForEach-Object { $_.Line }
                ""
            }
        }
        if (-not $Found) {
            "NOT FOUND in captured OpenClaw session/log files."
        }
        ""
    }
}

Start-Transcript -Path $TranscriptPath -Force | Out-Null

Write-Section "Diagnostic Run"
Write-Host "Run directory: $RunDir"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "Mention prefix: $Mention"
Write-Host "Probe count: $ProbeCount"
Write-Host "Wait seconds: $WaitSeconds"
Write-Host "Started: $(Get-Date -Format o)"

$BeforeSnapshot = Get-SessionFileSnapshot

Invoke-Capture "Host And Gateway Process" {
    "Computer: $env:COMPUTERNAME"
    "User: $env:USERNAME"
    "PowerShell: $($PSVersionTable.PSVersion)"
    "OpenClawRoot: $OpenClawRoot"
    ""
    "Gateway listener:"
    $Conns = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue
    foreach ($Conn in $Conns) {
        $Proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($Conn.OwningProcess)" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            LocalAddress = $Conn.LocalAddress
            LocalPort = $Conn.LocalPort
            OwningProcess = $Conn.OwningProcess
            ProcessName = $Proc.Name
            CommandLine = $Proc.CommandLine
        }
    }
    ""
    "Node processes:"
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine |
        Format-List
}

Invoke-Capture "OpenClaw Status" {
    & openclaw status 2>&1 | Out-String -Width 320
}

Invoke-Capture "OpenClaw Doctor" {
    & openclaw doctor 2>&1 | Out-String -Width 320
}

Invoke-Capture "OpenClaw Config Redacted" {
    $ConfigPath = Join-Path $OpenClawRoot "openclaw.json"
    if (-not (Test-Path $ConfigPath)) {
        "Missing $ConfigPath"
        return
    }
    ConvertTo-RedactedJson (Get-Content $ConfigPath -Raw | ConvertFrom-Json)
}

Invoke-Capture "OpenClaw Config Key Lines" {
    $ConfigPath = Join-Path $OpenClawRoot "openclaw.json"
    if (-not (Test-Path $ConfigPath)) {
        "Missing $ConfigPath"
        return
    }
    Select-String -Path $ConfigPath -Pattern "discord|groupPolicy|requireMention|allowFrom|ownerAllowFrom|visibleReplies|queue|concurrency|model|fallback|personal-assistant|message|tools|plugins" -CaseSensitive:$false |
        Select-Object LineNumber, Line |
        Format-Table -AutoSize
}

$Needles = @()
for ($i = 1; $i -le $ProbeCount; $i++) {
    $Needles += "ocdiag_${Stamp}_${i}"
}

$ProbeMessages = $Needles | ForEach-Object {
    "$Mention diagnostic probe $_ please reply with exactly ACK $_"
}

Write-TextFile "probe-messages.txt" ($ProbeMessages -join [Environment]::NewLine)

Write-Section "Discord Probe"
Write-Host "Send these $ProbeCount messages in Discord as separate messages, 5-8 seconds apart:"
Write-Host ""
$ProbeMessages | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "Waiting $WaitSeconds seconds after you send them. Keep this PowerShell window open."
Start-Sleep -Seconds $WaitSeconds

$AfterSnapshot = Get-SessionFileSnapshot

Invoke-Capture "Changed Session Files" {
    $BeforeByPath = @{}
    foreach ($Item in $BeforeSnapshot) { $BeforeByPath[$Item.FullName] = $Item }
    $Changed = foreach ($Item in $AfterSnapshot) {
        $Before = $BeforeByPath[$Item.FullName]
        if ($null -eq $Before -or $Before.Length -ne $Item.Length -or $Before.LastWriteTimeUtc -ne $Item.LastWriteTimeUtc) {
            [pscustomobject]@{
                FullName = $Item.FullName
                BeforeLength = if ($Before) { $Before.Length } else { $null }
                AfterLength = $Item.Length
                LastWriteTimeUtc = $Item.LastWriteTimeUtc
            }
        }
    }
    $Changed | Sort-Object LastWriteTimeUtc -Descending | Format-Table -AutoSize
}

Invoke-Capture "Probe Search Results" {
    Search-ProbesInOpenClawFiles -Needles $Needles
}

Invoke-Capture "Probe Turn Summary" {
    Summarize-ProbeTurns -Needles $Needles
}

Invoke-Capture "Recent Session Tail" {
    if (-not (Test-Path $SessionsRoot)) {
        "Sessions root not found: $SessionsRoot"
        return
    }
    $Files = Get-ChildItem $SessionsRoot -Recurse -File -Include *.jsonl,*.trajectory.jsonl -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 8
    foreach ($File in $Files) {
        "---- $($File.FullName) ----"
        Get-Content $File.FullName -Tail 120 -ErrorAction SilentlyContinue |
            Select-String -Pattern "was_mentioned|inbound_event_kind|task_started|task_complete|agent_message|NO_REPLY|error|rate_limit|message_id|sender|diagnostic probe|ocdiag_|ACK" -CaseSensitive:$false |
            ForEach-Object { $_.Line }
        ""
    }
}

Invoke-Capture "OpenClaw Log File Inventory" {
    $Roots = @($OpenClawRoot, (Join-Path $OpenClawRoot "logs")) | Where-Object { Test-Path $_ } | Select-Object -Unique
    foreach ($Root in $Roots) {
        "-- $Root --"
        Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 50MB -and ($_.Name -match "\.log$|\.jsonl$|gateway|discord|error|stdout|stderr") } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 60 FullName, LastWriteTime, Length |
            Format-Table -AutoSize
    }
}

Write-TextFile "README.txt" @"
OpenClaw-only Discord intermittent-response diagnostic.

This diagnostic does not require or test the PersonalAssistant Python service.

Inspect first:
- OpenClaw_Status.txt
- OpenClaw_Doctor.txt
- OpenClaw_Config_Redacted.txt
- Probe_Search_Results.txt
- Probe_Turn_Summary.txt
- Recent_Session_Tail.txt
- Changed_Session_Files.txt
"@

Stop-Transcript | Out-Null
Sanitize-DiagnosticFiles -Path $RunDir

if ($PushToGitHub) {
    Write-Host ""
    Write-Host "==== GitHub Upload ===="
    Push-Location $RepoRoot
    try {
        git add -- "diagnostics/$SafeComputer-openclaw-discord-$Stamp"
        git commit -m "Add OpenClaw Discord intermittent diagnostic $SafeComputer $Stamp"
        git push origin HEAD:master
    } finally {
        Pop-Location
    }
} else {
    Write-Host "Diagnostic bundle written to $RunDir"
}
