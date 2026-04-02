"""Fixtures for Agentic RAG agent evals."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest
import yaml


@pytest.fixture
def agent_url() -> str:
    """RAG agent URL from RAG_AGENT_URL env var or default localhost:8001."""
    return os.environ.get("RAG_AGENT_URL", "http://localhost:8001")


@pytest.fixture
def known_tools() -> list[str]:
    """Tools available on the Agentic RAG agent."""
    return ["retriever"]


@pytest.fixture
def rag_thresholds() -> dict[str, Any]:
    """Load the agentic_rag section from thresholds.yaml."""
    config_path = Path(__file__).parent.parent.parent / "configs" / "thresholds.yaml"
    with open(config_path) as f:
        data = yaml.safe_load(f)
    return data["agentic_rag"]
