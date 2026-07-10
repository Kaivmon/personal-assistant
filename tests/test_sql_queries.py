import shutil
from pathlib import Path

from personal_assistant.analytics import category_counts, quantity_stats
from personal_assistant.db import connect, initialize, insert_note, search_notes
from personal_assistant.parser import parse_note


def test_sql_insert_search_and_analytics() -> None:
    runtime = Path(__file__).parent / "_runtime" / "sql"
    shutil.rmtree(runtime, ignore_errors=True)
    runtime.mkdir(parents=True)
    db_path = runtime / "assistant.sqlite3"
    with connect(db_path) as conn:
        initialize(conn)
        insert_note(conn, parse_note("I spent $10 on lunch"))
        insert_note(conn, parse_note("I spent $5 on coffee"))
        insert_note(conn, parse_note("I walked 2 miles"))

        results = search_notes(conn, "coffee")
        counts = category_counts(conn)
        stats = quantity_stats(conn, "finance")

    assert len(results) == 1
    assert results[0]["subject"] == "coffee"
    assert any(row["category"] == "finance" and row["count"] == 2 for row in counts)
    assert stats[0]["total"] == 15
    shutil.rmtree(runtime, ignore_errors=True)
