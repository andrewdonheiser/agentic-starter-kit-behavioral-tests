"""Configuration translation between EvalHub JobSpec and our TaskConfig."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from harness.runner import TaskConfig


@dataclass
class AgenticEvalParams:
    """Parameters parsed from JobSpec.parameters.

    These are agent-specific settings passed by the EvalHub job submitter,
    NOT baked into benchmark definitions. Benchmark definitions (scorer lists)
    are agent-agnostic, but query files contain agent-specific expected_tools.
    Only known_tools (for hallucination detection), thresholds, and forbidden
    actions come from job parameters.

    Example job submission parameters:
        {
            "known_tools": ["search"],
            "forbidden_actions": ["shell execution"],
            "max_latency_seconds": 8.0,
            "timeout_seconds": 30.0
        }
    """

    # Agent-specific
    known_tools: list[str] = field(default_factory=list)
    forbidden_actions: list[str] = field(default_factory=list)

    # Thresholds
    max_latency_seconds: float = 10.0
    tool_selection_threshold: float = 0.85
    coherence_threshold: float = 0.75

    # Execution
    timeout_seconds: float = 30.0
    pass_at_k: int = 1

    # MLflow trace enrichment (reads tool calls from agent-side traces)
    mlflow_tracking_uri: str | None = None
    mlflow_experiment_name: str | None = None

    @classmethod
    def from_dict(cls, params: dict[str, Any]) -> AgenticEvalParams:
        """Create from a dict, ignoring unknown keys."""
        known_fields = {f for f in cls.__dataclass_fields__}
        filtered = {k: v for k, v in params.items() if k in known_fields}
        return cls(**filtered)


def job_spec_to_task_config(
    agent_url: str,
    query: str,
    expected_tools: list[str] | None,
    params: AgenticEvalParams,
    model_name: str | None = None,
) -> TaskConfig:
    """Translate EvalHub job parameters into our TaskConfig."""
    return TaskConfig(
        agent_url=agent_url,
        query=query,
        expected_tools=expected_tools,
        timeout_seconds=params.timeout_seconds,
        model=model_name,
    )
