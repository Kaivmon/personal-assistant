from datetime import datetime, timezone

from personal_assistant.parser import parse_note


def test_parse_finance_expense() -> None:
    note = parse_note("Log that I spent $12.50 on coffee", datetime(2026, 7, 9, tzinfo=timezone.utc))

    assert note.category == "finance"
    assert note.event_type == "expense"
    assert note.quantity == 12.50
    assert note.units == "dollars"
    assert "coffee" in note.subject
    assert note.confidence >= 0.7


def test_parse_health_measurement() -> None:
    note = parse_note("record weight 182 lbs")

    assert note.category == "health"
    assert note.event_type == "measurement"
    assert note.quantity == 182
    assert note.units == "lbs"

