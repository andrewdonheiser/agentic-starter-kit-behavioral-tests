# Agentic Eval Framework

Pytest-based eval harness for testing AI agents in `red-hat-data-services/agentic-starter-kits`.
Tests agents over HTTP against their shared OpenAI-compatible API. Organized by capability
(not by agent) so tests automatically apply to new agents as they are added.

## Architecture

The eval harness follows a pipeline: `TaskConfig` → HTTP POST → `EvalResult` → Scorers → Report.

- **Task runner** (`harness/runner.py`): Sends queries to agents, captures response,
  tool calls, latency, tokens. Supports streaming and non-streaming.
- **Scorers** (`harness/scorers/`): Pure functions that take an `EvalResult` and return
  a `Score`. Each scorer tests one dimension (tool accuracy, coherence, latency, safety).
- **Reporters** (`harness/reporters/`): Format scorer output for humans (Rich console)
  or machines (JSON files).
- **Prompt regression** (`harness/prompt_regression.py`): Save/load/compare baselines
  across prompt or model versions.

### Scorer inventory

| Scorer | What it measures |
|--------|-----------------|
| `tool_sequence.py` | Tool selection (F1), tool order (LCS), arg validity, hallucinated tool detection |
| `plan_coherence.py` | Response length, structure, sentence count, refusal detection, completeness |
| `latency.py` | Threshold scoring, `LatencyTracker` with p50/p95/p99 |
| `safety.py` | PII regex patterns, prompt injection compliance detection, policy adherence |

### Failure modes we detect

| Class | Scorer / Test |
|-------|---------------|
| Hallucinated tools | `score_hallucinated_tools()` |
| Tool misselection | `score_tool_selection()` F1 |
| Unsafe actions | `adversarial/test_safety.py` + `score_policy_adherence()` |
| PII/secret leakage | `score_pii_leakage()` regex patterns |
| Incorrect API usage | `score_tool_call_validity()` JSON check |
| Partial completion | `score_completeness()` substring matching |

Not yet detected: infinite loops, memory corruption, coordination failure (single-agent only).

### Metrics

| Category | Metric | Scorer |
|----------|--------|--------|
| Task | pass@k reliability, plan coherence, completeness | `plan_coherence.py`, `test_reliability.py` |
| Tool use | Selection accuracy (F1), sequence accuracy (LCS), call validity, hallucination rate | `tool_sequence.py` |
| Operational | Latency (p50/p95/p99), tokens per task | `latency.py` |
| Safety | Policy adherence, PII leakage, prompt injection resistance | `safety.py` |

Planned but not implemented: partial completion rate, retry/loop rate.

## Roadmap

See `STATUS.md` for current status, test counts, review progress, and known gaps.

### Phase 1: Foundation -- COMPLETE
Eval harness, scorers, reporters, test suites, golden datasets, adversarial payloads,
threshold configs, prompt regression infrastructure, test design philosophy.

### Phase 2: Review & Harden (current)
Interactive review of test suites, upstream bug filing, threshold tuning,
cross-framework gap investigation.

### Phase 3: CI/CD & Cross-Framework
GitHub Actions integration, threshold-based merge gating, cross-framework parity
testing, LLM-as-judge scoring.

### Phase 4: Production Readiness
Regression dashboard, RAG quality testing, model regression baselines,
agent memory/state testing, LLM-as-judge calibration.

## System Under Test

**Repo:** `red-hat-data-services/agentic-starter-kits`
**Branch:** `main`

### Agent inventory (as of 2026-04-01)

| Agent | Framework | Path | Tools | MLflow Tracing |
|-------|-----------|------|-------|----------------|
| ReAct | LangGraph | `agents/langgraph/react_agent/` | dummy_web_search | Yes |
| Agentic RAG | LangGraph | `agents/langgraph/agentic_rag/` | retriever_tool (Milvus) | No |
| ReAct + DB Memory | LangGraph | `agents/langgraph/react_with_database_memory/` | web search (PostgreSQL memory) | No |
| Human-in-the-Loop | LangGraph | `agents/langgraph/human_in_the_loop/` | tools requiring approval | No |
| WebSearch | LlamaIndex | `agents/llamaindex/websearch_agent/` | dummy web search | Yes |
| WebSearch | CrewAI | `agents/crewai/websearch_agent/` | web search via crew | Yes |
| OpenAI Responses | Vanilla Python | `agents/vanilla_python/openai_responses_agent/` | custom action/observation | Yes |
| MCP Agent | AutoGen | `agents/autogen/mcp_agent/` | MCP server tools (SSE) | No |
| Tool Calling | Langflow | `agents/langflow/simple_tool_calling_agent/` | external APIs | Langfuse only |

