#!/bin/bash
#
# Deploy all agent demos to OpenShift or kind (local Kubernetes)
#
# Usage:
#   ./deploy-all.sh [OPTIONS]
#
# Options:
#   --skip <name>        Skip a specific demo (repeatable)
#   --only <name>        Only deploy a specific demo (repeatable)
#   --no-build           Skip the build phase (reuse existing images)
#   --sequential         Build images sequentially instead of in parallel
#   --dry-run            Show what would be done without doing it
#   --smoke-test         Run liveness checks after deployment
#   --smoke-test-full    Run liveness + e2e checks after deployment
#
# Prerequisites:
#   - oc CLI (OpenShift) or kubectl + kind (local) installed
#   - docker or podman installed
#   - envsubst installed (gettext)
#   - Access to container registry (OpenShift) or kind cluster (local)
#   - deploy-all.env file with required variables (see deploy-all.env.example)
#

set -e  # Exit on error

## ============================================
# CONFIGURATION
## ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library (cluster detection, image helpers)
source "${SCRIPT_DIR}/deploy-all-lib.sh"

# Demo registry: name|deployment-name|secret-name|path
DEMOS=(
  "crewai-websearch-agent|crewai-websearch-agent|crewai-websearch-agent-secrets|agents/crewai/websearch_agent"
  "langgraph-react-agent|langgraph-react-agent|langgraph-react-agent-secrets|agents/langgraph/react_agent"
  "langgraph-agentic-rag|langgraph-agentic-rag|langgraph-agentic-rag-secrets|agents/langgraph/agentic_rag"
  "langgraph-db-memory|langgraph-db-memory|langgraph-db-memory-secrets|agents/langgraph/react_with_database_memory"
  "llamaindex-websearch-agent|llamaindex-websearch-agent|llamaindex-websearch-agent-secrets|agents/llamaindex/websearch_agent"
  "openai-responses-agent|openai-responses-agent|openai-responses-agent-secrets|agents/vanilla_python/openai_responses_agent"
)

## ============================================
# COLOR AND OUTPUT HELPERS
## ============================================

if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BOLD=''
  RESET=''
fi

log_info()  { printf "  ${GREEN}✓${RESET}  %s\n" "$1"; }
log_warn()  { printf "  ${YELLOW}⚠${RESET}  %s\n" "$1"; }
log_error() { printf "  ${RED}✗${RESET}  %s\n" "$1"; }
log_step()  { printf "\n${BOLD}▸ %s${RESET}\n" "$1"; }

## ============================================
# ARGUMENT PARSING
## ============================================

NO_BUILD=false
SEQUENTIAL=false
DRY_RUN=false
SMOKE_TEST=""
declare -a SKIP_DEMOS=()
declare -a ONLY_DEMOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)
      [[ -z "$2" || "$2" == --* ]] && echo "Error: --skip requires a value" >&2 && exit 1
      SKIP_DEMOS+=("$2")
      shift 2
      ;;
    --only)
      [[ -z "$2" || "$2" == --* ]] && echo "Error: --only requires a value" >&2 && exit 1
      ONLY_DEMOS+=("$2")
      shift 2
      ;;
    --no-build)
      NO_BUILD=true
      shift
      ;;
    --sequential)
      SEQUENTIAL=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --smoke-test)
      SMOKE_TEST="level1"
      shift
      ;;
    --smoke-test-full)
      SMOKE_TEST="full"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

## ============================================
# DEMO FILTERING
## ============================================

