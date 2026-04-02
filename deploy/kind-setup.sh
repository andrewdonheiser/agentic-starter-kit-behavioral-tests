#!/bin/bash
#
# Create or delete a kind cluster for local development
#
# Usage:
#   ./kind-setup.sh              Create a kind cluster with nginx ingress
#   ./kind-setup.sh --delete     Delete the kind cluster
#
# The cluster is configured with:
#   - nginx ingress controller (maps to host ports 80/443)
#   - PostgreSQL database (for langgraph-db-memory demo)
#   - Agents accessible at <name>.localhost (e.g. langgraph-react-agent.localhost)
#
# Notes:
#   - On macOS, *.localhost resolves to 127.0.0.1 automatically
#   - On Linux, you may need to add entries to /etc/hosts:
#       127.0.0.1 crewai-websearch-agent.localhost langgraph-react-agent.localhost ...
#     Or configure systemd-resolved to resolve *.localhost to 127.0.0.1
#

set -e

CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentic-demos}"

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

DELETE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete)
      DELETE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--delete]" >&2
      exit 1
      ;;
  esac
done

## ============================================
# PREREQUISITES
## ============================================

for cmd in kind kubectl docker; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "$cmd is required but not found"
    exit 1
  fi
done

## ============================================
# DELETE MODE
## ============================================

if [ "$DELETE" = true ]; then
  log_step "Deleting kind cluster: ${CLUSTER_NAME}"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "$CLUSTER_NAME"
    log_info "Cluster deleted"
  else
    log_warn "Cluster '${CLUSTER_NAME}' does not exist"
  fi
  exit 0
fi

## ============================================
# CREATE CLUSTER
## ============================================

log_step "Creating kind cluster: ${CLUSTER_NAME}"

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  log_warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
  log_info "To recreate, run: $0 --delete && $0"
else
  # Create cluster with ingress-ready config
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
  log_info "Cluster created"
fi

## ============================================
# INSTALL NGINX INGRESS
## ============================================

log_step "Installing nginx ingress controller"

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml &>/dev/null

log_info "Nginx ingress manifests applied"
log_info "Waiting for ingress controller to be ready..."

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s &>/dev/null

log_info "Nginx ingress controller is ready"

## ============================================
# DEPLOY POSTGRESQL
## ============================================

log_step "Deploying PostgreSQL (for langgraph-db-memory)"

cat <<'EOF' | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  labels:
    app: postgres
stringData:
  POSTGRES_PASSWORD: "postgres"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: agent_memory
        - name: POSTGRES_USER
          value: postgres
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: POSTGRES_PASSWORD
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
          periodSeconds: 5
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: pgdata
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: postgres
EOF

log_info "PostgreSQL manifests applied"

# Load postgres image into kind to avoid pull delays
kind load docker-image postgres:16 --name "$CLUSTER_NAME" 2>/dev/null || true

log_info "Waiting for PostgreSQL to be ready..."

kubectl wait --for=condition=ready pod \
  --selector=app=postgres \
  --timeout=120s &>/dev/null

log_info "PostgreSQL is ready (postgres:5432, db=agent_memory, user=postgres, password=postgres)"

## ============================================
# LINUX DNS HINT
## ============================================

if [[ "$(uname)" == "Linux" ]]; then
  echo ""
  log_warn "Linux detected: *.localhost may not resolve to 127.0.0.1 by default"
  log_warn "If agents are unreachable, add entries to /etc/hosts:"
  echo "    127.0.0.1 crewai-websearch-agent.localhost langgraph-react-agent.localhost langgraph-agentic-rag.localhost langgraph-db-memory.localhost llamaindex-websearch-agent.localhost openai-responses-agent.localhost"
fi

## ============================================
# SUMMARY
## ============================================

echo ""
log_step "Kind cluster ready"
log_info "Cluster: ${CLUSTER_NAME}"
log_info "Context: kind-${CLUSTER_NAME}"
log_info "Ingress: nginx (ports 80/443 on localhost)"
log_info "PostgreSQL: postgres:5432 (db=agent_memory, user=postgres, pw=postgres)"
echo ""
printf "  Next steps:\n"
printf "    1. Copy deploy-all.env.example to deploy-all.env and fill in values\n"
printf "       (REGISTRY_PREFIX and POSTGRES_* are not needed — pre-configured for kind)\n"
printf "    2. Run: ./deploy-all.sh\n"
echo ""