### What's in the repo
- 9 agents across 6 frameworks: LangGraph, LlamaIndex, CrewAI, AutoGen, Langflow, vanilla Python
- Common pattern: FastAPI `/chat/completions` + `/health` + `/` (playground) endpoints
- OpenAI-compatible chat completion API across all agents (except Langflow)
- Tools via LangChain `@tool` decorators + Pydantic schemas; AutoGen agent uses MCP (SSE transport)
- MLflow tracing (4 agents) with graceful degradation; Langfuse (Langflow only)
- Deployment: local (`make run` via Makefile) or OpenShift (shared Helm chart at `charts/agent/`)
- Milvus vector DB used for RAG (retrieval quality is testable)
- Python 3.12+ required

### Nature of the system under test

**This repo houses example agents for customers.** This has critical implications for
how we design tests:

- **Agents come and go.** New agent examples are added, old ones are retired or
  replaced. The set of agents is unpredictable and their lifespan is unknown.
- **Frameworks evolve rapidly.** The AI agent ecosystem is immature -- frameworks,
  APIs, and best practices change frequently.
- **We test the repo as much as the agents.** The FastAPI application code, Pydantic
  schemas, error handling, and deployment manifests are all testable artifacts.
  These tests are deterministic and fast. Don't neglect them for the flashier
  LLM-behavior tests.

### Remaining QE gaps in agentic-starter-kits

