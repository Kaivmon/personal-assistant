# Architecture

## Runtime Topology

- Discord is the user interface.
- OpenClaw owns Discord, conversation context, provider routing, OAuth to ChatGPT Plus, skill execution, and future integrations.
- `personal-assistant` is a local HTTP skill service for note taking, deterministic retrieval, SQL analytics, and temporary Markdown generation.
- SQLite is the source of truth.
- Markdown reports are regenerated from SQLite and deleted after roughly two hours.
- Ollama runs only on the Beelink and is reachable only from the Windows Server LAN.

## Components

- `personal_assistant.service`: HTTP endpoints for OpenClaw.
- `personal_assistant.assistant`: intent handling for log, query, stats, and report flows.
- `personal_assistant.parser`: deterministic natural-language note parser and classifier.
- `personal_assistant.db`: SQLite schema and persistence.
- `personal_assistant.analytics`: deterministic SQL summaries.
- `personal_assistant.reports`: Obsidian-compatible Markdown generation and cleanup.
- `personal_assistant.model_router`: usage warning and fallback decision helper for OpenClaw routing.

## Data Model

`notes` stores:

- `timestamp`
- `category`
- `event_type`
- `subject`
- `quantity`
- `units`
- `original_message`
- `parsed_values`
- `confidence`

## Provider Policy

Primary provider is ChatGPT Plus through OpenClaw OAuth. OpenAI API keys are intentionally unsupported. When usage estimates hit zero, routing moves to Ollama. Warning thresholds are 20 and 5 estimated remaining requests.

