"""Tool contract validation tests for the AutoGen MCP agent.

Verifies that the agent's endpoints conform to their defined
contracts: health check schema, tool invocation reporting,
tool call schema validity, and error-free tool execution.
"""

from __future__ import annotations

import json

import pytest

pytestmark = pytest.mark.autogen_mcp
from typing import Any

import pytest


class TestHealthEndpoint:
    """Tests for the /health endpoint contract."""

    async def test_health_endpoint(self, agent_url, http_client, tool_contracts):
        """Health endpoint must return the expected schema fields."""
        contract = tool_contracts["health_endpoint"]
        resp = await http_client.get(
            f"{agent_url}{contract['path']}", timeout=10.0
        )
        resp.raise_for_status()
        data = resp.json()

        for field in contract["expected_fields"]:
            assert field in data, (
                f"Health response missing required field '{field}'. "
                f"Got: {list(data.keys())}"
            )

        assert data["status"] in contract["valid_status_values"], (
            f"Health status '{data['status']}' not in valid values: "
            f"{contract['valid_status_values']}"
        )

class TestToolInvocations:
    """Tests for tool invocation reporting in streaming responses."""

    async def test_tool_invocations_reported(self, agent_url, http_client):
        """Streaming response must include tool_invocations data."""
        payload = {
            "messages": [{"role": "user", "content": "What is the weather in Denver?"}],
            "stream": True,
        }

        tool_invocations_found = False
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
                if "tool_invocations" in chunk:
                    tool_invocations_found = True

        assert tool_invocations_found, (
            "Streaming response did not include any tool_invocations data"
        )

    async def test_tool_call_schema_valid(self, agent_url, http_client, tool_contracts):
        """Tool invocations must contain name, arguments, and result fields."""
        contract = tool_contracts["streaming_response"]["tool_invocation_schema"]
        required_fields = contract["required"]

        payload = {
            "messages": [{"role": "user", "content": "What is the weather in Denver?"}],
            "stream": True,
        }

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
                if "tool_invocations" in chunk:
                    tool_invocations.extend(chunk["tool_invocations"])

        assert tool_invocations, "No tool invocations found to validate"

        for invocation in tool_invocations:
            for field in required_fields:
                assert field in invocation, (
                    f"Tool invocation missing required field '{field}'. "
                    f"Got: {list(invocation.keys())}. "
                    f"Invocation: {invocation}"
                )

    async def test_no_tool_errors(self, agent_url, http_client):
        """Tool invocations should not have is_error=True for valid queries."""
        payload = {
            "messages": [{"role": "user", "content": "What is the weather in Denver?"}],
            "stream": True,
        }

        errored_tools: list[dict[str, Any]] = []
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
                    if invocation.get("is_error", False):
                        errored_tools.append(invocation)

        assert not errored_tools, (
            f"Tool invocations had errors: {errored_tools}"
        )
