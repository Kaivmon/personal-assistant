from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any


@dataclass(frozen=True)
class ParsedNote:
    timestamp: str
    category: str
    event_type: str
    subject: str
    quantity: float | None
    units: str | None
    original_message: str
    parsed_values: dict[str, Any]
    confidence: float


CATEGORY_KEYWORDS = {
    "health": {"weight", "sleep", "slept", "run", "walk", "workout", "meds", "medicine", "pain"},
    "finance": {"spent", "paid", "bought", "earned", "invoice", "$", "dollars", "cost"},
    "work": {"meeting", "call", "shipped", "deployed", "bug", "task", "project"},
    "home": {"cleaned", "fixed", "laundry", "groceries", "maintenance"},
    "food": {"ate", "drank", "coffee", "breakfast", "lunch", "dinner", "calories"},
}

EVENT_PATTERNS = [
    ("expense", re.compile(r"\b(spent|paid|bought|cost)\b", re.I)),
    ("measurement", re.compile(r"\b(weight|weighed|miles|km|hours|minutes|calories|lbs|kg)\b", re.I)),
    ("activity", re.compile(r"\b(run|walk|workout|meeting|call|cleaned|fixed|deployed|shipped)\b", re.I)),
    ("consumption", re.compile(r"\b(ate|drank|coffee|breakfast|lunch|dinner|took meds)\b", re.I)),
]

QUANTITY_RE = re.compile(
    r"(?P<prefix>\$)?(?P<quantity>-?\d+(?:\.\d+)?)\s*(?P<units>hours?|hrs?|minutes?|mins?|miles?|mi|km|kilometers?|lbs?|pounds?|kg|calories|cal|dollars?)?",
    re.I,
)

FILLER_RE = re.compile(
    r"\b(log|note|record|remember|that|i|my|a|an|the|on|for|to|today|yesterday|just|please)\b",
    re.I,
)


def parse_note(message: str, now: datetime | None = None) -> ParsedNote:
    now = now or datetime.now(timezone.utc)
    clean = " ".join(message.strip().split())
    lowered = clean.lower()
    category, category_score = classify_category(lowered)
    event_type, event_score = classify_event(clean)
    quantity, units = extract_quantity(clean)
    subject = extract_subject(clean, quantity, units, event_type)
    confidence = min(0.98, 0.35 + category_score + event_score + (0.15 if subject else 0) + (0.1 if quantity is not None else 0))
    return ParsedNote(
        timestamp=now.isoformat(),
        category=category,
        event_type=event_type,
        subject=subject or "general note",
        quantity=quantity,
        units=units,
        original_message=message,
        parsed_values={
            "category_score": category_score,
            "event_score": event_score,
            "detected_quantity": quantity,
            "detected_units": units,
        },
        confidence=round(confidence, 2),
    )


def classify_category(lowered: str) -> tuple[str, float]:
    tokens = set(re.findall(r"[\w$]+", lowered))
    best = ("general", 0)
    for category, keywords in CATEGORY_KEYWORDS.items():
        score = len(tokens & keywords)
        if score > best[1]:
            best = (category, score)
    if best[1] == 0:
        return "general", 0.05
    return best[0], min(0.25, 0.12 + best[1] * 0.04)


def classify_event(message: str) -> tuple[str, float]:
    for event, pattern in EVENT_PATTERNS:
        if pattern.search(message):
            return event, 0.22
    return "note", 0.08


def extract_quantity(message: str) -> tuple[float | None, str | None]:
    match = QUANTITY_RE.search(message)
    if not match:
        return None, None
    quantity = float(match.group("quantity"))
    units = match.group("units")
    if match.group("prefix") == "$":
        units = "dollars"
    return quantity, units.lower() if units else None


def extract_subject(message: str, quantity: float | None, units: str | None, event_type: str) -> str:
    text = message
    if quantity is not None:
        text = QUANTITY_RE.sub(" ", text, count=1)
    text = FILLER_RE.sub(" ", text)
    for event, pattern in EVENT_PATTERNS:
        if event == event_type:
            text = pattern.sub(" ", text, count=1)
            break
    subject = " ".join(re.findall(r"[A-Za-z][A-Za-z0-9'-]*", text)).strip()
    return subject[:120]
