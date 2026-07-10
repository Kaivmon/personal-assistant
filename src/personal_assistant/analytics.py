from __future__ import annotations

import sqlite3
from typing import Any


def category_counts(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT category, COUNT(*) AS count
        FROM notes
        GROUP BY category
        ORDER BY count DESC, category ASC
        """
    ).fetchall()
    return [dict(row) for row in rows]


def event_counts(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT event_type, COUNT(*) AS count
        FROM notes
        GROUP BY event_type
        ORDER BY count DESC, event_type ASC
        """
    ).fetchall()
    return [dict(row) for row in rows]


def quantity_stats(conn: sqlite3.Connection, category: str | None = None) -> list[dict[str, Any]]:
    if category:
        rows = conn.execute(
            """
            SELECT category, units, COUNT(quantity) AS samples, SUM(quantity) AS total, AVG(quantity) AS average
            FROM notes
            WHERE quantity IS NOT NULL AND category = ?
            GROUP BY category, units
            ORDER BY category ASC, units ASC
            """,
            (category,),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT category, units, COUNT(quantity) AS samples, SUM(quantity) AS total, AVG(quantity) AS average
            FROM notes
            WHERE quantity IS NOT NULL
            GROUP BY category, units
            ORDER BY category ASC, units ASC
            """
        ).fetchall()
    return [dict(row) for row in rows]


def deterministic_summary(conn: sqlite3.Connection) -> dict[str, list[dict[str, Any]]]:
    return {
        "category_counts": category_counts(conn),
        "event_counts": event_counts(conn),
        "quantity_stats": quantity_stats(conn),
    }

