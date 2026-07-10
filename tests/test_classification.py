from personal_assistant.assistant import classify_intent
from personal_assistant.model_router import choose_provider
from personal_assistant.parser import classify_category, classify_event


def test_classifies_category_and_event() -> None:
    assert classify_category("i had a meeting about the project")[0] == "work"
    assert classify_event("I walked 3 miles")[0] == "measurement"


def test_intent_detection() -> None:
    assert classify_intent("generate markdown report for this week") == "report"
    assert classify_intent("show coffee notes") == "query"
    assert classify_intent("average spending stats") == "stats"
    assert classify_intent("I slept 7 hours") == "log"


def test_model_router_warns_and_falls_back() -> None:
    warning = choose_provider(80, 60, (20, 5))
    assert warning.provider == "chatgpt_plus_openclaw"
    assert warning.warnings == ("ChatGPT Plus estimated remaining requests: 20",)

    fallback = choose_provider(80, 80, (20, 5))
    assert fallback.provider == "ollama"
    assert "without API credits" in fallback.reason

