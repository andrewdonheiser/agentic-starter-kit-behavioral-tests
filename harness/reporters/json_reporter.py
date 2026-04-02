"""JSON file reporter for eval scores and results."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harness.runner import EvalResult
from harness.scorers import Score


def write_json_report(
    scores: list[Score],
    output_path: str,
    results: list[EvalResult] | None = None,
) -> None:
    """Write a JSON report of scores and optional results to a file.

    Creates parent directories if they do not exist.
    """
    report: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": _build_summary(scores),
        "scores": [_score_to_dict(s) for s in scores],
    }

    if results is not None:
        report["results"] = [_result_to_dict(r) for r in results]

    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(report, f, indent=2, default=str)


def _build_summary(scores: list[Score]) -> dict[str, Any]:
    """Compute summary statistics across all scores."""
    if not scores:
        return {"total": 0, "passed": 0, "failed": 0, "pass_rate": 0.0}

    passed = sum(1 for s in scores if s.passed)
    return {
        "total": len(scores),
        "passed": passed,
        "failed": len(scores) - passed,
        "pass_rate": passed / len(scores),
        "average_value": sum(s.value for s in scores) / len(scores),
    }


def _score_to_dict(score: Score) -> dict[str, Any]:
    """Convert a Score dataclass to a JSON-serializable dict."""
    return {
        "name": score.name,
        "value": score.value,
        "passed": score.passed,
        "details": score.details,
    }


def _result_to_dict(result: EvalResult) -> dict[str, Any]:
    """Convert an EvalResult to a JSON-serializable dict (excluding raw_response)."""
    return {
        "success": result.success,
        "response_length": len(result.response),
        "tool_calls_count": len(result.tool_calls),
        "latency_seconds": result.latency_seconds,
        "tokens_used": result.tokens_used,
        "error": result.error,
    }
