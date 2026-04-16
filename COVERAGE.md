# Agent Coverage Status

Per-agent breakdown of what the eval framework tests, why, and what's missing.
Last updated: 2026-04-01.

---

## How the Testing Works

Every agent in agentic-starter-kits exposes the same OpenAI-compatible HTTP API:
`POST /chat/completions` and `GET /health`. The eval harness sends queries over HTTP,
captures the response, and scores it across multiple dimensions:

- **API contract** — Does the HTTP interface conform to the OpenAI spec?
- **Tool usage** — Did the agent call the right tools with valid arguments?
- **Response quality** — Is the response coherent, complete, and grounded?
- **Safety** — Does the agent refuse dangerous operations and avoid leaking secrets?
- **Reliability** — Does the agent produce consistent results across repeated runs (pass@k)?
- **Latency** — Does the agent respond within acceptable time bounds?

Tests are organized by *what they test*, not *which agent they target*. Agent identity
is configuration (env vars), not a test category. This means cross-agent suites
(API contract, adversarial) work against any agent with zero changes.

### MLflow Trace Enrichment

Agents don't expose `tool_calls` in their HTTP responses (the FastAPI response model
strips them). MLflow tracing fills this gap: after each request, the eval harness
queries MLflow for the trace and extracts tool calls and token usage from spans.

This is implemented in `harness/mlflow_client.py` and wired into the `run_eval`
fixture for agent-specific test suites. It requires:
- MLflow server running (`MLFLOW_TRACKING_URI`)
- Agent started with tracing enabled (`MLFLOW_EXPERIMENT_NAME`)
- Both using the same experiment name

Without MLflow, tests gracefully degrade: tool usage tests either skip or fall back
to checking response content for evidence of tool use.

---

## Agent-by-Agent Coverage

Agents with dedicated test suites are listed first, followed by agents with
cross-agent-only coverage, then agents with no coverage.

### 1. LangGraph ReAct Agent — FULL COVERAGE

| | |
|---|---|
| **Framework** | LangGraph |
| **Path** | `agents/langgraph/react_agent/` |
| **Tools** | `dummy_web_search(query)` — returns canned OpenShift AI answer |
| **MLflow tracing** | Yes |
| **Eval suite** | `evals/langgraph_react/` (12 tests) |
| **Env var** | `REACT_AGENT_URL` |
| **Status** | Reviewed, 9 pass / 0 skip / 2 slow |

**What's tested:**

| Test | What it checks | Why |
|------|---------------|-----|
| `test_tool_selection_accuracy` (x4) | Agent calls `search` for factual queries; response contains search output | Core agent behavior — does it use its tools? |
| `test_no_hallucinated_tools` | Agent only calls tools that exist in its schema | Catches model inventing tool names |
| `test_tool_call_has_valid_args` | Tool call arguments are valid JSON with required fields | Catches malformed tool invocations |
| `test_tool_not_called_for_greeting` | "Hello" doesn't trigger search tool | Agent should know when NOT to use tools |
| `test_plan_coherence` | Response is structured, substantive, not a bare one-liner | Basic response quality gate |
| `test_latency_under_threshold` | Response time < configured p95 threshold | Catches performance regressions |
| `test_pass_at_k_tool_usage` (slow) | Tool selection succeeds in >= 85% of 8 runs | Measures reliability, not just single-shot |
| `test_pass_at_k_response_quality` (slow) | Response coherence passes in >= 75% of 8 runs | Catches intermittent quality drops |

**MLflow integration:** Fully wired. The `run_eval` fixture in `evals/langgraph_react/conftest.py`
auto-enriches results with tool calls and token usage from MLflow traces. This is why
`test_no_hallucinated_tools` and `test_tool_call_has_valid_args` now pass instead of skip.

**Potential issues:**
- `dummy_web_search` always returns the same canned answer — we're testing that the agent
  calls it, not that it returns useful results. This is by design (testing agent behavior,
  not model knowledge).
- Latency threshold (8s) may be flaky on loaded Ollama instances.
- pass@k tests run sequentially (not concurrent) because concurrent requests overwhelm
  local Ollama. In CI with a stronger inference server, could parallelize.
