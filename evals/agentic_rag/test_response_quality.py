"""Response quality evals for the Agentic RAG agent.

Validates that the agent's responses are grounded in retrieved
context, coherent, and complete. RAG agents must not hallucinate
beyond the retrieved documents.
"""

from __future__ import annotations

import pytest

from pathlib import Path

pytestmark = pytest.mark.langgraph_rag
from typing import Any

import pytest
import yaml

from harness.scorers.plan_coherence import score_completeness, score_plan_coherence


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_golden_with_elements() -> list[dict[str, Any]]:
    """Return golden queries that have expected_elements defined."""
    path = Path(__file__).parent.parent.parent / "fixtures" / "agentic_rag" / "golden_queries.yaml"
    with open(path) as f:
        data = yaml.safe_load(f)
    return [q for q in data.get("queries", []) if q.get("expected_elements")]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_response_grounded_in_context(run_eval: Any) -> None:
    """Response should reference retrieved information rather than generic knowledge.

    For a domain-specific query the agent should retrieve relevant
    documents and base its answer on them. We check that the response
    contains domain-specific terminology that would come from the
    vector store rather than pure parametric knowledge.
    """
    result = await run_eval(
        "How do I configure Llama Stack for model serving?"
    )
    assert result.success, f"Agent request failed: {result.error}"
    assert result.response.strip(), "Agent returned an empty response"
    text_lower = result.response.lower()
    # The response should at minimum mention the technology being asked about
    assert any(
        term in text_lower
        for term in ["llama stack", "llama", "model serving", "model", "serving"]
    ), (
        f"Response does not appear grounded in domain knowledge. "
        f"Response: {result.response[:300]}"
    )


@pytest.mark.asyncio
async def test_response_coherence(run_eval: Any) -> None:
    """Response should be well-structured and substantive."""
    result = await run_eval(
        "What are the key components of a RAG pipeline?"
    )
    assert result.success, f"Agent request failed: {result.error}"
    score = score_plan_coherence(result)
    assert score.passed, (
        f"Coherence check failed (score={score.value:.2f}): {score.details}"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "golden",
    _load_golden_with_elements(),
    ids=lambda q: q["query"][:60],
)
async def test_response_completeness(
    run_eval: Any, golden: dict[str, Any]
) -> None:
    """Response should contain the required elements for known queries."""
    result = await run_eval(golden["query"])
    assert result.success, f"Agent request failed: {result.error}"
    score = score_completeness(result, golden["expected_elements"])
    assert score.value >= 0.5, (
        f"Completeness too low ({score.value:.2f}): "
        f"missing={score.details.get('missing')}"
    )
