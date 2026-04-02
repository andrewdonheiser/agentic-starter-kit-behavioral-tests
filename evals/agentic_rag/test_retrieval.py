"""Retrieval evals for the Agentic RAG agent.

Validates that the agent correctly decides when to invoke the
``retriever`` tool and when to respond directly. The RAG agent
workflow is: receive query -> decide -> retrieve -> generate.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

pytestmark = pytest.mark.langgraph_rag
import yaml

from harness.scorers.tool_sequence import (
    score_hallucinated_tools,
    score_tool_selection,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_golden(category: str | None = None) -> list[dict[str, Any]]:
    """Load golden queries for the RAG agent."""
    path = Path(__file__).parent.parent.parent / "fixtures" / "agentic_rag" / "golden_queries.yaml"
    with open(path) as f:
        data = yaml.safe_load(f)
    queries = data.get("queries", [])
    if category:
        queries = [q for q in queries if q.get("category") == category]
    return queries


def _knowledge_queries() -> list[dict[str, Any]]:
    """Queries that should trigger retrieval."""
    return [q for q in _load_golden() if q.get("expected_tools")]


def _greeting_queries() -> list[dict[str, Any]]:
    return _load_golden(category="greeting")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_retriever_tool_called(run_eval: Any) -> None:
    """A domain-specific query should trigger the retriever tool."""
    result = await run_eval(
        "How do I deploy a model using Llama Stack?",
        expected_tools=["retriever"],
    )
    assert result.success, f"Agent request failed: {result.error}"
    tool_names = [tc["name"] for tc in result.tool_calls]
    assert "retriever" in tool_names, (
        f"Expected 'retriever' tool call, got: {tool_names}"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "golden",
    _knowledge_queries(),
    ids=lambda q: q["query"][:60],
)
async def test_retrieval_for_knowledge_query(
    run_eval: Any, golden: dict[str, Any], known_tools: list[str]
) -> None:
    """Domain-specific knowledge queries should trigger retrieval."""
    result = await run_eval(
        golden["query"],
        expected_tools=golden["expected_tools"],
    )
    assert result.success, f"Agent request failed: {result.error}"
    score = score_tool_selection(result, golden["expected_tools"])
    assert score.passed, (
        f"Tool selection failed for '{golden['query'][:50]}': {score.details}"
    )
    # Also verify no hallucinated tools
    h_score = score_hallucinated_tools(result, known_tools)
    assert h_score.passed, (
        f"Hallucinated tools: {h_score.details.get('hallucinated')}"
    )


@pytest.mark.asyncio
async def test_no_retrieval_for_greeting(run_eval: Any) -> None:
    """Simple greetings should not trigger the retriever tool."""
    result = await run_eval("Hello")
    assert result.success, f"Agent request failed: {result.error}"
    assert len(result.tool_calls) == 0, (
        f"Greeting should not trigger retrieval, "
        f"but got: {[tc['name'] for tc in result.tool_calls]}"
    )
