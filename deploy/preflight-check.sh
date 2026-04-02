#!/bin/bash
#
# Preflight checks for deploying all agent demos to OpenShift or kind
#
# Usage:
#   ./preflight-check.sh [OPTIONS]
#
# Options:
#   --strict         Treat warnings as errors (abort instead of skip)
#   --skip <name>    Skip checks for a specific demo (repeatable)
#   --only <name>    Only check prereqs for a specific demo (repeatable)
#   --quiet          Suppress info output, only show failures
#
# Exit codes:
#   0  All critical checks passed
#   1  One or more critical checks failed
#

set -e  # Exit on error

## ============================================
# CONFIGURATION
## ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library (cluster detection, image helpers)
source "${SCRIPT_DIR}/deploy-all-lib.sh"

SKIP_FILE="${TMPDIR:-/tmp}/preflight-skip-demos.$$"

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

STRICT=false
QUIET=false
declare -a SKIP_DEMOS=()
declare -a ONLY_DEMOS=()
CRITICAL_FAIL=false
declare -a SKIPPED_DEMOS=()
declare -a READY_DEMOS=()

print_pass() {
  [ "$QUIET" = true ] && return
  printf "  ${GREEN}✓${RESET}  %-25s %s\n" "$1" "$2"
}

print_warn() {
  if [ "$STRICT" = true ]; then
    printf "  ${RED}✗${RESET}  %-25s %s\n" "$1" "$2"
  else
    [ "$QUIET" = true ] && return
    printf "  ${YELLOW}⚠${RESET}  %-25s %s\n" "$1" "$2"
  fi
}

print_fail() {
  printf "  ${RED}✗${RESET}  %-25s %s\n" "$1" "$2"
}

print_info() {
  [ "$QUIET" = true ] && return
  printf "  ${BOLD}i${RESET}  %-25s %s\n" "$1" "$2"
}

## ============================================
# ARGUMENT PARSING
## ============================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
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
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

## ============================================
# LOAD ENVIRONMENT (if not already set)
## ============================================

