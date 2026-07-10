from __future__ import annotations

import json
import sqlite3
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .parser import ParsedNote

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    category TEXT NOT NULL,
    event_type TEXT NOT NULL,
    subject TEXT NOT NULL,
    quantity REAL,
    units TEXT,
    original_message TEXT NOT NULL,
    parsed_values TEXT NOT NULL,
    confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1)
);
CREATE INDEX IF NOT EXISTS idx_notes_timestamp ON notes(timestamp);
CREATE INDEX IF NOT EXISTS idx_notes_category ON notes(category);
CREATE INDEX IF NOT EXISTS idx_notes_event_type ON notes(event_type);
CREATE INDEX IF NOT EXISTS idx_notes_subject ON notes(subject);

CREATE TABLE IF NOT EXISTS provider_usage (
    provider TEXT PRIMARY KEY,
    limit_per_window INTEGER,
    used_in_window INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);
"""


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


def insert_note(conn: sqlite3.Connection, note: ParsedNote) -> int:
    values = asdict(note)
    parsed_values = json.dumps(values["parsed_values"], sort_keys=True)
    cur = conn.execute(
        """
        INSERT INTO notes (
            timestamp, category, event_type, subject, quantity, units,
            original_message, parsed_values, confidence
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            note.timestamp,
            note.category,
            note.event_type,
            note.subject,
            note.quantity,
            note.units,
            note.original_message,
            parsed_values,
            note.confidence,
        ),
    )
    conn.commit()
    return int(cur.lastrowid)


def search_notes(conn: sqlite3.Connection, query: str, limit: int = 10) -> list[dict[str, Any]]:
    like = f"%{query.lower()}%"
    rows = conn.execute(
        """
        SELECT * FROM notes
        WHERE lower(category) LIKE ?
           OR lower(event_type) LIKE ?
           OR lower(subject) LIKE ?
           OR lower(original_message) LIKE ?
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        (like, like, like, like, limit),
    ).fetchall()
    return [dict(row) for row in rows]


def record_usage(conn: sqlite3.Connection, provider: str, limit_per_window: int | None, used: int) -> None:
    conn.execute(
        """
        INSERT INTO provider_usage(provider, limit_per_window, used_in_window, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(provider) DO UPDATE SET
            limit_per_window = excluded.limit_per_window,
            used_in_window = excluded.used_in_window,
            updated_at = excluded.updated_at
        """,
        (provider, limit_per_window, used, datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()

