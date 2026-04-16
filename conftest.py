"""Shared pytest fixtures for the eval framework."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, AsyncGenerator, Callable, Coroutine

import httpx
import pytest
import yaml

from harness.runner import EvalResult, TaskConfig, run_task

try:
    from harness.mlflow_client import MLflowTraceClient
except ImportError:
    MLflowTraceClient = None  # type: ignore[misc,assignment]


def pytest_report_header(config: pytest.Config) -> list[str]:
    """Display the target agent URL and MLflow experiment at the top of the test session."""
    lines = []
    urls = []
    for var in ("AGENT_URL", "REACT_AGENT_URL", "RAG_AGENT_URL", "MCP_AGENT_URL"):
        val = os.environ.get(var)
        if val:
            urls.append(f"{var}={val}")
    if not urls:
        urls.append("AGENT_URL=http://localhost:8000 (default)")
    lines.append(f"agent targets: {', '.join(urls)}")

    experiment = os.environ.get("MLFLOW_EXPERIMENT_NAME")
    tracking_uri = os.environ.get("MLFLOW_TRACKING_URI")
    if experiment and tracking_uri:
        lines.append(f"mlflow: {tracking_uri} experiment={experiment}")

    return lines


@pytest.fixture
def agent_url() -> str:
    """Agent base URL from AGENT_URL env var or default localhost:8000."""
    return os.environ.get("AGENT_URL", "http://localhost:8000")


@pytest.fixture
def eval_config() -> dict[str, Any]:
    """Load threshold configuration from configs/thresholds.yaml."""
    config_path = Path(__file__).parent / "configs" / "thresholds.yaml"
    with open(config_path) as f:
        return yaml.safe_load(f)


@pytest.fixture
async def http_client() -> AsyncGenerator[httpx.AsyncClient, None]:
    """Provide an async httpx client that is closed after the test."""
    async with httpx.AsyncClient() as client:
        yield client


@pytest.fixture
def run_eval(
    agent_url: str, http_client: httpx.AsyncClient
) -> Callable[..., Coroutine[Any, Any, EvalResult]]:
    """Convenience fixture that wraps run_task with the session's agent URL and client.

    Usage in tests:
        async def test_something(run_eval):
            result = await run_eval("What is the weather in Denver?")
            assert result.success
    """

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
        return await run_task(config, client=http_client)

    return _run


@pytest.fixture
def mlflow_client() -> "MLflowTraceClient | None":
    """Provide an MLflow trace client if configured via env vars.

    Set MLFLOW_TRACKING_URI and MLFLOW_EXPERIMENT_NAME to enable.
    Returns None if mlflow is not installed or env vars are not set.
    """
    if MLflowTraceClient is None:
        return None
    tracking_uri = os.environ.get("MLFLOW_TRACKING_URI")
    experiment_name = os.environ.get("MLFLOW_EXPERIMENT_NAME")
    if not tracking_uri or not experiment_name:
        return None
    return MLflowTraceClient(tracking_uri, experiment_name)
