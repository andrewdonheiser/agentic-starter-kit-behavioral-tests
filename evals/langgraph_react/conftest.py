"""Fixtures for LangGraph React agent evals."""

from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any, Callable, Coroutine

import httpx
import pytest
import yaml

from harness.runner import EvalResult, TaskConfig, run_task

try:
    from harness.mlflow_client import MLflowTraceClient
except ImportError:
    MLflowTraceClient = None  # type: ignore[misc,assignment]


@pytest.fixture
def agent_url() -> str:
    """React agent URL from REACT_AGENT_URL env var or default localhost:8000."""
    return os.environ.get("REACT_AGENT_URL", "http://localhost:8000")


@pytest.fixture
def known_tools() -> list[str]:
    """Tools available on the LangGraph React agent."""
    return ["search"]


@pytest.fixture
def react_thresholds() -> dict[str, Any]:
    """Load the langgraph_react section from thresholds.yaml."""
    config_path = Path(__file__).parent.parent.parent / "configs" / "thresholds.yaml"
    with open(config_path) as f:
        data = yaml.safe_load(f)
    return data["langgraph_react"]


@pytest.fixture
def run_eval(
    agent_url: str, http_client: httpx.AsyncClient
) -> Callable[..., Coroutine[Any, Any, EvalResult]]:
    """Run eval with automatic MLflow enrichment when available.

    Overrides the root run_eval fixture to add MLflow trace data
    (tool calls, token usage) after each request.
    """
    mlflow = None
    if MLflowTraceClient is not None:
        tracking_uri = os.environ.get("MLFLOW_TRACKING_URI")
        experiment = os.environ.get("MLFLOW_EXPERIMENT_NAME")
        if tracking_uri and experiment:
            mlflow = MLflowTraceClient(tracking_uri, experiment)

    async def _run(
        query: str,
        expected_tools: list[str] | None = None,
        timeout_seconds: float = 30.0,
        max_tokens_budget: int | None = None,
        model: str | None = None,
        stream: bool = False,
    ) -> EvalResult:
        config = TaskConfig(
            agent_url=agent_url,
            query=query,
            expected_tools=expected_tools,
            timeout_seconds=timeout_seconds,
            max_tokens_budget=max_tokens_budget,
            model=model,
            stream=stream,
        )
        # Record timestamp before request so we can filter stale traces
        request_start_ms = int(time.time() * 1000)
        result = await run_task(config, client=http_client)

        # Enrich with MLflow trace data if available
        if mlflow is not None and result.success:
            mlflow.enrich_eval_result(result, since_ms=request_start_ms)

        return result

    return _run
