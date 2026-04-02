#!/bin/bash
#
# Shared library for deploy-all scripts
#
# Provides:
#   - Cluster type detection (openshift vs kind)
#   - KUBE_CLI selection (oc vs kubectl)
#   - Container image name construction
#   - Build and load helpers per cluster type
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/deploy-all-lib.sh"
#

## ============================================
# CLUSTER TYPE DETECTION
## ============================================

detect_cluster_type() {
  # Allow explicit override from env
  if [ -n "$CLUSTER_TYPE" ]; then
    echo "$CLUSTER_TYPE"
    return
  fi

  # Auto-detect from current kubectl/oc context
  local context
  context=$(kubectl config current-context 2>/dev/null || true)

  if [[ "$context" == kind-* ]]; then
    echo "kind"
  else
    echo "openshift"
  fi
}

CLUSTER_TYPE="${CLUSTER_TYPE:-$(detect_cluster_type)}"

## ============================================
# KUBE CLI SELECTION
## ============================================

if [ "$CLUSTER_TYPE" = "kind" ]; then
  KUBE_CLI="kubectl"
else
  KUBE_CLI="oc"
fi

## ============================================
# CONTAINER IMAGE HELPERS
## ============================================

# Construct the container image name for a given deploy name.
# For kind: just "deploy_name:latest" (no registry prefix)
# For openshift: "REGISTRY_PREFIX/deploy_name:latest"
container_image_for() {
  local deploy_name="$1"
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    echo "${deploy_name}:latest"
  else
    echo "${REGISTRY_PREFIX}/${deploy_name}:latest"
  fi
}

# Build a container image for the given demo.
# For kind: plain docker build + kind load (no push, no buildx builder isolation)
# For openshift: docker buildx build --push to registry
build_image() {
  local deploy_name="$1"
  local demo_path="$2"
  local container_image="$3"
  local log_file="${4:-}"  # optional log file for parallel builds

  if [ "$CLUSTER_TYPE" = "kind" ]; then
    local kind_cluster
    kind_cluster=$(kubectl config current-context 2>/dev/null | sed 's/^kind-//')
    if [ -n "$log_file" ]; then
      (cd "${SCRIPT_DIR}/${demo_path}" && docker build -t "${container_image}" -f Dockerfile . > "$log_file" 2>&1)
      kind load docker-image "${container_image}" --name "$kind_cluster" >> "$log_file" 2>&1
    else
      (cd "${SCRIPT_DIR}/${demo_path}" && docker build -t "${container_image}" -f Dockerfile .)
      kind load docker-image "${container_image}" --name "$kind_cluster"
    fi
  else
    if [ -n "$log_file" ]; then
      (cd "${SCRIPT_DIR}/${demo_path}" && docker buildx build --platform linux/amd64 -t "${container_image}" -f Dockerfile --push . > "$log_file" 2>&1)
    else
      (cd "${SCRIPT_DIR}/${demo_path}" && docker buildx build --platform linux/amd64 -t "${container_image}" -f Dockerfile --push .)
    fi
  fi
}

## ============================================
# INGRESS HELPERS (kind)
## ============================================

# Generate and apply an Ingress resource for a kind cluster.
# Uses <deploy_name>.localhost as the hostname (resolves to 127.0.0.1 on macOS).
apply_ingress() {
  local deploy_name="$1"
  local hostname="${deploy_name}.localhost"

  cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${deploy_name}
  labels:
    app: ${deploy_name}
spec:
  ingressClassName: nginx
  rules:
  - host: ${hostname}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${deploy_name}
            port:
              number: 8080
EOF
}

# Get the URL for a deployed demo.
# For openshift: https://<route host>
# For kind: http://<deploy_name>.localhost
get_demo_url() {
  local deploy_name="$1"
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    # Verify the ingress actually exists before returning a URL
    if kubectl get ingress "$deploy_name" &>/dev/null; then
      echo "http://${deploy_name}.localhost"
    fi
  else
    local route_host
    route_host=$($KUBE_CLI get route "$deploy_name" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$route_host" ]; then
      echo "https://${route_host}"
    fi
  fi
}
