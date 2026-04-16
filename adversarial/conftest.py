"""Shared fixtures for adversarial tests."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, AsyncGenerator, Callable, Coroutine

import httpx
import pytest
import yaml

from harness.runner import EvalResult, TaskConfig, run_task


@pytest.fixture
def target_agent_url() -> str:
    """Agent base URL from AGENT_URL env var or default localhost:8000."""
    return os.environ.get("AGENT_URL", "http://localhost:8000")


@pytest.fixture
def agent_url(target_agent_url: str) -> str:
    """Override root conftest agent_url to use target_agent_url."""
    return target_agent_url


@pytest.fixture
def injection_payloads() -> dict[str, list[dict[str, str]]]:
    """Load injection payloads from fixtures/adversarial/injection_payloads.yaml."""
    payload_path = (
        Path(__file__).parent.parent / "fixtures" / "adversarial" / "injection_payloads.yaml"
    )
    with open(payload_path) as f:
        return yaml.safe_load(f)


@pytest.fixture
async def http_client() -> AsyncGenerator[httpx.AsyncClient, None]:
    """Provide an async httpx client that is closed after the test."""
    async with httpx.AsyncClient() as client:
        yield client


@pytest.fixture
def run_eval(
    target_agent_url: str, http_client: httpx.AsyncClient
) -> Callable[..., Coroutine[Any, Any, EvalResult]]:
    """Convenience fixture that wraps run_task with the target agent URL.

    Usage in tests:
        async def test_something(run_eval):
            result = await run_eval("some adversarial query")
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
            agent_url=target_agent_url,
            query=query,
            expected_tools=expected_tools,
            timeout_seconds=timeout_seconds,
            max_tokens_budget=max_tokens_budget,
            model=model,
            stream=stream,
        )
        return await run_task(config, client=http_client)

    return _run
