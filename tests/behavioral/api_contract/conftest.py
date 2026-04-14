"""Fixtures for API contract tests.

These tests are agent-agnostic — they verify the FastAPI
application contract that all agents in agentic-starter-kits share.
Set AGENT_URL to target any deployed agent.
"""

from __future__ import annotations

import os
from typing import Any, AsyncGenerator

import httpx
import pytest


@pytest.fixture
def agent_url() -> str:
    return os.environ.get("AGENT_URL", "http://localhost:8000")


@pytest.fixture
async def http_client() -> AsyncGenerator[httpx.AsyncClient, None]:
    async with httpx.AsyncClient() as client:
        yield client
