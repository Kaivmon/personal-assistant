# Configuration

Configuration is environment-variable based. Start from `.env.example`.

## Required

- `OPENCLAW_DISCORD_BOT_TOKEN`: Discord bot token used by OpenClaw.
- `OPENCLAW_CHATGPT_OAUTH_PROFILE`: OpenClaw OAuth profile for ChatGPT Plus.
- `OLLAMA_BASE_URL`: Beelink Ollama URL, for example `http://192.168.1.50:11434`.
- `OLLAMA_MODEL`: local fallback model.

## Storage

- `ASSISTANT_DB_PATH`: SQLite database path.
- `ASSISTANT_REPORT_DIR`: temporary Markdown directory.
- `ASSISTANT_REPORT_TTL_SECONDS`: report cleanup age. Default is `7200`.

## Usage Monitoring

- `CHATGPT_USAGE_LIMIT_PER_WINDOW`: estimated ChatGPT Plus request window.
- `CHATGPT_USAGE_USED`: current usage estimate if OpenClaw does not provide live usage.
- `CHATGPT_WARN_REMAINING`: comma-separated warning thresholds. Default is `20,5`.

The MVP records provider usage estimates where available. It warns at configured thresholds and falls back to Ollama when the primary estimate reaches zero.