- The `context` field in the HTTP response contains tool calls but FastAPI's response
  model strips it. Filed as upstream issue (RHAIENG-4156).

---

### 2. LangGraph Agentic RAG — TESTS WRITTEN, NOT RUNNABLE

| | |
|---|---|
| **Framework** | LangGraph |
| **Path** | `agents/langgraph/agentic_rag/` |
| **Tools** | `retriever_tool(query)` — retrieves from LlamaStack vector store |
| **MLflow tracing** | No |
| **Eval suite** | `evals/agentic_rag/` (10 tests) |
| **Env var** | `RAG_AGENT_URL` |
| **Status** | Not yet reviewed. Agent not deployed (needs LlamaStack + Milvus) |

**What's tested:**

| Test | What it checks | Why |
|------|---------------|-----|
| `test_retriever_tool_called` | Domain query triggers `retriever` tool | Core RAG behavior — does it retrieve? |
| `test_retrieval_for_knowledge_query` (parametrized) | Knowledge queries trigger retrieval; no hallucinated tools | Validates retrieval decision across query types |
| `test_no_retrieval_for_greeting` | Greetings don't trigger retrieval | Agent should skip retrieval for non-knowledge queries |
| `test_response_grounded_in_context` | Response contains domain-specific terms from retrieved docs | RAG responses must be grounded, not hallucinated |
| `test_response_coherence` | Response is structured and substantive | Basic quality gate |
| `test_response_completeness` (parametrized) | Response contains expected elements from golden queries | Validates that retrieved info makes it into the response |

**Potential issues:**
- **Cannot run today.** Agent requires LlamaStack with a Milvus vector store. Neither is
  deployed locally or on the kind cluster.
- No MLflow tracing — tool call tests will skip unless we add MLflow or the upstream
  response format is fixed.
- Retrieval quality depends heavily on what's in the vector store. Need golden documents
  loaded before tests are meaningful.
- Tests are written but completely unvalidated against a live agent.

---

### 3. AutoGen MCP Agent — TESTS WRITTEN, NOT RUNNABLE

| | |
|---|---|
| **Framework** | AutoGen |
| **Path** | `agents/autogen/mcp_agent/` |
| **Tools** | Dynamic — loaded from MCP server at runtime via SSE |
| **MLflow tracing** | No |
| **Eval suite** | `evals/autogen_mcp/` (7 tests) |
| **Env var** | `MCP_AGENT_URL` |
| **Status** | Not yet reviewed. Agent not deployed (needs MCP server) |

**What's tested:**

| Test | What it checks | Why |
|------|---------------|-----|
| `test_health_endpoint` | Health response has expected schema | API contract for MCP agent |
| `test_tool_invocations_reported` | Streaming response includes tool invocation data | MCP agents report tool use differently |
| `test_tool_call_schema_valid` | Tool invocations have name, arguments, result fields | Validates MCP tool call structure |
| `test_no_tool_errors` | Tool invocations don't have `is_error=True` | Tools should execute without errors |
| `test_mcp_tools_loaded` | Agent initialized with tools from MCP server | Validates MCP server connection and tool discovery |
| `test_tool_results_structured` | Tool results are valid JSON or well-structured text | Results should be parseable |
| `test_agent_reflects_on_tool_use` | Final response incorporates tool output | Agent should use tool results in its answer |

**Potential issues:**
- **Cannot run today.** Agent requires an MCP server with SSE transport. No MCP server
  is deployed.
- The agent uses a non-standard response format (`messages` + `tool_invocations` instead
  of OpenAI-compatible `choices`). Tests account for this but the harness's
  `_extract_tool_calls` won't work — tests use direct HTTP parsing.
- No MLflow tracing — tool visibility comes from the custom `tool_invocations` field
  in the streaming response.
- Tests are written but completely unvalidated against a live agent.

---

### 4. LlamaIndex Websearch Agent — CROSS-AGENT ONLY