ENV_FILE="${SCRIPT_DIR}/deploy-all.env"
if [ -f "$ENV_FILE" ] && [ -z "$API_KEY" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

## ============================================
# DEMO FILTERING
## ============================================

demo_included() {
  local name="$1"

  # If --only is specified, only include those demos
  if [ ${#ONLY_DEMOS[@]} -gt 0 ]; then
    for only in "${ONLY_DEMOS[@]}"; do
      if [ "$only" = "$name" ]; then
        return 0
      fi
    done
    return 1
  fi

  # If --skip is specified, exclude those demos
  for skip in "${SKIP_DEMOS[@]}"; do
    if [ "$skip" = "$name" ]; then
      return 1
    fi
  done

  return 0
}

skip_demo() {
  local name="$1"
  SKIPPED_DEMOS+=("$name")
  echo "SKIP:${name}" >> "$SKIP_FILE"
}

## ============================================
# PREFLIGHT CHECKS
## ============================================

[ "$QUIET" = true ] || echo ""
[ "$QUIET" = true ] || printf "${BOLD}Preflight Checks${RESET}\n"
[ "$QUIET" = true ] || echo "═══════════════════════════════════════════════════"

# Initialize skip file
> "$SKIP_FILE"

# --- Critical checks ---

if [ "$CLUSTER_TYPE" = "kind" ]; then
  # 1. kubectl CLI installed
  if command -v kubectl &>/dev/null; then
    KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | sed 's/.*"v//' | sed 's/".*//' || echo "unknown")
    print_pass "kubectl CLI" "installed (${KUBECTL_VERSION})"
  else
    print_fail "kubectl CLI" "not found — install kubectl"
    CRITICAL_FAIL=true
  fi

  # 2. kind CLI installed
  if command -v kind &>/dev/null; then
    KIND_VERSION=$(kind version 2>/dev/null | sed 's/kind //' | awk '{print $1}' || echo "unknown")
    print_pass "kind CLI" "installed (${KIND_VERSION})"
  else
    print_fail "kind CLI" "not found — install kind"
    CRITICAL_FAIL=true
  fi

  # 3. kind cluster reachable
  if [ "$CRITICAL_FAIL" = false ] && kubectl cluster-info &>/dev/null; then
    CONTEXT=$(kubectl config current-context 2>/dev/null)
    print_pass "Cluster reachable" "${CONTEXT}"
  else
    if [ "$CRITICAL_FAIL" = false ]; then
      print_fail "Cluster reachable" "cannot reach kind cluster — run ./kind-setup.sh"
      CRITICAL_FAIL=true
    fi
  fi
else
  # 1. oc CLI installed
  if command -v oc &>/dev/null; then
    OC_VERSION=$(oc version --client 2>/dev/null | head -1 | sed 's/.*: *//' || echo "unknown")
    print_pass "oc CLI" "installed (${OC_VERSION})"
  else
    print_fail "oc CLI" "not found — install the oc CLI"
    CRITICAL_FAIL=true
  fi

  # 2. oc logged in
  if [ "$CRITICAL_FAIL" = false ] && oc whoami &>/dev/null; then
    OC_USER=$(oc whoami 2>/dev/null)
    OC_SERVER=$(oc whoami --show-server 2>/dev/null)
    print_pass "oc logged in" "${OC_USER} @ ${OC_SERVER}"
  else
    if [ "$CRITICAL_FAIL" = false ]; then
      print_fail "oc logged in" "not logged in — run oc login"
      CRITICAL_FAIL=true
    fi
  fi
fi

# 3. docker or podman installed
CONTAINER_RUNTIME=""
if command -v docker &>/dev/null; then
  CONTAINER_RUNTIME="docker"
  CR_VERSION=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
  print_pass "docker" "installed (${CR_VERSION})"
elif command -v podman &>/dev/null; then
  CONTAINER_RUNTIME="podman"
  CR_VERSION=$(podman --version 2>/dev/null | sed 's/podman version //' || echo "unknown")
  print_pass "podman" "installed (${CR_VERSION})"
else
  print_fail "Container runtime" "neither docker nor podman found"
  CRITICAL_FAIL=true
fi

# 4. envsubst installed
if command -v envsubst &>/dev/null; then
  print_pass "envsubst" "installed"
else
  print_fail "envsubst" "not found — install gettext"
  CRITICAL_FAIL=true
fi

# 5. Container registry reachable (not needed for kind — images loaded directly)
if [ "$CLUSTER_TYPE" = "kind" ]; then
  print_pass "Registry access" "not needed (kind loads images directly)"
elif [ -n "$REGISTRY_PREFIX" ] && [ -n "$CONTAINER_RUNTIME" ]; then
  REGISTRY_HOST="${REGISTRY_PREFIX%%/*}"
  if $CONTAINER_RUNTIME login --get-login "$REGISTRY_HOST" &>/dev/null 2>&1; then
    print_pass "Registry access" "${REGISTRY_HOST}"
  else
    print_fail "Registry access" "cannot authenticate to ${REGISTRY_HOST}"
    CRITICAL_FAIL=true
  fi
elif [ -z "$REGISTRY_PREFIX" ]; then
  # Will be caught by env var check below
  :
fi

# 6-9. Required env vars
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

if [ ${#MISSING_VARS[@]} -eq 0 ]; then
  print_pass "Shared env vars" "${REQUIRED_VARS[*]}"
else
  print_fail "Shared env vars" "${MISSING_VARS[*]} not set"
  CRITICAL_FAIL=true
fi

# --- Warning checks ---

# 10. LLM endpoint reachable
if [ -n "$BASE_URL" ]; then
  if curl -sf --max-time 10 "${BASE_URL}/v1/models" &>/dev/null; then
    print_pass "LLM endpoint" "BASE_URL reachable"
  else
    print_warn "LLM endpoint" "BASE_URL not reachable from local (may work in-cluster)"
    if [ "$STRICT" = true ]; then
      CRITICAL_FAIL=true
    fi
  fi
fi

# 11. PostgreSQL (affects react_with_database_memory)
if demo_included "langgraph-db-memory"; then
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    # For kind, PostgreSQL is deployed by kind-setup.sh — check it's running
    if kubectl get deployment postgres &>/dev/null && \
       kubectl get pod -l app=postgres -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
      print_pass "PostgreSQL (in-cluster)" "running in kind cluster"
    else
      print_warn "PostgreSQL (in-cluster)" "not running — run ./kind-setup.sh first"
      skip_demo "langgraph-db-memory"
      if [ "$STRICT" = true ]; then
        CRITICAL_FAIL=true
      fi
    fi
  else
    PG_MISSING=()
    for var in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
      if [ -z "${!var}" ]; then
        PG_MISSING+=("$var")
      fi
    done

    if [ ${#PG_MISSING[@]} -eq 0 ]; then
      print_pass "PostgreSQL vars" "all POSTGRES_* vars set"

      # 12. PostgreSQL reachable
      if command -v pg_isready &>/dev/null; then
        if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -d "$POSTGRES_DB" -U "$POSTGRES_USER" &>/dev/null; then
          print_pass "PostgreSQL reachable" "${POSTGRES_HOST}:${POSTGRES_PORT}"
        else
          print_warn "PostgreSQL reachable" "pg_isready failed (may work in-cluster)"
          if [ "$STRICT" = true ]; then
            skip_demo "langgraph-db-memory"
          fi
        fi
      fi
    else
      print_warn "PostgreSQL vars" "${PG_MISSING[*]} not set -> skipping react_with_database_memory"
      skip_demo "langgraph-db-memory"
      if [ "$STRICT" = true ]; then
        CRITICAL_FAIL=true
      fi
    fi
  fi
fi

# 13. RAG vars (affects agentic_rag)
if demo_included "langgraph-agentic-rag"; then
  RAG_MISSING=()
  for var in EMBEDDING_MODEL VECTOR_STORE_ID; do
    if [ -z "${!var}" ]; then
      RAG_MISSING+=("$var")
    fi
  done

  if [ ${#RAG_MISSING[@]} -eq 0 ]; then
    print_pass "RAG vars" "EMBEDDING_MODEL, VECTOR_STORE_ID set"
  else
    print_warn "RAG vars" "${RAG_MISSING[*]} not set -> skipping agentic_rag"
    skip_demo "langgraph-agentic-rag"
    if [ "$STRICT" = true ]; then
      CRITICAL_FAIL=true
    fi
  fi
fi

# 14. Namespace writable
if [ "$CRITICAL_FAIL" = false ]; then
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    if kubectl auth can-i create deployments &>/dev/null; then
      CURRENT_NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
      CURRENT_NS="${CURRENT_NS:-default}"
      print_pass "Namespace writable" "${CURRENT_NS}"
    else
      print_warn "Namespace writable" "cannot create deployments in current namespace"
      if [ "$STRICT" = true ]; then
        CRITICAL_FAIL=true
      fi
    fi
  elif command -v oc &>/dev/null && oc whoami &>/dev/null; then
    if oc auth can-i create deployments &>/dev/null; then
      CURRENT_NS=$(oc project -q 2>/dev/null || echo "unknown")
      print_pass "Namespace writable" "${CURRENT_NS}"
    else
      print_warn "Namespace writable" "cannot create deployments in current namespace"
      if [ "$STRICT" = true ]; then
        CRITICAL_FAIL=true
      fi
    fi
  fi
fi

# --- Info checks ---

if [ "$QUIET" = false ]; then
  print_info "Cluster type" "${CLUSTER_TYPE}"

  if [ "$CLUSTER_TYPE" = "kind" ]; then
    CURRENT_NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    CURRENT_NS="${CURRENT_NS:-default}"
    print_info "Current namespace" "${CURRENT_NS}"
    print_info "Context" "$(kubectl config current-context 2>/dev/null)"
  elif command -v oc &>/dev/null && oc whoami &>/dev/null; then
    CURRENT_NS=$(oc project -q 2>/dev/null || echo "unknown")
    print_info "Current namespace" "${CURRENT_NS}"
    print_info "Cluster API URL" "$(oc whoami --show-server 2>/dev/null)"
  fi

  if [ -n "$CONTAINER_RUNTIME" ]; then
    print_info "Container runtime" "${CONTAINER_RUNTIME} ${CR_VERSION}"
  fi
fi

## ============================================
# BUILD SUMMARY
## ============================================

# Determine which demos are ready vs skipped
for entry in "${DEMOS[@]}"; do
  IFS='|' read -r name _ _ _ <<< "$entry"

  if ! demo_included "$name"; then
    SKIPPED_DEMOS+=("$name")
    continue
  fi

  # Check if demo was skipped during checks
  already_skipped=false
  for s in "${SKIPPED_DEMOS[@]}"; do
    if [ "$s" = "$name" ]; then
      already_skipped=true
      break
    fi
  done

  if [ "$already_skipped" = false ]; then
    READY_DEMOS+=("$name")
  fi
done

TOTAL=${#DEMOS[@]}
READY_COUNT=${#READY_DEMOS[@]}
SKIPPED_COUNT=${#SKIPPED_DEMOS[@]}

if [ "$QUIET" = false ]; then
  echo "═══════════════════════════════════════════════════"
  if [ $SKIPPED_COUNT -gt 0 ]; then
    SKIPPED_LIST=$(IFS=', '; echo "${SKIPPED_DEMOS[*]}")
    printf "  Ready: %d/%d demos    Skipped: %d (%s)\n" "$READY_COUNT" "$TOTAL" "$SKIPPED_COUNT" "$SKIPPED_LIST"
  else
    printf "  Ready: %d/%d demos\n" "$READY_COUNT" "$TOTAL"
  fi
  echo ""
fi

# Output skip lines to stderr for deploy-all.sh to capture
for s in "${SKIPPED_DEMOS[@]}"; do
  echo "SKIP:${s}" >&2
done

# Write skip list to known temp file for deploy-all.sh
cat "$SKIP_FILE" > "${TMPDIR:-/tmp}/preflight-skip-demos"

# Clean up per-process file
rm -f "$SKIP_FILE"

if [ "$CRITICAL_FAIL" = true ]; then
  [ "$QUIET" = true ] || printf "${RED}Preflight failed — fix critical errors above before deploying.${RESET}\n\n"
  exit 1
fi

exit 0
