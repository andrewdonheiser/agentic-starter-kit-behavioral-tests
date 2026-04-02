# Local Kind Cluster

## Cluster

| Property | Value |
|----------|-------|
| Cluster name | `agentic-demos` |
| Kind version | v0.31.0 (go1.25.5 darwin/arm64) |
| Kubernetes | v1.35.0 |
| Container runtime | containerd 2.2.0 |
| Node OS | Debian GNU/Linux 12 (bookworm) |
| Kernel | 6.10.14-linuxkit |
| Docker | 28.3.2 |
| kubectl | v1.32.1 |
| Node | `agentic-demos-control-plane` (single control-plane node) |
| API server | https://127.0.0.1:65143 |

## Deployed Agents

All agents run in the `default` namespace on port 8080, using locally-built `:latest` images. Every agent connects to Ollama on the host via `http://host.docker.internal:11434/v1` with model `qwen2.5:7b`.

| Agent | Deployment | Service | Ingress Host | Image |
|-------|-----------|---------|--------------|-------|
| LangGraph ReAct | `langgraph-react-agent` | `langgraph-react-agent:8080` | `langgraph-react-agent.localhost` | `langgraph-react-agent:latest` |
| LangGraph DB Memory | `langgraph-db-memory` | `langgraph-db-memory:8080` | `langgraph-db-memory.localhost` | `langgraph-db-memory:latest` |
| CrewAI WebSearch | `crewai-websearch-agent` | `crewai-websearch-agent:8080` | `crewai-websearch-agent.localhost` | `crewai-websearch-agent:latest` |
| LlamaIndex WebSearch | `llamaindex-websearch-agent` | `llamaindex-websearch-agent:8080` | `llamaindex-websearch-agent.localhost` | `llamaindex-websearch-agent:latest` |
| OpenAI Responses | `openai-responses-agent` | `openai-responses-agent:8080` | `openai-responses-agent.localhost` | `openai-responses-agent:latest` |

### Agent Environment Variables

All agents share:

| Var | Value |
|-----|-------|
| `PORT` | `8080` |
| `BASE_URL` | `http://host.docker.internal:11434/v1` |
| `MODEL_ID` | `qwen2.5:7b` |
| `API_KEY` | From secret `<agent-name>-secrets` (key: `api-key`) |

Agents with MLflow tracing (ReAct, LlamaIndex WebSearch, CrewAI WebSearch, OpenAI Responses) also have:

| Var | Value |
|-----|-------|
| `MLFLOW_TRACKING_URI` | `http://mlflow:5000` |
| `MLFLOW_EXPERIMENT_NAME` | Set per agent (e.g., `react-agent-evals`) |

DB Memory agent has additional PostgreSQL config:

| Var | Value |
|-----|-------|
| `POSTGRES_HOST` | `postgres` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_DB` | `agent_memory` |
| `POSTGRES_USER` | `postgres` |
| `POSTGRES_PASSWORD` | From secret `langgraph-db-memory-secrets` (key: `postgres-password`) |

## Infrastructure

### MLflow

| Property | Value |
|----------|-------|
| Deployment | `mlflow` |
| Image | `mlflow:v3.10.1` (ghcr.io/mlflow/mlflow:v3.10.1) |
| Service | `mlflow:5000` (ClusterIP) |
| Ingress | `mlflow.localhost` |
| Storage | emptyDir at `/mlflow` |
| Manifest | `deploy/mlflow.yaml` |

Agents with tracing enabled have `MLFLOW_TRACKING_URI=http://mlflow:5000` set. The server is configured with `--allowed-hosts` to accept requests from in-cluster service names.

### PostgreSQL

| Property | Value |
|----------|-------|
| Deployment | `postgres` |
| Image | `postgres:16` |
| Service | `postgres:5432` (ClusterIP) |
| Database | `agent_memory` |
| User | `postgres` |
| Password | From secret `postgres-credentials` (key: `POSTGRES_PASSWORD`) |

### Ingress

| Property | Value |
|----------|-------|
| Controller | nginx-ingress v1.15.0 |
| Service type | LoadBalancer (external-ip pending — use localhost) |
| HTTP port | 80 (NodePort 31729) |
| HTTPS port | 443 (NodePort 31130) |

All agents are accessible via `http://<agent-name>.localhost` through the ingress controller.

### Secrets

| Secret | Namespace | Keys |
|--------|-----------|------|
| `langgraph-react-agent-secrets` | default | `api-key` |
| `langgraph-db-memory-secrets` | default | `api-key`, `postgres-password` |
| `crewai-websearch-agent-secrets` | default | `api-key` |
| `llamaindex-websearch-agent-secrets` | default | `api-key` |
| `openai-responses-agent-secrets` | default | `api-key` |
| `postgres-credentials` | default | `POSTGRES_PASSWORD` |

## Agents Not Deployed

The following agents from agentic-starter-kits are **not** on this cluster:

| Agent | Reason |
|-------|--------|
| Agentic RAG (LangGraph) | Requires Milvus vector DB |
| Human-in-the-Loop (LangGraph) | Requires interactive approval flow |
| MCP Agent (AutoGen) | Requires MCP server (SSE transport) |
| Tool Calling (Langflow) | Requires Langflow runtime |

## Running Tests Against the Cluster

```bash
# Cross-agent tests (any agent)
AGENT_URL=http://langgraph-react-agent.localhost pytest -m api_contract -v

# Agent-specific tests with MLflow trace enrichment
REACT_AGENT_URL=http://langgraph-react-agent.localhost \
  MLFLOW_TRACKING_URI=http://mlflow.localhost \
  MLFLOW_EXPERIMENT_NAME=react-agent-evals \
  pytest evals/langgraph_react/ -v

# All deployed agent URLs
DB_MEMORY_AGENT_URL=http://langgraph-db-memory.localhost
CREWAI_AGENT_URL=http://crewai-websearch-agent.localhost
LLAMAINDEX_AGENT_URL=http://llamaindex-websearch-agent.localhost
OPENAI_RESPONSES_AGENT_URL=http://openai-responses-agent.localhost

# MLflow UI
open http://mlflow.localhost
```
