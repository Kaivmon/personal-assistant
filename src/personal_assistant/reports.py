from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from .analytics import deterministic_summary


def generate_markdown_report(
    conn: sqlite3.Connection,
    report_dir: Path,
    originating_query: str,
    request_timestamp: str,
) -> Path:
    report_dir.mkdir(parents=True, exist_ok=True)
    generation_timestamp = datetime.now(timezone.utc).isoformat()
    path = report_dir / f"assistant-report-{generation_timestamp.replace(':', '').replace('.', '')}.md"
    summary = deterministic_summary(conn)
    recent = conn.execute(
        """
        SELECT timestamp, category, event_type, subject, quantity, units, confidence
        FROM notes
        ORDER BY timestamp DESC
        LIMIT 50
        """
    ).fetchall()
    lines = [
        "---",
        f"generation_timestamp: {generation_timestamp}",
        f"request_timestamp: {request_timestamp}",
        f"originating_query: {originating_query!r}",
        "temporary: true",
        "---",
        "",
        "# Personal Assistant Report",
        "",
        "## Category Counts",
        "",
    ]
    for row in summary["category_counts"]:
        lines.append(f"- {row['category']}: {row['count']}")
    lines.extend(["", "## Event Counts", ""])
    for row in summary["event_counts"]:
        lines.append(f"- {row['event_type']}: {row['count']}")
    lines.extend(["", "## Quantity Statistics", ""])
    for row in summary["quantity_stats"]:
        units = row["units"] or "unitless"
        lines.append(
            f"- {row['category']} / {units}: samples={row['samples']}, total={row['total']}, average={row['average']}"
        )
    lines.extend(["", "## Recent Notes", ""])
    for row in recent:
        amount = ""
        if row["quantity"] is not None:
            amount = f" ({row['quantity']} {row['units'] or ''})".rstrip()
        lines.append(
            f"- {row['timestamp']} | {row['category']} | {row['event_type']} | {row['subject']}{amount} | confidence={row['confidence']}"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def cleanup_old_reports(report_dir: Path, ttl_seconds: int) -> list[Path]:
    if not report_dir.exists():
        return []
    now = datetime.now(timezone.utc).timestamp()
    deleted: list[Path] = []
    for path in report_dir.glob("*.md"):
        age = now - path.stat().st_mtime
        if age >= ttl_seconds:
            path.unlink()
            deleted.append(path)
    return deleted

