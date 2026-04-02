"""Prompt regression testing infrastructure.

Provides tools for comparing eval scores across prompt versions,
saving baselines, and detecting regressions.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from harness.scorers import Score


@dataclass
class PromptVersion:
    """Represents a versioned prompt for regression tracking."""

    version: str
    prompt_text: str
    model: str
    timestamp: str


@dataclass
class RegressionResult:
    """Result of comparing a metric between two prompt versions."""

    current_version: str
    baseline_version: str
    metric_name: str
    current_value: float
    baseline_value: float
    regression: bool
    delta: float


def compare_versions(
    current_scores: list[Score],
    baseline_scores: list[Score],
    threshold: float = 0.05,
) -> list[RegressionResult]:
    """Compare current scores against a baseline and detect regressions.

    A regression is detected when the current score drops below the
    baseline by more than the threshold amount.

    Args:
        current_scores: Scores from the current prompt version.
        baseline_scores: Scores from the baseline prompt version.
        threshold: Maximum acceptable decline before flagging a regression.
            Defaults to 0.05 (5 percentage points).

    Returns:
        List of RegressionResult for each metric present in both score sets.
    """
    baseline_map: dict[str, Score] = {s.name: s for s in baseline_scores}
    current_map: dict[str, Score] = {s.name: s for s in current_scores}

    results: list[RegressionResult] = []

    # Compare all metrics present in either set
    all_metrics = set(baseline_map.keys()) | set(current_map.keys())

    for metric in sorted(all_metrics):
        current_score = current_map.get(metric)
        baseline_score = baseline_map.get(metric)

        if current_score is None or baseline_score is None:
            # Metric missing from one side -- report but don't flag as regression
            results.append(
                RegressionResult(
                    current_version="current",
                    baseline_version="baseline",
                    metric_name=metric,
                    current_value=current_score.value if current_score else 0.0,
                    baseline_value=baseline_score.value if baseline_score else 0.0,
                    regression=False,
                    delta=(
                        (current_score.value if current_score else 0.0)
                        - (baseline_score.value if baseline_score else 0.0)
                    ),
                )
            )
            continue

        delta = current_score.value - baseline_score.value
        regression = delta < -threshold

        results.append(
            RegressionResult(
                current_version="current",
                baseline_version="baseline",
                metric_name=metric,
                current_value=current_score.value,
                baseline_value=baseline_score.value,
                regression=regression,
                delta=delta,
            )
        )

    return results


def save_baseline(
    scores: list[Score],
    version: PromptVersion,
    output_path: str | Path,
) -> None:
    """Save scores as a JSON baseline file.

    Args:
        scores: List of Score objects to persist.
        version: The prompt version metadata.
        output_path: Path to write the JSON baseline file.
    """
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    data: dict[str, Any] = {
        "version": asdict(version),
        "scores": [asdict(s) for s in scores],
    }

    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)


def load_baseline(baseline_path: str | Path) -> tuple[PromptVersion, list[Score]]:
    """Load a previously saved baseline.

    Args:
        baseline_path: Path to the JSON baseline file.

    Returns:
        Tuple of (PromptVersion, list of Score objects).

    Raises:
        FileNotFoundError: If the baseline file does not exist.
        KeyError: If the baseline file is malformed.
    """
    baseline_path = Path(baseline_path)

    with open(baseline_path) as f:
        data = json.load(f)

    version = PromptVersion(**data["version"])
    scores = [
        Score(
            name=s["name"],
            value=s["value"],
            passed=s["passed"],
            details=s.get("details", {}),
        )
        for s in data["scores"]
    ]

    return version, scores
