from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import analytics, db
from .model_router import choose_provider
from .parser import parse_note
from .reports import cleanup_old_reports, generate_markdown_report


REPORT_WORDS = {"report", "markdown", "obsidian", "export"}
QUERY_WORDS = {"show", "find", "retrieve", "what", "list", "search"}
STATS_WORDS = {"stats", "statistics", "total", "average", "count", "analytics"}


class Assistant:
    def __init__(self, db_path: Path, report_dir: Path, report_ttl_seconds: int) -> None:
        self.db_path = db_path
        self.report_dir = report_dir
        self.report_ttl_seconds = report_ttl_seconds

    def handle_message(self, message: str) -> dict[str, Any]:
        request_timestamp = datetime.now(timezone.utc).isoformat()
        with db.connect(self.db_path) as conn:
            db.initialize(conn)
            cleanup_old_reports(self.report_dir, self.report_ttl_seconds)
            intent = classify_intent(message)
            if intent == "report":
                path = generate_markdown_report(conn, self.report_dir, message, request_timestamp)
                return {"intent": intent, "reply": f"Generated temporary Markdown report: {path}", "report_path": str(path)}
            if intent == "stats":
                summary = analytics.deterministic_summary(conn)
                return {"intent": intent, "reply": format_summary(summary), "data": summary}
            if intent == "query":
                rows = db.search_notes(conn, message)
                return {"intent": intent, "reply": format_rows(rows), "data": rows}
            note = parse_note(message)
            note_id = db.insert_note(conn, note)
            return {
                "intent": "log",
                "reply": f"Logged note #{note_id}: {note.category} / {note.event_type} / {note.subject}",
                "note_id": note_id,
                "note": note.__dict__,
            }

    def provider_status(self, limit_per_window: int, used_in_window: int, warn_remaining: tuple[int, ...]) -> dict[str, Any]:
        decision = choose_provider(limit_per_window, used_in_window, warn_remaining)
        with db.connect(self.db_path) as conn:
            db.initialize(conn)
            db.record_usage(conn, decision.provider, limit_per_window, used_in_window)
        return decision.__dict__


def classify_intent(message: str) -> str:
    words = set(message.lower().split())
    if words & REPORT_WORDS:
        return "report"
    if words & STATS_WORDS:
        return "stats"
    if words & QUERY_WORDS:
        return "query"
    return "log"


def format_rows(rows: list[dict[str, Any]]) -> str:
    if not rows:
        return "No matching notes found."
    return "\n".join(
        f"- {row['timestamp']} | {row['category']} | {row['event_type']} | {row['subject']}" for row in rows
    )


def format_summary(summary: dict[str, list[dict[str, Any]]]) -> str:
    category_parts = [f"{row['category']}={row['count']}" for row in summary["category_counts"]]
    event_parts = [f"{row['event_type']}={row['count']}" for row in summary["event_counts"]]
    return f"Categories: {', '.join(category_parts) or 'none'}\nEvents: {', '.join(event_parts) or 'none'}"

