#!/bin/bash
#
# Tear down all agent demo resources from OpenShift or kind
#
# Usage:
#   ./teardown-all.sh [OPTIONS]
#
# Options:
#   --skip <name>    Skip teardown for a specific demo (repeatable)
#   --only <name>    Only tear down a specific demo (repeatable)
#   --dry-run        Show what would be deleted without doing it
#

set -e  # Exit on error

## ============================================
# CONFIGURATION
## ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library (cluster detection, KUBE_CLI)
source "${SCRIPT_DIR}/deploy-all-lib.sh"

# Demo registry: name|deployment-name|secret-name
DEMOS=(
  "crewai-websearch-agent|crewai-websearch-agent|crewai-websearch-agent-secrets"
  "langgraph-react-agent|langgraph-react-agent|langgraph-react-agent-secrets"
  "langgraph-agentic-rag|langgraph-agentic-rag|langgraph-agentic-rag-secrets"
  "langgraph-db-memory|langgraph-db-memory|langgraph-db-memory-secrets"
  "llamaindex-websearch-agent|llamaindex-websearch-agent|llamaindex-websearch-agent-secrets"
  "openai-responses-agent|openai-responses-agent|openai-responses-agent-secrets"
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

DRY_RUN=false
declare -a SKIP_DEMOS=()
declare -a ONLY_DEMOS=()

## ============================================
# ARGUMENT PARSING
## ============================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
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
# PREREQUISITES
## ============================================

if [ "$CLUSTER_TYPE" = "kind" ]; then
  if ! command -v kubectl &>/dev/null; then
    printf "${RED}Error: kubectl not found${RESET}\n" >&2
    exit 1
  fi
  if ! kubectl cluster-info &>/dev/null; then
    printf "${RED}Error: cannot reach kind cluster${RESET}\n" >&2
    exit 1
  fi
  CURRENT_NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  CURRENT_NS="${CURRENT_NS:-default}"
else
  if ! command -v oc &>/dev/null; then
    printf "${RED}Error: oc CLI not found${RESET}\n" >&2
    exit 1
  fi
  if ! oc whoami &>/dev/null; then
    printf "${RED}Error: not logged in to OpenShift — run oc login${RESET}\n" >&2
    exit 1
  fi
  CURRENT_NS=$(oc project -q 2>/dev/null || echo "unknown")
fi

echo ""
printf "${BOLD}Teardown — namespace: %s${RESET}\n" "$CURRENT_NS"
echo "═══════════════════════════════════════════════════"

if [ "$DRY_RUN" = true ]; then
  printf "${YELLOW}DRY RUN — no resources will be deleted${RESET}\n\n"
fi

## ============================================
# TEARDOWN LOOP
## ============================================

DELETED=0
SKIPPED=0

for entry in "${DEMOS[@]}"; do
  IFS='|' read -r name deploy_name secret_name <<< "$entry"

  if ! demo_included "$name"; then
    printf "  ${YELLOW}—${RESET}  %-30s skipped\n" "$name"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    if [ "$CLUSTER_TYPE" = "kind" ]; then
      printf "  ${BOLD}~${RESET}  %-30s would delete deployment,service,ingress -l app=%s + secret/%s\n" \
        "$name" "$deploy_name" "$secret_name"
    else
      printf "  ${BOLD}~${RESET}  %-30s would delete deployment,service,route -l app=%s + secret/%s\n" \
        "$name" "$deploy_name" "$secret_name"
    fi
  else
    if [ "$CLUSTER_TYPE" = "kind" ]; then
      $KUBE_CLI delete deployment,service,ingress -l app="$deploy_name" --ignore-not-found &>/dev/null
    else
      $KUBE_CLI delete deployment,service,route -l app="$deploy_name" --ignore-not-found &>/dev/null
    fi
    $KUBE_CLI delete secret "$secret_name" --ignore-not-found &>/dev/null
    printf "  ${GREEN}✓${RESET}  %-30s cleaned up\n" "$name"
  fi

  DELETED=$((DELETED + 1))
done

## ============================================
# SUMMARY
## ============================================

echo "═══════════════════════════════════════════════════"
if [ "$DRY_RUN" = true ]; then
  printf "  Would delete: %d demos    Skipped: %d\n" "$DELETED" "$SKIPPED"
else
  printf "  Deleted: %d demos    Skipped: %d\n" "$DELETED" "$SKIPPED"
fi
echo ""
