#!/bin/bash
#
# Smoke test all deployed agent demos on OpenShift or kind
#
# Usage:
#   ./smoke-test.sh [OPTIONS]
#
# Options:
#   --level 1|2       Run only liveness (1) or e2e (2) checks (default: both)
#   --only <name>     Only test a specific demo (repeatable)
#   --skip <name>     Skip a specific demo (repeatable)
#   --timeout <secs>  Override default timeouts
#   --insecure        Use curl -k for self-signed certs
#

set -e  # Exit on error

## ============================================
# CONFIGURATION
## ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library (cluster detection, URL helpers)
source "${SCRIPT_DIR}/deploy-all-lib.sh"

DEMOS=(
  "crewai-websearch-agent"
  "langgraph-react-agent"
  "langgraph-agentic-rag"
  "langgraph-db-memory"
  "llamaindex-websearch-agent"
  "openai-responses-agent"
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

## ============================================
# ARGUMENT PARSING
## ============================================

LEVEL=""
HEALTH_TIMEOUT=10
CHAT_TIMEOUT=60
INSECURE=""
declare -a SKIP_DEMOS=()
declare -a ONLY_DEMOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      LEVEL="$2"
      shift 2
      ;;
    --only)
      [[ -z "$2" || "$2" == --* ]] && echo "Error: --only requires a value" >&2 && exit 1
      ONLY_DEMOS+=("$2")
      shift 2
      ;;
    --skip)
      [[ -z "$2" || "$2" == --* ]] && echo "Error: --skip requires a value" >&2 && exit 1
      SKIP_DEMOS+=("$2")
      shift 2
      ;;
    --timeout)
      HEALTH_TIMEOUT="$2"
      CHAT_TIMEOUT="$2"
      shift 2
      ;;
    --insecure)
      INSECURE="-k"
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
else
  if ! command -v oc &>/dev/null; then
    printf "${RED}Error: oc CLI not found${RESET}\n" >&2
    exit 1
  fi
  if ! oc whoami &>/dev/null; then
    printf "${RED}Error: not logged in to OpenShift — run oc login${RESET}\n" >&2
    exit 1
  fi
fi

## ============================================
# SMOKE TESTS
## ============================================

echo ""
printf "${BOLD}Smoke Test Results${RESET}\n"
echo "═══════════════════════════════════════════════════════════════════════════════════"
printf "  %-30s %-10s %-10s %s\n" "Demo" "Health" "Chat" "URL"
echo "─────────────────────────────────────────────────────────────────────────────────"

PASSED=0
FAILED=0
SKIPPED=0

for name in "${DEMOS[@]}"; do
  if ! demo_included "$name"; then
    printf "  %-30s ${YELLOW}- SKIP${RESET}    ${YELLOW}- SKIP${RESET}    (filtered)\n" "$name"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Get demo URL
  ROUTE_URL=$(get_demo_url "$name")

  if [ -z "$ROUTE_URL" ]; then
    printf "  %-30s ${YELLOW}- SKIP${RESET}    ${YELLOW}- SKIP${RESET}    (not deployed)\n" "$name"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  HEALTH_RESULT=""
  CHAT_RESULT=""
  DEMO_FAILED=false

  # Level 1: Health check
  if [ "$LEVEL" != "2" ]; then
    HEALTH_RESPONSE=$(curl -sf $INSECURE --max-time "$HEALTH_TIMEOUT" "${ROUTE_URL}/health" 2>/dev/null || true)

    if [ -n "$HEALTH_RESPONSE" ] && echo "$HEALTH_RESPONSE" | grep -q '"status"'; then
      HEALTH_RESULT="${GREEN}✓ PASS${RESET}"
    else
      HEALTH_RESULT="${RED}✗ FAIL${RESET}"
      DEMO_FAILED=true
    fi
  else
    HEALTH_RESULT="${YELLOW}- SKIP${RESET}"
  fi

  # Level 2: Chat completion check
  if [ "$LEVEL" != "1" ]; then
    CHAT_RESPONSE=$(curl -sf $INSECURE --max-time "$CHAT_TIMEOUT" \
      "${ROUTE_URL}/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{"messages": [{"role": "user", "content": "Say hello in one word."}]}' \
      2>/dev/null || true)

    if [ -n "$CHAT_RESPONSE" ] && echo "$CHAT_RESPONSE" | grep -q '"choices"'; then
      CHAT_RESULT="${GREEN}✓ PASS${RESET}"
    else
      CHAT_RESULT="${RED}✗ FAIL${RESET}"
      DEMO_FAILED=true
    fi
  else
    CHAT_RESULT="${YELLOW}- SKIP${RESET}"
  fi

  printf "  %-30s ${HEALTH_RESULT}    ${CHAT_RESULT}    %s\n" "$name" "$ROUTE_URL"

  if [ "$DEMO_FAILED" = true ]; then
    FAILED=$((FAILED + 1))
  else
    PASSED=$((PASSED + 1))
  fi
done

echo "═══════════════════════════════════════════════════════════════════════════════════"
printf "  Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}\n" "$PASSED" "$FAILED" "$SKIPPED"
echo ""

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