demo_included() {
  local name="$1"

  if [ ${#ONLY_DEMOS[@]} -gt 0 ]; then
    for only in "${ONLY_DEMOS[@]}"; do
      if [ "$only" = "$name" ]; then
        return 0
      fi
    done
    return 1
  fi

  for skip in "${SKIP_DEMOS[@]}"; do
    if [ "$skip" = "$name" ]; then
      return 1
    fi
  done

  return 0
}

## ============================================
# LOAD ENVIRONMENT
## ============================================

log_step "Loading environment"

ENV_FILE="${SCRIPT_DIR}/deploy-all.env"

if [ ! -f "$ENV_FILE" ]; then
  log_error "deploy-all.env not found — copy deploy-all.env.example and fill in values"
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

# Validate shared vars
MISSING_VARS=()
REQUIRED_VARS=(API_KEY BASE_URL MODEL_ID)
if [ "$CLUSTER_TYPE" != "kind" ]; then
  REQUIRED_VARS+=(REGISTRY_PREFIX)
fi
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    MISSING_VARS+=("$var")
  fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  log_error "Missing required variables in deploy-all.env: ${MISSING_VARS[*]}"
  exit 1
fi

log_info "Environment loaded from deploy-all.env"

# Auto-default PostgreSQL vars for kind (deployed by kind-setup.sh)
if [ "$CLUSTER_TYPE" = "kind" ]; then
  POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
  POSTGRES_PORT="${POSTGRES_PORT:-5432}"
  POSTGRES_DB="${POSTGRES_DB:-agent_memory}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
fi

## ============================================
# PER-DEMO VALIDATION
## ============================================

declare -a SKIP_BY_PREREQ=()

# agentic_rag requires EMBEDDING_MODEL and VECTOR_STORE_ID
if demo_included "langgraph-agentic-rag"; then
  RAG_MISSING=()
  for var in EMBEDDING_MODEL VECTOR_STORE_ID; do
    if [ -z "${!var}" ]; then
      RAG_MISSING+=("$var")
    fi
  done
  if [ ${#RAG_MISSING[@]} -gt 0 ]; then
    if [ ${#ONLY_DEMOS[@]} -gt 0 ]; then
      log_error "langgraph-agentic-rag requires: ${RAG_MISSING[*]}"
      exit 1
    fi
    log_warn "Skipping langgraph-agentic-rag — missing: ${RAG_MISSING[*]}"
    SKIP_BY_PREREQ+=("langgraph-agentic-rag")
  fi
fi

# react_with_database_memory requires POSTGRES_* vars
if demo_included "langgraph-db-memory"; then
  PG_MISSING=()
  for var in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
    if [ -z "${!var}" ]; then
      PG_MISSING+=("$var")
    fi
  done
  if [ ${#PG_MISSING[@]} -gt 0 ]; then
    if [ ${#ONLY_DEMOS[@]} -gt 0 ]; then
      log_error "langgraph-db-memory requires: ${PG_MISSING[*]}"
      exit 1
    fi
    log_warn "Skipping langgraph-db-memory — missing: ${PG_MISSING[*]}"
    SKIP_BY_PREREQ+=("langgraph-db-memory")
  fi
fi

demo_skipped_by_prereq() {
  local name="$1"
  for s in "${SKIP_BY_PREREQ[@]}"; do
    if [ "$s" = "$name" ]; then
      return 0
    fi
  done
  return 1
}

## ============================================
# PREFLIGHT CHECKS
## ============================================

log_step "Running preflight checks"

if [ "$DRY_RUN" = true ]; then
  log_info "Dry run — skipping preflight checks"
else
  PREFLIGHT_ARGS=()
  for s in "${SKIP_DEMOS[@]}"; do
    PREFLIGHT_ARGS+=("--skip" "$s")
  done
  for o in "${ONLY_DEMOS[@]}"; do
    PREFLIGHT_ARGS+=("--only" "$o")
  done

  if ! "${SCRIPT_DIR}/preflight-check.sh" "${PREFLIGHT_ARGS[@]}"; then
    log_error "Preflight checks failed — aborting"
    exit 1
  fi

  # Read additional skips from preflight
  SKIP_FILE="${TMPDIR:-/tmp}/preflight-skip-demos"
  if [ -f "$SKIP_FILE" ]; then
    while IFS= read -r line; do
      skip_name="${line#SKIP:}"
      if [ -n "$skip_name" ]; then
        SKIP_BY_PREREQ+=("$skip_name")
      fi
    done < "$SKIP_FILE"
  fi
fi

## ============================================
# BUILD ACTIVE DEMO LIST
## ============================================

declare -a ACTIVE_DEMOS=()

for entry in "${DEMOS[@]}"; do
  IFS='|' read -r name _ _ _ <<< "$entry"
  if demo_included "$name" && ! demo_skipped_by_prereq "$name"; then
    ACTIVE_DEMOS+=("$entry")
  fi
done

if [ ${#ACTIVE_DEMOS[@]} -eq 0 ]; then
  log_warn "No demos to deploy"
  exit 0
fi

log_info "Deploying ${#ACTIVE_DEMOS[@]} demo(s)"

## ============================================
# BUILD PHASE
## ============================================

if [ "$NO_BUILD" = true ]; then
  log_step "Build phase (skipped — --no-build)"
else
  log_step "Building container images"

  if [ "$DRY_RUN" = true ]; then
    for entry in "${ACTIVE_DEMOS[@]}"; do
      IFS='|' read -r name deploy_name _ demo_path <<< "$entry"
      CONTAINER_IMAGE=$(container_image_for "$deploy_name")
      log_info "[dry-run] Would build ${CONTAINER_IMAGE} from ${demo_path}"
    done
  elif [ "$SEQUENTIAL" = true ]; then
    for entry in "${ACTIVE_DEMOS[@]}"; do
      IFS='|' read -r name deploy_name _ demo_path <<< "$entry"
      export CONTAINER_IMAGE=$(container_image_for "$deploy_name")
      log_info "Building ${deploy_name}..."
      build_image "$deploy_name" "$demo_path" "$CONTAINER_IMAGE"
      log_info "Built ${deploy_name}"
    done
  else
    # Parallel builds
    declare -a BUILD_PIDS=()
    declare -a BUILD_NAMES=()
    BUILD_LOG_DIR="${TMPDIR:-/tmp}/deploy-all-builds-$$"
    mkdir -p "$BUILD_LOG_DIR"

    for entry in "${ACTIVE_DEMOS[@]}"; do
      IFS='|' read -r name deploy_name _ demo_path <<< "$entry"
      CONTAINER_IMAGE=$(container_image_for "$deploy_name")
      log_info "Starting build: ${deploy_name}..."
      build_image "$deploy_name" "$demo_path" "$CONTAINER_IMAGE" "${BUILD_LOG_DIR}/${deploy_name}.log" &
      BUILD_PIDS+=($!)
      BUILD_NAMES+=("$deploy_name")
    done

    # Wait for all builds
    BUILD_FAILURES=()
    for i in "${!BUILD_PIDS[@]}"; do
      if wait "${BUILD_PIDS[$i]}"; then
        log_info "Built ${BUILD_NAMES[$i]}"
      else
        log_error "Build failed: ${BUILD_NAMES[$i]} (see ${BUILD_LOG_DIR}/${BUILD_NAMES[$i]}.log)"
        BUILD_FAILURES+=("${BUILD_NAMES[$i]}")
      fi
    done

    if [ ${#BUILD_FAILURES[@]} -gt 0 ]; then
      log_error "Build failures: ${BUILD_FAILURES[*]}"
      log_error "Aborting deployment"
      exit 1
    fi

    rm -rf "$BUILD_LOG_DIR"
  fi
fi

## ============================================
# DEPLOY PHASE
## ============================================

if [ "$CLUSTER_TYPE" = "kind" ]; then
  log_step "Deploying to kind cluster"
else
  log_step "Deploying to OpenShift"
fi

# Status tracking (bash 3.x compat — no associative arrays)
declare -a _STATUS_KEYS=()
declare -a _STATUS_VALS=()
set_status() { _STATUS_KEYS+=("$1"); _STATUS_VALS+=("$2"); }
get_status() {
  local key="$1" i
  for i in "${!_STATUS_KEYS[@]}"; do
    if [ "${_STATUS_KEYS[$i]}" = "$key" ]; then echo "${_STATUS_VALS[$i]}"; return; fi
  done
  echo "unknown"
}

for entry in "${ACTIVE_DEMOS[@]}"; do
  IFS='|' read -r name deploy_name secret_name demo_path <<< "$entry"
  export CONTAINER_IMAGE=$(container_image_for "$deploy_name")

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would deploy ${deploy_name}"
    set_status "$deploy_name" "dry-run"
    continue
  fi

  printf "  Deploying %-30s" "${deploy_name}..."

  # Export demo-specific vars for envsubst
  case "$deploy_name" in
    langgraph-agentic-rag)
      export EMBEDDING_MODEL VECTOR_STORE_ID VECTOR_STORE_NAME
      ;;
    langgraph-db-memory)
      export POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER
      ;;
  esac

  # Create secret
  $KUBE_CLI delete secret "$secret_name" --ignore-not-found &>/dev/null

  case "$deploy_name" in
    langgraph-db-memory)
      $KUBE_CLI create secret generic "$secret_name" \
        --from-literal=api-key="${API_KEY}" \
        --from-literal=postgres-password="${POSTGRES_PASSWORD}" &>/dev/null
      ;;
    *)
      $KUBE_CLI create secret generic "$secret_name" \
        --from-literal=api-key="${API_KEY}" &>/dev/null
      ;;
  esac

  # Delete old resources
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    $KUBE_CLI delete deployment,service,ingress -l app="$deploy_name" --ignore-not-found &>/dev/null
  else
    $KUBE_CLI delete deployment,service,route -l app="$deploy_name" --ignore-not-found &>/dev/null
  fi

  # Apply manifests
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    # For kind: set imagePullPolicy to Never (images loaded via kind load)
    (cd "${SCRIPT_DIR}/${demo_path}" && \
      envsubst < k8s/deployment.yaml | sed 's|image: .*|&\'$'\n''        imagePullPolicy: Never|' | $KUBE_CLI apply -f - &>/dev/null && \
      $KUBE_CLI apply -f k8s/service.yaml &>/dev/null)
    apply_ingress "$deploy_name"
  else
    (cd "${SCRIPT_DIR}/${demo_path}" && \
      envsubst < k8s/deployment.yaml | $KUBE_CLI apply -f - &>/dev/null && \
      $KUBE_CLI apply -f k8s/service.yaml &>/dev/null && \
      $KUBE_CLI apply -f k8s/route.yaml &>/dev/null)
  fi

  printf " ${GREEN}done${RESET}\n"
  set_status "$deploy_name" "deployed"
done

## ============================================
# VERIFY PHASE
## ============================================

if [ "$DRY_RUN" = false ]; then
  log_step "Verifying rollouts"

  for entry in "${ACTIVE_DEMOS[@]}"; do
    IFS='|' read -r name deploy_name _ _ <<< "$entry"
    printf "  Waiting for %-30s" "${deploy_name}..."

    if $KUBE_CLI rollout status deployment/"$deploy_name" --timeout=300s &>/dev/null; then
      printf " ${GREEN}ready${RESET}\n"
    else
      printf " ${RED}timeout${RESET}\n"
      set_status "$deploy_name" "timeout"
    fi
  done
fi

## ============================================
# SUMMARY
## ============================================

log_step "Deployment Summary"

echo "═══════════════════════════════════════════════════════════════════════════════════"
printf "  %-30s %-12s %s\n" "Demo" "Status" "URL"
echo "─────────────────────────────────────────────────────────────────────────────────"

for entry in "${DEMOS[@]}"; do
  IFS='|' read -r name deploy_name _ _ <<< "$entry"

  if ! demo_included "$name" || demo_skipped_by_prereq "$name"; then
    printf "  %-30s ${YELLOW}skipped${RESET}\n" "$deploy_name"
    continue
  fi

  STATUS=$(get_status "$deploy_name")
  ROUTE_URL=""

  if [ "$DRY_RUN" = false ]; then
    ROUTE_URL=$(get_demo_url "$deploy_name")
  fi

  case "$STATUS" in
    deployed)
      printf "  %-30s ${GREEN}%-12s${RESET} %s\n" "$deploy_name" "deployed" "$ROUTE_URL"
      ;;
    timeout)
      printf "  %-30s ${RED}%-12s${RESET} %s\n" "$deploy_name" "timeout" "$ROUTE_URL"
      ;;
    dry-run)
      printf "  %-30s ${YELLOW}%-12s${RESET}\n" "$deploy_name" "dry-run"
      ;;
    *)
      printf "  %-30s ${RED}%-12s${RESET}\n" "$deploy_name" "$STATUS"
      ;;
  esac
done

echo "═══════════════════════════════════════════════════════════════════════════════════"

# Langflow note
echo ""
printf "  ${YELLOW}Note:${RESET} The Langflow demo (langflow/simple_tool_calling_agent) requires manual setup.\n"
printf "  Import the flow JSON into your existing Langflow instance. See its README for details.\n"
echo ""

## ============================================
# SMOKE TESTS
## ============================================

if [ -n "$SMOKE_TEST" ] && [ "$DRY_RUN" = false ]; then
  SMOKE_ARGS=()
  for s in "${SKIP_DEMOS[@]}"; do
    SMOKE_ARGS+=("--skip" "$s")
  done
  for o in "${ONLY_DEMOS[@]}"; do
    SMOKE_ARGS+=("--only" "$o")
  done
  for s in "${SKIP_BY_PREREQ[@]}"; do
    SMOKE_ARGS+=("--skip" "$s")
  done

  if [ "$SMOKE_TEST" = "level1" ]; then
    SMOKE_ARGS+=("--level" "1")
  fi

  "${SCRIPT_DIR}/smoke-test.sh" "${SMOKE_ARGS[@]}"
fi
