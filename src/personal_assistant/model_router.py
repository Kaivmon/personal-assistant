from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ProviderDecision:
    provider: str
    remaining_estimate: int | None
    warnings: tuple[str, ...]
    reason: str


def choose_provider(limit_per_window: int, used_in_window: int, warn_remaining: tuple[int, ...]) -> ProviderDecision:
    remaining = max(limit_per_window - used_in_window, 0)
    warnings = tuple(
        f"ChatGPT Plus estimated remaining requests: {remaining}"
        for threshold in sorted(warn_remaining, reverse=True)
        if remaining == threshold
    )
    if remaining <= 0:
        return ProviderDecision(
            provider="ollama",
            remaining_estimate=0,
            warnings=warnings,
            reason="ChatGPT Plus usage limit reached; using Ollama fallback without API credits.",
        )
    return ProviderDecision(
        provider="chatgpt_plus_openclaw",
        remaining_estimate=remaining,
        warnings=warnings,
        reason="Primary provider available through OpenClaw OAuth.",
    )

