# Deployment

There is exactly one deployment script per machine:

- `Deploy-Server.ps1` for Windows Server 2025.
- `Deploy-Beelink.ps1` for the Beelink.

## Windows Server 2025

Run PowerShell as Administrator:

```powershell
.\Deploy-Server.ps1 -RepoUrl "https://github.com/YOUR-USER/personal-assistant.git" -OllamaBaseUrl "http://BEELINK-LAN-IP:11434"
```

The script installs Git and Python if needed, clones the app, clones OpenClaw, creates SQLite, installs the assistant as a Windows Service, starts it immediately, and verifies `/health`.

After deployment, edit `C:\PersonalAssistant\.env` with Discord and OpenClaw OAuth settings, then restart:

```powershell
Restart-Service PersonalAssistant
```

## Beelink

Run PowerShell as Administrator on the Beelink:

```powershell
.\Deploy-Beelink.ps1 -Model "llama3.1:8b"
```

The script installs Ollama, configures LAN binding, registers automatic startup, starts Ollama, pulls the model, performs a health check, and prints the server connection URL.

