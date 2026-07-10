# Deployment

There is exactly one deployment script per machine:

- `Deploy-Server.ps1` for Windows Server 2025.
- `Deploy-Beelink.ps1` for the Beelink.

## Windows Server 2025

Run PowerShell as Administrator:

```powershell
.\Deploy-Server.ps1
```

The script installs Git, Python, and NSSM if needed, clones or fast-forwards `https://github.com/Kaivmon/personal-assistant.git`, clones or fast-forwards OpenClaw, configures Ollama at `http://172.19.96.1:11434`, creates SQLite, installs the assistant as a Windows Service, starts it immediately, verifies `/health`, and verifies the Beelink Ollama connection.

Service logs are written to:

```text
C:\PersonalAssistant\logs\service.log
C:\PersonalAssistant\logs\service.err.log
```

After deployment, edit `C:\PersonalAssistant\.env` with Discord and OpenClaw OAuth settings, then restart:

```powershell
Restart-Service PersonalAssistant
```

## Beelink

Run PowerShell as Administrator on the Beelink:

```powershell
.\Deploy-Beelink.ps1 -Model "llama3.1:8b"
```

The script installs Ollama, configures LAN binding, opens the Windows firewall port, registers automatic startup, starts Ollama, pulls the model, performs a health check, and prints the server connection URL.

The Windows Server deployment currently expects the Beelink connection URL to be:

```text
http://172.19.96.1:11434
```

If that address is not reachable from the Windows Server, find the Beelink address on the adapter with a default gateway:

```powershell
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -ExpandProperty IPv4Address
```

Then rerun server deployment with:

```powershell
.\Deploy-Server.ps1 -OllamaBaseUrl "http://BEELINK-LAN-IP:11434"
```

If you need to finish the Windows Server deployment before fixing Ollama connectivity:

```powershell
.\Deploy-Server.ps1 -SkipOllamaHealthCheck
```

## Troubleshooting

On the Windows Server, run:

```powershell
cd C:\PersonalAssistant\app
.\Troubleshoot-Server.ps1
```

The script checks the assistant service, local health endpoints, key environment variables with secrets masked, Node/npm/OpenClaw command availability, likely OpenClaw config paths, OpenClaw status commands, and recent assistant service logs.

To prove whether Discord messages are actually reaching the Personal Assistant SQLite-backed service, run:

```powershell
cd C:\PersonalAssistant\app
.\Test-DiscordAssistantPath.ps1
```

The script prints a unique message to send in Discord, waits for it to appear in SQLite, and reports whether the full Discord -> OpenClaw -> PersonalAssistant path is working.

If Discord replies but the probe does not appear in SQLite, run:

```powershell
cd C:\PersonalAssistant\app
.\Repair-OpenClawDiscordConfig.ps1 -RestartGateway
```

Then rerun `Test-DiscordAssistantPath.ps1`. This repair script backs up `~\.openclaw\openclaw.json`, opens Discord group routing by setting `channels.discord.groupPolicy` to `open`, installs the local Personal Assistant OpenClaw plugin, runs `openclaw doctor --fix`, and inspects the plugin runtime.
