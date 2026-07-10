import os
import shutil
import time
from pathlib import Path

from personal_assistant.db import connect, initialize, insert_note
from personal_assistant.parser import parse_note
from personal_assistant.reports import cleanup_old_reports, generate_markdown_report


def test_report_generation_and_cleanup() -> None:
    runtime = Path(__file__).parent / "_runtime" / "reports"
    shutil.rmtree(runtime, ignore_errors=True)
    runtime.mkdir(parents=True)
    db_path = runtime / "assistant.sqlite3"
    report_dir = runtime / "reports"
    with connect(db_path) as conn:
        initialize(conn)
        insert_note(conn, parse_note("I slept 7 hours"))
        report = generate_markdown_report(conn, report_dir, "markdown report", "2026-07-09T00:00:00+00:00")

    content = report.read_text(encoding="utf-8")
    assert "generation_timestamp:" in content
    assert "request_timestamp:" in content
    assert "originating_query:" in content
    assert "# Personal Assistant Report" in content

    old_time = time.time() - 7201
    os.utime(report, (old_time, old_time))
    deleted = cleanup_old_reports(report_dir, 7200)

    assert deleted == [report]
    assert not report.exists()
    shutil.rmtree(runtime, ignore_errors=True)
