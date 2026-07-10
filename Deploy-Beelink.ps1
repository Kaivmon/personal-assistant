param(
    [string]$Model = "llama3.1:8b",
    [int]$Port = 11434
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    winget install --id Ollama.Ollama --exact --silent --accept-package-agreements --accept-source-agreements
}

[Environment]::SetEnvironmentVariable("OLLAMA_HOST", "0.0.0.0:$Port", "Machine")
$env:OLLAMA_HOST = "0.0.0.0:$Port"

if (-not (Get-NetFirewallRule -DisplayName "Ollama LAN $Port" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Ollama LAN $Port" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
}

$TaskName = "Ollama LAN Server"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$Action = New-ScheduledTaskAction -Execute "ollama" -Argument "serve"
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal | Out-Null

$Existing = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if (-not $Existing) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
}

ollama pull $Model

$Health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tags" -Method GET
if (-not $Health.models) {
    throw "Ollama health check failed or no models are installed"
}

$Ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Select-Object -First 1 -ExpandProperty IPAddress)

Write-Host "Ollama is healthy."
Write-Host "Server connection URL: http://$Ip`:$Port"
Write-Host "Installed model: $Model"
