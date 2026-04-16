# Agentic Eval Framework

Behavioral evaluation harness for AI agents in
[`red-hat-data-services/agentic-starter-kits`](https://github.com/red-hat-data-services/agentic-starter-kits).

Tests 9 agents across 6 frameworks over HTTP against their shared OpenAI-compatible
API. Organized by capability (not by agent) so tests automatically apply to new agents
as they are added.

---

## What This Project Does

The eval framework answers three questions for every agent before it ships:

1. **What does success look like?** Concrete, numeric criteria.
2. **What is the acceptable failure rate?** Thresholds enforced as gates.
3. **What is unsafe behavior?** Zero-tolerance safety gates — PII leakage, secret
   exposure, shell execution compliance, hallucinated tools. Any single occurrence
   fails the eval. Defined in the safety scorers and adversarial test assertions,
   not a separate file.

It does this through a pipeline that sends queries to live agents, captures responses,
scores them across multiple dimensions, and reports results:

```
TaskConfig → HTTP POST → EvalResult → Scorers → Score → Report
```

### What gets measured

| Category | What | Scorers | Execution |
|----------|------|---------|-----------|
| API contract | Schema validation, streaming, error handling | pytest assertions | pytest only |
| Tool use | Selection accuracy (F1), sequence order, arg validity, hallucination detection | `tool_sequence.py` | pytest + EvalHub |
| Response quality | Coherence, structure, completeness, refusal detection | `plan_coherence.py` | pytest + EvalHub |
| Latency | p50/p95/p99 threshold enforcement | `latency.py` | pytest + EvalHub |
| Safety | PII leakage, prompt injection resistance, policy adherence | `safety.py` | pytest + EvalHub |
| Reliability | pass@k consistency across repeated runs (k=8) | `test_reliability.py` | pytest (slow) + EvalHub |

### What gets caught

Hallucinated tools, tool misselection, PII/secret leakage, prompt injection compliance,
malformed tool arguments, partial completion, unsafe action attempts.

---

## System Under Test

**9 agents across 6 frameworks**, all exposing the same OpenAI-compatible HTTP API
(`POST /chat/completions`, `GET /health`).

| Agent | Framework | Tools | MLflow Supported |
|-------|-----------|-------|--------|
| ReAct | LangGraph | dummy_web_search | Yes |
| Agentic RAG | LangGraph | retriever_tool (Milvus) | No |
| ReAct + DB Memory | LangGraph | web search (PostgreSQL memory) | No |
| Human-in-the-Loop | LangGraph | tools requiring approval | No |
| WebSearch | LlamaIndex | dummy web search | Yes |
| WebSearch | CrewAI | web search via crew | Yes |
| OpenAI Responses | Vanilla Python | search_price, search_reviews | Yes |
| MCP Agent | AutoGen | MCP server tools (SSE) | No |
| Tool Calling | Langflow | external APIs | Langfuse |

These are **example agents for customers**, not products. They come and go as the
technology matures. Tests are designed to survive this churn.

---

## Architecture

### Core harness (`harness/`)

- **Runner** (`runner.py`): Sends queries, captures response + tool calls + latency +
  tokens. Supports streaming and non-streaming.
- **Scorers** (`scorers/`): Pure functions. Each takes an `EvalResult`, returns a `Score`.
  One scorer per dimension.
- **Reporters** (`reporters/`): Format output for humans (Rich console) or machines (JSON).
- **MLflow client** (`mlflow_client.py`): Queries MLflow traces after each request to
  extract tool calls and token usage that agents don't expose in HTTP responses.
- **Prompt regression** (`prompt_regression.py`): Save/load/compare baselines across
  prompt or model versions.

### Test suites

Tests are organized by **what they test**, not which agent they target:

| Suite | Location | Scope |
|-------|----------|-------|
| API contract | `evals/api_contract/` | Any agent — schema, streaming, validation |
| Adversarial safety | `adversarial/test_safety.py` | Any agent — PII, secrets, dangerous ops |
| Prompt injection | `adversarial/test_prompt_injection.py` | Any agent — model alignment |
| Boundary conditions | `adversarial/test_boundary_conditions.py` | Any agent — edge cases |
| LangGraph ReAct | `evals/langgraph_react/` | Agent-specific — tool usage, quality, reliability |
| Agentic RAG | `evals/agentic_rag/` | Agent-specific — retrieval, grounding |
| AutoGen MCP | `evals/autogen_mcp/` | Agent-specific — MCP tool discovery |

Agent-specific suites live under `evals/<agent_name>/` but are marked by capability
(`tool_usage`, `response_quality`), not by agent name.

### EvalHub adapter (`evalhub_adapter/`)

Wraps the entire harness as a single EvalHub-compatible package so evals can run as
Kubernetes jobs on OpenShift AI. One adapter, all agents — agent-specific config comes
from `JobSpec.parameters` at submission time.

Five registered benchmarks: `agentic-tool-use`, `agentic-coherence`, `agentic-safety`,
`agentic-latency`, `agentic-full`.

## Two Execution Paths

The same harness and scorers power both paths. The difference is orchestration.
How these paths integrate into CI/CD has not been decided yet.

### Path 1: pytest

Runs tests directly via pytest. Can be invoked locally or from any CI system.

```bash
# API contract against any agent
AGENT_URL=http://langgraph-react-agent.localhost pytest -m api_contract -v

# Safety tests against any agent
AGENT_URL=http://crewai-websearch-agent.localhost pytest -m adversarial -v

# Agent-specific evals with MLflow
REACT_AGENT_URL=http://langgraph-react-agent.localhost \
  MLFLOW_TRACKING_URI=http://mlflow.localhost \
  MLFLOW_EXPERIMENT_NAME=react-agent-evals \
  pytest evals/langgraph_react/ -v

# Skip slow tests (pass@k)
pytest -m "not slow" -v
```

### Path 2: EvalHub

EvalHub orchestrates scored benchmark runs as Kubernetes Jobs on OpenShift AI,
providing historical tracking, cross-agent comparison, and regression dashboards.

**How it works:**

1. EvalHub submits a `JobSpec` per agent/benchmark combination. Each `JobSpec` specifies
   the agent URL, benchmark ID, and agent-specific parameters (known tools, thresholds,
   forbidden actions).
2. EvalHub creates a Kubernetes Job running the adapter container
   (`agentic-eval-adapter`).
3. The adapter loads golden queries from `fixtures/benchmarks/`, runs each query against
   the agent using the same `run_task()` and scorers as pytest, and reports progress
   back to EvalHub through six phases (INITIALIZING → LOADING_DATA →
   RUNNING_EVALUATION → POST_PROCESSING → PERSISTING_ARTIFACTS → results).
4. Aggregated metrics (per-metric mean, pass rate, min/max) are returned to EvalHub
   as `JobResults` and optionally logged to MLflow as a run.

**Five registered benchmarks:**

| Benchmark ID | Scorers | Golden queries |
|--------------|---------|----------------|
| `agentic-tool-use` | Tool selection, sequence, hallucination, arg validity | `fixtures/benchmarks/tool_use.yaml` |
| `agentic-coherence` | Plan coherence, completeness | `fixtures/benchmarks/coherence.yaml` |
| `agentic-safety` | PII leakage, policy adherence, injection resistance | `fixtures/benchmarks/safety.yaml` |
| `agentic-latency` | Latency threshold | `fixtures/benchmarks/latency.yaml` |
| `agentic-full` | All scorers | `fixtures/benchmarks/full.yaml` |

**What EvalHub adds over pytest:**

- Kubernetes-native job scheduling and progress tracking
- Per-benchmark result aggregation with overall scores
- Historical comparison across runs (model versions, prompt changes, code changes)
- Dashboard for cross-agent benchmark comparison
- MLflow run logging with params, metrics, and pass rates for each benchmark

```bash
# Adapter entry point (runs inside a K8s Job, reads JobSpec from ConfigMap)
agentic-eval-adapter

# Example: run tool-use benchmark against ReAct agent
# (submitted via EvalHub API, not CLI)
# JobSpec {
#   benchmark_id: "agentic-tool-use",
#   model: { url: "http://react-agent.apps.cluster/", name: "qwen2.5:7b" },
#   parameters: { known_tools: ["search"], max_latency_seconds: 8.0 }
# }
```

### Results unification

Both paths write to **MLflow** as the common data plane:

- **Agent-side tracing** (runtime): individual spans for LLM calls, tool invocations,
  and token usage. The eval harness reads these after each request to fill in tool call
  data that agents don't expose in HTTP responses.
- **Eval run metrics** (EvalHub adapter): aggregated scorer results per benchmark run —
  tool selection accuracy, coherence scores, latency, safety pass rates, overall score,
  duration. Logged as MLflow runs with params (benchmark ID, model name, agent URL) and
  metrics for dashboard consumption.

MLflow provides detailed metric exploration and historical trends. EvalHub provides
benchmark comparison, job management, and scheduling.

---

## Coverage Status

| Agent | API | Safety | Tools | Quality | Reliability | Latency | Overall |
|-------|-----|--------|-------|---------|-------------|---------|---------|
| ReAct (LangGraph) | Yes | Yes | Yes | Yes | Yes (slow) | Yes | **Full** |
| Agentic RAG | Yes | Yes | Yes | Yes | No | No | Written, not runnable |
| AutoGen MCP | No* | No* | Yes | Yes | No | No | Written, not runnable |
| LlamaIndex WebSearch | Yes | Yes | No | No | No | No | Cross-agent only |
| CrewAI WebSearch | Yes | Yes | No | No | No | No | Cross-agent only |
| Vanilla Python | Yes | Yes | No | No | No | No | Cross-agent only |
| DB Memory | Yes | Yes | No | No | No | No | Cross-agent only |
| Human-in-the-Loop | Yes | Yes | No | No | No | No | Cross-agent only |
| Langflow | No | No | No | No | No | No | None |

**51 tests** across 7 suites. See [COVERAGE.md](./COVERAGE.md) for per-agent details.

---

## Quick Start

```bash
# Install
pip install -e .

# Point at an agent
export AGENT_URL=http://langgraph-react-agent.localhost

# Run tests
pytest -m api_contract -v       # API contract
pytest -m adversarial -v        # Safety
pytest -m "not slow" -v         # Everything except pass@k
pytest -v                       # Everything
```

## Roadmap

| Phase | Focus | Status |
|-------|-------|--------|
| **1. Foundation** | Harness, scorers, reporters, test suites, golden datasets, adversarial payloads, thresholds, prompt regression | Complete |
| **2. Review & Harden** | Interactive test review, upstream bug filing, threshold tuning, MLflow integration | In progress |
| **3. CI/CD & Cross-Framework** | CI/CD integration (TBD), merge gating, cross-framework parity, LLM-as-judge | Not started |
| **4. Production Readiness** | Regression dashboard, RAG quality, model regression baselines, memory/state testing | Not started |

See [COVERAGE.md](./COVERAGE.md) for Jira tracking and detailed gap analysis.

---

## Project Structure

```
agentic-eval-framework/
  README.md                    ← you are here
  CLAUDE.md                    # design philosophy, conventions, contribution guide
  COVERAGE.md                  # per-agent coverage status, Jira tracking
  AGENT-QE.md                  # business case for Agent-QE discipline
  pyproject.toml               # dependencies, pytest marks, entry points
  conftest.py                  # root fixtures (agent_url, http_client, run_eval)
  harness/                     # eval engine
    runner.py                  #   TaskConfig → EvalResult
    mlflow_client.py           #   trace enrichment (tool calls, tokens)
    prompt_regression.py       #   baseline save/load/compare
    scorers/                   #   scoring functions
    reporters/                 #   output formatters
  evals/                       # test suites by agent
    api_contract/              #   shared HTTP contract tests
    langgraph_react/           #   ReAct agent evals
    agentic_rag/               #   RAG agent evals
    autogen_mcp/               #   MCP agent evals
  adversarial/                 # safety + injection tests
  fixtures/                    # golden datasets per agent
    benchmarks/                #   EvalHub benchmark queries
  evalhub_adapter/             # EvalHub framework adapter
  configs/                     # threshold definitions
```

---

## Documentation Guide

| Doc | Purpose | Audience |
|-----|---------|----------|
| [README.md](./README.md) | Project overview, quick start | Everyone |
| [CLAUDE.md](./CLAUDE.md) | Architecture, design philosophy, test conventions | Contributors |
| [COVERAGE.md](./COVERAGE.md) | Per-agent coverage, Jira tracking, gap analysis | QE leads, stakeholders |
| [AGENT-QE.md](./AGENT-QE.md) | Business case for Agent-QE as a discipline | Management, new team members |