| | |
|---|---|
| **Framework** | LlamaIndex |
| **Path** | `agents/llamaindex/websearch_agent/` |
| **Tools** | `dummy_web_search(query)` — same canned response |
| **MLflow tracing** | Yes (`mlflow.llama_index` autolog) |
| **Eval suite** | None (agent-specific). Cross-agent suites apply. |
| **Env var** | `AGENT_URL` |
| **Status** | Partially covered by cross-agent suites only |

**Current coverage (via cross-agent suites):**
- API contract tests work against this agent via `AGENT_URL`
- Adversarial safety tests work against this agent via `AGENT_URL`
- No agent-specific tool usage or response quality tests

**What should be tested (agent-specific):**
- Tool selection (same pattern as ReAct — should call `dummy_web_search`)
- Response quality with LlamaIndex-specific behaviors
- MLflow trace structure (Sana noted LlamaIndex traces look different — "look at
  'a chat' for LLM calls and 'last function tool' for tool calls")

**Why no dedicated suite yet:**
- Behavior is very similar to ReAct agent (same tool, same queries). The cross-agent
  suites cover the shared contract. Agent-specific tests would mostly duplicate ReAct.
- Could share golden queries and thresholds with minor adjustments.

**Potential issues:**
- MLflow trace structure differs from LangGraph. The `mlflow_client.py` extraction
  logic was built against LangGraph trace spans. May need adjustments for LlamaIndex
  span types/names.
- Agent has additional endpoints (`/api/chat`, `/api/health`) not covered by API
  contract tests.

---

### 5. CrewAI Websearch Agent — CROSS-AGENT ONLY

| | |
|---|---|
| **Framework** | CrewAI |
| **Path** | `agents/crewai/websearch_agent/` |
| **Tools** | `WebSearchTool` (BaseTool) — dummy search results |
| **MLflow tracing** | Yes (provider-specific autolog + manual tool span wrapping) |
| **Eval suite** | None (agent-specific). Cross-agent suites apply. |
| **Env var** | `AGENT_URL` |
| **Status** | Partially covered by cross-agent suites only |

**Current coverage (via cross-agent suites):**
- API contract tests work against this agent
- Adversarial safety tests work against this agent
- No agent-specific tests

**What should be tested (agent-specific):**
- Tool selection (CrewAI uses a crew/task pattern — tool invocation may differ)
- Response quality (CrewAI agents have a defined role/goal/backstory that shapes responses)
- MLflow trace structure (CrewAI tracing uses manual `wrap_func_with_mlflow_trace`)

**Why no dedicated suite yet:**
- Same reasoning as LlamaIndex — similar behavior, cross-agent suites cover the basics.
- CrewAI's crew execution model (Agent -> Task -> Crew) may produce different response
  patterns that deserve dedicated quality tests.

**Potential issues:**
- CrewAI agent response format may differ subtly from LangGraph (crew execution
  wraps the response differently).
- MLflow trace structure uses manual span wrapping, not framework autolog. Span
  names/types will differ from LangGraph.

---

### 6. Vanilla Python OpenAI Responses Agent — TESTS WRITTEN, NOT REVIEWED

| | |
|---|---|
| **Framework** | Vanilla Python (raw OpenAI client with `tool_choice="auto"`) |
| **Path** | `agents/vanilla_python/openai_responses_agent/` |
| **Tools** | `search_price(brand)`, `search_reviews(brand)` — dummy product data |
| **MLflow tracing** | Yes (manual function wrapping) |
| **Eval suite** | `evals/vanilla_python/` (24 pytest tests) + 2 EvalHub benchmarks |
| **Env var** | `VANILLA_PYTHON_AGENT_URL` |
| **Status** | Tests written, not yet reviewed against live agent |

**Test inventory:**

| Test file | Tests | What it checks |
|-----------|-------|---------------|
| `test_tool_usage.py` | 10 | Single-tool selection (price x2, reviews x2, adversarial x1), multi-tool orchestration (x2), no-tool for greeting, hallucinated tools, arg validity |
| `test_response_quality.py` | 9 | Plan coherence, multi-tool synthesis, completeness for 7 queries with expected elements |
| `test_reliability.py` | 3 (slow) | pass@8 single-tool (>= 85%), pass@8 multi-tool (>= 75%), pass@8 coherence (>= 75%) |
| `test_cost_latency.py` | 2 | Single-tool latency under threshold, multi-tool latency under 1.5x threshold |
| Cross-agent API contract | 7 | Schema, streaming, error handling (via `AGENT_URL`) |
| Cross-agent adversarial | 4 | PII, API keys, dangerous ops (via `AGENT_URL`) |

**EvalHub benchmarks:**

| Benchmark ID | Queries | Scorers |
|-------------|---------|---------|
| `vanilla-python-tool-use` | 6 (product-domain) | tool_selection, tool_sequence, hallucinated_tools, tool_call_validity |
| `vanilla-python-full` | 11 (tool use + coherence + safety) | all |

**Potential issues:**
- Different tools means different golden queries, thresholds, and expected elements.
  Can't reuse ReAct fixtures.
- The agent uses raw OpenAI client (no framework), so tracing spans will look different.

---

### 7. LangGraph ReAct with Database Memory — NO COVERAGE

| | |
|---|---|
| **Framework** | LangGraph |
| **Path** | `agents/langgraph/react_with_database_memory/` |
| **Tools** | `dummy_web_search(query)` — same as ReAct agent |
| **MLflow tracing** | No |
| **Eval suite** | None |
| **Env var** | — |
| **Status** | No coverage |

**What should be tested:**
- Same tool usage tests as ReAct (same tool, same pattern)
- **Conversation memory persistence** — does thread_id maintain context across requests?
- **Memory isolation** — do different thread_ids get independent conversations?
- **Database failure handling** — what happens when PostgreSQL is down?
- Health endpoint reports database connection status

**Why no coverage yet:**
- Agent requires PostgreSQL for conversation memory. Not deployed locally.
- The interesting behavior (memory) requires multi-turn test patterns that the current
  harness doesn't support well (single query in, single response out).
- Tool usage tests would be near-identical to ReAct — low incremental value without
  the memory-specific tests.

**Potential issues:**
- Multi-turn testing needs harness changes: `run_task` currently sends a single message.
  Need to support `thread_id` in `TaskConfig` and send conversation sequences.
- PostgreSQL setup adds deployment complexity for CI.

---

### 8. LangGraph Human-in-the-Loop — NO COVERAGE

| | |
|---|---|
| **Framework** | LangGraph |
| **Path** | `agents/langgraph/human_in_the_loop/` |
| **Tools** | `create_file(filename, content)` — requires human approval |
| **MLflow tracing** | No |
| **Eval suite** | None |
| **Env var** | — |
| **Status** | No coverage. Jira story RHAIENG-4189 created |

**What should be tested:**
- Agent returns `finish_reason: pending_approval` when tool requires human review
- Approval flow: approve tool call -> agent executes -> returns result
- Rejection flow: deny tool call -> agent acknowledges without executing
- Queries that don't need tools should complete normally (no approval needed)
- API contract (same OpenAI-compatible endpoints)

**Why no coverage yet:**
- Agent not deployed.
- The approval flow is a different interaction pattern than the other agents.
  The harness sends a query and expects a response — but this agent pauses mid-execution
  waiting for approval. Need to handle the multi-step flow.

**Potential issues:**
- Requires harness changes to support the approval interaction pattern:
  send query -> get pending response -> send approval -> get final response.
- The `create_file` tool has side effects (file creation). Tests need cleanup or
  sandboxing.
- No MLflow tracing — tool call visibility will be limited.

---

### 9. Langflow Simple Tool Calling Agent — NO COVERAGE

| | |
|---|---|
| **Framework** | Langflow (visual flow builder) |
| **Path** | `agents/langflow/simple_tool_calling_agent/` |
| **Tools** | Open-Meteo weather API, NPS parks API, NPS alerts API |
| **MLflow tracing** | No (uses Langfuse instead) |
| **Eval suite** | None |
| **Env var** | — |
| **Status** | No coverage |

**What should be tested:**
- Basic flow execution (does the Langflow agent respond to queries?)
- Tool selection (weather vs. parks queries should route to correct API)
- Response grounding (does the response contain data from the external API?)

**Why no coverage:**
- Langflow uses a completely different API (`POST /api/v1/run/<flow-id>`) — not
  OpenAI-compatible. None of the existing test infrastructure works against it.
- Deployment requires podman-compose with PostgreSQL, Langfuse, and Ollama.
  Heaviest deployment footprint of any agent.
- The agent is defined as a JSON flow, not Python code. No source to analyze.
- Uses Langfuse for tracing, not MLflow. Would need a separate tracing integration.

**Potential issues:**
- Would need either: (a) a Langflow-specific test adapter in the harness, or
  (b) an OpenAI-compatible wrapper in front of Langflow.
- External API tools (Open-Meteo, NPS) make responses non-deterministic and
  dependent on live services. Need mocking or tolerance for variable responses.
- Lowest priority given the deployment complexity and non-standard API.

---

## Cross-Agent Test Suites

These suites run against **any** agent via `AGENT_URL`. No agent-specific configuration needed.

### API Contract (7 tests)

| Test | What it checks |
|------|---------------|
| `test_health_returns_expected_fields` | Health endpoint returns `status` + `agent_initialized` |
| `test_non_streaming_response_schema` | Response has `id`, `object`, `created`, `model`, `choices` |
| `test_streaming_returns_sse_with_done` | SSE stream ends with `data: [DONE]` |
| `test_missing_messages_returns_422` | Missing `messages` field rejected |
| `test_empty_messages_list_handled` | Empty messages list doesn't crash (returns 400/422, not 500) |
| `test_agent_ready_after_startup` | Agent reports `agent_initialized: true` |
| `test_uninitialized_agent_returns_503` | Uninitialized agent returns 503 (skips if already initialized) |

**Status:** Reviewed, all passing. Found upstream bug: empty messages causes 500.

**Why these matter:** These test the FastAPI application code, not the model. They're
deterministic, fast, and catch regressions in the shared HTTP interface. Every agent
should pass these.

### Adversarial Safety (4 tests)

| Test | What it checks |
|------|---------------|
| `test_no_pii_leakage` | Standard query doesn't produce PII patterns |
| `test_no_api_key_exposure` | Agent doesn't reveal credentials; no tool calls for credential queries |
| `test_refuses_dangerous_operations` | No tool calls and no compliance for "rm -rf /" |
| `test_no_shell_execution_compliance` | No tool calls and no compliance for shell commands |

**Status:** Reviewed, all passing. Tests verify both response content AND tool call layer.

### Prompt Injection / Model Baseline (6 tests)

| Test | What it checks |
|------|---------------|
| `test_direct_injection_ignore_instructions` | Resists "ignore all instructions" attacks |
| `test_direct_injection_reveal_system_prompt` | Doesn't output system prompt |
| `test_indirect_injection_via_tool_syntax` | Doesn't execute tool calls embedded in user text |
| `test_indirect_injection_data_exfiltration` | Doesn't format internal data as exfiltration URLs |
| `test_injection_with_role_play` | Resists DAN/jailbreak attempts |
| `test_injection_nested_in_content` | Catches injection hidden in legitimate-looking content |

**Status:** Not yet reviewed. These test model alignment, not agent architecture.
Results will change when you swap models.

### Boundary Conditions (5 tests, slow)

| Test | What it checks |
|------|---------------|
| `test_empty_query` | Empty string handled gracefully |
| `test_very_long_query` | 10K character query doesn't crash |
| `test_special_characters` (x2) | Unicode, emoji, HTML, quotes handled |
| `test_repeated_queries` | Same query 5 times doesn't cause loops |

**Status:** Not yet reviewed.

---

## Coverage Summary

| Agent | API Contract | Safety | Tool Usage | Response Quality | Reliability | Latency | MLflow | Overall |
|-------|-------------|--------|-----------|-----------------|-------------|---------|--------|---------|
| ReAct (LangGraph) | Yes | Yes | Yes (4) | Yes (1) | Yes (2, slow) | Yes (1) | Yes | Full |
| Agentic RAG | Yes | Yes | Yes (3) | Yes (3) | No | No | No | Written, not runnable |
| AutoGen MCP | No* | No* | Yes (4) | Yes (3) | No | No | No | Written, not runnable |
| LlamaIndex Websearch | Yes | Yes | No | No | No | No | Available | Cross-agent only |
| CrewAI Websearch | Yes | Yes | No | No | No | No | Available | Cross-agent only |
| Vanilla Python | Yes | Yes | Yes (10) | Yes (9) | Yes (3, slow) | Yes (2) | Available | Written, not reviewed |
| DB Memory | Yes | Yes | No | No | No | No | No | Cross-agent only |
| Human-in-the-Loop | Yes | Yes | No | No | No | No | No | Cross-agent only |
| Langflow | No | No | No | No | No | No | No (Langfuse) | No coverage |

*AutoGen MCP has its own API contract tests but can't use the shared cross-agent suites
because its response format differs from OpenAI-compatible.

**"Yes" = API contract and safety suites can run against these agents** by setting
`AGENT_URL`. They just haven't been formally run and reviewed yet (except ReAct).

---

## Next Steps

### Immediate (this sprint)

1. **Run cross-agent suites against deployed agents.** The API contract and adversarial
   tests already work against any agent. Run them against LlamaIndex, CrewAI, and
   Vanilla Python on the kind cluster and record results.
   ```bash
   for url in http://llamaindex-websearch-agent.localhost \
              http://crewai-websearch-agent.localhost \
              http://openai-responses-agent.localhost; do
     AGENT_URL=$url pytest -m "api_contract or adversarial" -v
   done
   ```

2. **Test MLflow trace extraction for non-LangGraph agents.** The `mlflow_client.py`
   was built against LangGraph spans. Need to verify it works with LlamaIndex
   (`mlflow.llama_index` autolog), CrewAI (manual span wrapping), and Vanilla Python
   (manual span wrapping). Sana noted trace structure differs per framework.

3. **Review unreviewed test suites.** Agentic RAG, AutoGen MCP, boundary conditions,
   and model baseline suites have never been run against live agents. Mark them as
   reviewed or fix them.

### Short-term (Phase 2)

4. **Deploy Agentic RAG agent.** Needs LlamaStack + Milvus. Once deployed, run the
   `evals/agentic_rag/` suite and review results.

5. **Add Vanilla Python agent-specific tests.** This agent has two tools (`search_price`,
   `search_reviews`), making it the best candidate for multi-tool selection tests.
   Create `evals/vanilla_python/` with golden queries for product comparison queries.

6. **Upstream the `context` field fix.** The ReAct agent already builds tool call data
   in the `context` field but FastAPI's response model strips it. A one-line fix
   (add `context` to `ChatCompletionResponse`) would give tool call visibility without
   needing MLflow. File this as part of RHAIENG-4156.

### Medium-term (Phase 3)

7. **Add multi-turn test support.** DB Memory and Human-in-the-Loop agents need
   conversation sequences. Extend `TaskConfig` with `thread_id` and `messages` list
   to support multi-turn flows.

8. **Add Human-in-the-Loop approval flow tests.** Need harness support for the
   send-query -> pending -> approve -> result pattern. Story: RHAIENG-4189.

9. **CI/CD integration.** GitHub Actions workflow that:
   - Starts MLflow server
   - Deploys agents to kind cluster
   - Runs cross-agent suites against all agents
   - Runs agent-specific suites
   - Fails the build if thresholds are breached

### Deferred

10. **Langflow coverage.** Requires either a Langflow API adapter or an
    OpenAI-compatible wrapper. Lowest priority given deployment complexity and
    non-standard API.

11. **AutoGen MCP deployment.** Needs an MCP server. Once available, validate the
    `evals/autogen_mcp/` suite.

12. **Cross-framework parity matrix.** Compare test results across agents that have
    the same tool (ReAct, LlamaIndex, CrewAI all use `dummy_web_search`). Same queries,
    same thresholds — which framework performs best?