See `STATUS.md` for the full gap history (what we've closed and what remains).

- **No CI/CD** -- no GitHub Actions workflows (Phase 3)
- **No quality gates** on merges (Phase 3)
- **tool_calls not exposed** in HTTP response -- need MLflow tracing to extract
- **Human-in-the-Loop agent** not yet covered by eval suites

## Test Design Philosophy

### Design for churn

The agents in agentic-starter-kits are **examples, not products**. They will be added,
renamed, forked, and deleted as the technology matures. Tests must survive this churn.

**Rule: Organize tests by what they test, not which agent they target.**

- `api_contract` -- Tests the shared FastAPI contract (endpoints, schemas, validation,
  streaming). Runs against any agent with zero configuration. This is the most durable
  test category because all agents share this contract.
- `adversarial` -- Agent-level safety tests (PII leakage, API key exposure, dangerous
  operations). Runs against any agent via `AGENT_URL`.
- `model_baseline` -- Model-level tests (prompt injection resistance). Tests the LLM's
  alignment, not the agent's architecture. Results change when you swap models.
- `tool_usage` -- Tests that an agent calls the right tools, with valid args, in the
  right order. Requires agent-specific config (which tools exist, what to expect).
- `response_quality` -- Tests that responses are coherent, complete, and grounded.
- `latency` -- Latency threshold enforcement.
- `slow` -- Multi-iteration tests (pass@k). Always combinable with other marks.

### Agent-specific tests

When a test is specific to a particular agent's behavior (e.g., "the react agent should
call the `search` tool"), it goes in a subdirectory under `evals/` named after the agent.
But the **mark** should describe what is being tested (`tool_usage`, `response_quality`),
not which agent it targets. Agent identity is configuration (env vars, fixtures), not
a test category.

```bash
# Test API contract against any agent
AGENT_URL=http://some-agent.localhost pytest -m api_contract -v

# Test tool usage for a specific agent
REACT_AGENT_URL=http://react-agent.localhost pytest evals/langgraph_react/ -m tool_usage -v

# Run all safety tests against all agents (loop in CI)
for url in $AGENT_URLS; do
  AGENT_URL=$url pytest -m adversarial -v
done
```

### Agent URL configuration

Agent targets are always set via environment variables, never hardcoded:

| Env var | Default | Used by |
|---------|---------|---------|
| `AGENT_URL` | `http://localhost:8000` | adversarial, api_contract, model_baseline |
| `REACT_AGENT_URL` | `http://localhost:8000` | evals/langgraph_react/ |
| `RAG_AGENT_URL` | `http://localhost:8001` | evals/agentic_rag/ |
| `MCP_AGENT_URL` | `http://localhost:8002` | evals/autogen_mcp/ |

When adding a new agent-specific eval suite, add a new env var and document it here.

### Adding tests for a new agent

1. Create `evals/<agent_name>/` with `__init__.py` and `conftest.py`
2. In `conftest.py`, override `agent_url` to read from a new env var
3. Add fixtures for the agent's known tools and thresholds
4. Write tests and mark them by **what they test** (`tool_usage`, `response_quality`)
5. Add golden queries to `fixtures/<agent_name>/`
6. **Do not** create a new mark for the agent name -- use directory structure for that
7. Update `STATUS.md` with the new agent and its env var

### What each test should verify

Every test should check as much of the agent stack as possible. Don't just check
the response text -- also verify:
- **Tool calls:** Were the right tools called? Were any tools called that shouldn't
  have been? (check `result.tool_calls`)
- **Response content:** Does the response incorporate tool results? Is it coherent?
- **Error behavior:** Does the agent crash (500) or handle gracefully?
- **Side effects:** Did the agent attempt actions it shouldn't have?

A test that only checks response text is testing the model, not the agent.

## Definition of Done

Every eval must answer:
1. **What is success?** -- concrete criteria, not "it works"
2. **What is acceptable failure rate?** -- numeric threshold
3. **What is unsafe behavior?** -- explicit blocklist

### Example: LangGraph React Agent (web search)
- **Success:** Calls `search` tool for factual queries in >= 85% of runs (pass@8)
- **Acceptable failure:** Correct answer without tool call, or wrong tool order (<= 10%)
- **Unsafe:** Shell execution, API key leakage, hallucinated tools, infinite loops (0% tolerance)
- **Latency threshold:** p95 latency < 30s

## Target Stack

- **Infrastructure:** Ollama (local dev) + OpenShift/ROSA (CI/prod) + kind (integration testing)
- **Language:** Python 3.12+
- **Eval framework:** pytest + pytest-asyncio + custom harness (`harness/`)
- **HTTP client:** httpx (async)
- **Frameworks under test:** LangGraph, LlamaIndex, CrewAI, AutoGen, Langflow
- **Observability:** MLflow tracing (4 agents), Langfuse (Langflow only) -- not yet integrated into evals
- **Eval harness pattern:**
  ```python
  # Actual API -- see harness/runner.py
  from harness.runner import TaskConfig, run_task
  from harness.scorers.tool_sequence import score_tool_selection

  config = TaskConfig(agent_url="http://react-agent.localhost", query="What is OpenShift?")
  result = await run_task(config)
  score = score_tool_selection(result, expected_tools=["search"])
  assert score.value >= 0.85
  ```

## Project Structure

```
agentic-eval-framework/
  CLAUDE.md                  # this file -- design philosophy, conventions
  STATUS.md                 # test review log, mark reference, cleanup history
  pyproject.toml             # project config, dependencies, pytest marks
  conftest.py                # root fixtures (agent_url, http_client, run_eval)
  evals/                     # eval suites organized by agent or concern
    api_contract/            # shared FastAPI contract tests (any agent)
    langgraph_react/         # agent-specific evals (tool usage, quality)
    agentic_rag/             # RAG agent evals
    autogen_mcp/             # MCP agent evals
  harness/                   # eval runner, scorers, reporters
    runner.py                # task execution engine (TaskConfig -> EvalResult)
    prompt_regression.py     # baseline save/load, version comparison
    scorers/                 # scoring functions (tool accuracy, coherence, latency, safety)
    reporters/               # output formatters (JSON, Rich console)
  fixtures/                  # golden datasets, test inputs per agent
  adversarial/               # agent-level safety tests (PII, secrets, dangerous ops)
  configs/                   # threshold definitions
  deploy/                    # local deployment scripts (kind, deploy-all, smoke-test)
```

## Commands

```bash
# Run API contract tests against any agent
AGENT_URL=http://langgraph-react-agent.localhost pytest -m api_contract -v

# Run safety tests against any agent
AGENT_URL=http://crewai-websearch-agent.localhost pytest -m adversarial -v

# Run agent-specific evals
REACT_AGENT_URL=http://langgraph-react-agent.localhost pytest evals/langgraph_react/ -v

# Skip slow tests (pass@k, repeated queries)
pytest -m "not slow" -v

# Run everything
pytest -v
```

## References

- [CLEAR Framework](https://arxiv.org/abs/2511.14136) -- pass@k reliability, cost-normalized accuracy
- [MASEval](https://arxiv.org/html/2603.08835) -- multi-agent coordination evaluation
- [Beyond Task Completion](https://arxiv.org/html/2512.12791v2) -- memory, partial completion metrics
- [Promptfoo](https://github.com/promptfoo/promptfoo) -- prompt regression testing
- [RAGAS](https://langfuse.com/guides/cookbook/evaluation_of_rag_with_ragas) -- RAG evaluation metrics
- [MCP Specification - Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) -- tool contract requirements
