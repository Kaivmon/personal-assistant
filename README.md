# Personal Assistant

Self-hosted personal AI assistant MVP using OpenClaw for Discord, conversation management, model routing, skill execution, and future extensibility.

The MVP implements intelligent note taking:

- Accepts natural-language Discord requests through OpenClaw.
- Stores structured records in SQLite.
- Retrieves notes naturally.
- Runs deterministic statistics with SQL.
- Generates temporary Obsidian-compatible Markdown reports on request.
- Uses ChatGPT Plus through OpenClaw OAuth first.
- Falls back to Ollama on the Beelink when ChatGPT Plus usage is exhausted.
- Never configures OpenAI API keys or paid API fallback.

## Quick Start

```powershell
cd personal-assistant
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .[test]
.\.venv\Scripts\personal-assistant.exe init-db
.\.venv\Scripts\personal-assistant.exe serve
```

Health check:

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health
```

Log a note:

```powershell
.\.venv\Scripts\personal-assistant.exe message "I spent $12 on coffee"
```

## OpenClaw

Install the native local OpenClaw plugin from `openclaw-plugin/personal-assistant`. The repair helper does this automatically:

```powershell
.\Repair-OpenClawDiscordConfig.ps1 -RestartGateway
```

The plugin registers a `personal_assistant` tool that calls the local service at `http://127.0.0.1:8765`.
