# Deployment

There is exactly one deployment script per machine:

- `Deploy-Server.ps1` for Windows Server 2025.
- `Deploy-Beelink.ps1` for the Beelink.

## Windows Server 2025

Run PowerShell as Administrator:

```powershell
.\Deploy-Server.ps1
```

The script installs Git and Python if needed, clones or fast-forwards `https://github.com/Kaivmon/personal-assistant.git`, clones or fast-forwards OpenClaw, configures Ollama at `http://172.19.96.1:11434`, creates SQLite, installs the assistant as a Windows Service, starts it immediately, verifies `/health`, and verifies the Beelink Ollama connection.

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
