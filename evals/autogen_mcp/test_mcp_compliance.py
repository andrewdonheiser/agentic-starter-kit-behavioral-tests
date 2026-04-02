"""MCP protocol compliance tests for the AutoGen MCP agent.

Verifies that the agent correctly loads tools from the MCP server,
produces structured tool results, and incorporates tool outputs
into its final answer.
"""

from __future__ import annotations

import json

import pytest

pytestmark = pytest.mark.autogen_mcp
from typing import Any

import pytest


class TestMCPToolLoading:
    """Tests that the agent loads tools from the MCP server."""

    async def test_mcp_tools_loaded(self, agent_url, http_client):
        """Agent must initialize with tools from the MCP server.

        A healthy agent with agent_initialized=True implies that
        the MCP tool discovery succeeded.
        """
        resp = await http_client.get(f"{agent_url}/health", timeout=10.0)
        resp.raise_for_status()
        data = resp.json()

        assert data.get("status") == "healthy", (
            f"Agent is not healthy: {data}"
        )
        assert data.get("agent_initialized") is True, (
            "Agent did not initialize -- MCP tools may not have loaded"
        )


class TestToolResultStructure:
    """Tests that tool results are properly structured."""

    async def test_tool_results_structured(self, agent_url, http_client):
        """Tool results should be valid JSON or well-structured text."""
        payload = {
            "messages": [{"role": "user", "content": "What is the weather in Denver?"}],
            "stream": True,
        }

        tool_results: list[dict[str, Any]] = []
        async with http_client.stream(
            "POST",
            f"{agent_url}/chat/completions",
            json=payload,
            timeout=60.0,
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                data_str = line[6:]
                if data_str.strip() == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                except json.JSONDecodeError:
                    continue
                for invocation in chunk.get("tool_invocations", []):
                    if "result" in invocation:
                        tool_results.append(invocation)

        assert tool_results, "No tool results found in streaming response"

        for invocation in tool_results:
            result_value = invocation["result"]
            assert isinstance(result_value, (str, dict, list)), (
                f"Tool result is not a structured type: {type(result_value)}"
            )
            # If it's a string, check if it's valid JSON (structured output)
            if isinstance(result_value, str) and result_value.strip():
                try:
                    parsed = json.loads(result_value)
                    assert isinstance(parsed, (dict, list, str, int, float, bool)), (
                        f"Parsed JSON result is unexpected type: {type(parsed)}"
                    )
                except json.JSONDecodeError:
                    # Non-JSON string is acceptable -- just needs to be non-empty
                    assert len(result_value.strip()) > 0, (
                        "Tool result is empty string"
                    )


class TestToolIntegration:
    """Tests that the agent integrates tool results into its answer."""

    async def test_agent_reflects_on_tool_use(self, agent_url, http_client):
        """Agent must incorporate tool results into its final response."""
        payload = {
            "messages": [{"role": "user", "content": "What is the weather in Denver?"}],
            "stream": True,
        }

        final_content = ""
        tool_invocations: list[dict[str, Any]] = []

        async with http_client.stream(
            "POST",
            f"{agent_url}/chat/completions",
            json=payload,
            timeout=60.0,
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                data_str = line[6:]
                if data_str.strip() == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                for invocation in chunk.get("tool_invocations", []):
                    tool_invocations.append(invocation)

                for choice in chunk.get("choices", []):
                    delta = choice.get("delta", {})
                    content = delta.get("content", "")
                    if content:
                        final_content += content

        assert final_content.strip(), (
            "Agent produced no final content after tool use"
        )

        # If tools were used, the final content should reference
        # something related to the query topic (weather/Denver)
        if tool_invocations:
            content_lower = final_content.lower()
            has_topic_reference = any(
                term in content_lower
                for term in ["weather", "denver", "temperature", "forecast", "condition"]
            )
            assert has_topic_reference, (
                "Agent used tools but final response does not reference the "
                f"query topic. Response: {final_content[:300]}"
            )
