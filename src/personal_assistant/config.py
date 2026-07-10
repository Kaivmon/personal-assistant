from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    db_path: Path
    report_dir: Path
    report_ttl_seconds: int
    openclaw_base_url: str
    ollama_base_url: str
    ollama_model: str
    chatgpt_usage_limit: int
    chatgpt_usage_used: int
    warn_remaining: tuple[int, ...]

    @classmethod
    def from_env(cls) -> "Settings":
        report_dir = Path(os.getenv("ASSISTANT_REPORT_DIR", "data/reports"))
        return cls(
            host=os.getenv("ASSISTANT_HOST", "127.0.0.1"),
            port=int(os.getenv("ASSISTANT_PORT", "8765")),
            db_path=Path(os.getenv("ASSISTANT_DB_PATH", "data/assistant.sqlite3")),
            report_dir=report_dir,
            report_ttl_seconds=int(os.getenv("ASSISTANT_REPORT_TTL_SECONDS", "7200")),
            openclaw_base_url=os.getenv("OPENCLAW_BASE_URL", "http://127.0.0.1:3210"),
            ollama_base_url=os.getenv("OLLAMA_BASE_URL", "http://beelink:11434"),
            ollama_model=os.getenv("OLLAMA_MODEL", "llama3.1:8b"),
            chatgpt_usage_limit=int(os.getenv("CHATGPT_USAGE_LIMIT_PER_WINDOW", "80")),
            chatgpt_usage_used=int(os.getenv("CHATGPT_USAGE_USED", "0")),
            warn_remaining=tuple(int(x) for x in _csv(os.getenv("CHATGPT_WARN_REMAINING", "20,5"))),
        )

