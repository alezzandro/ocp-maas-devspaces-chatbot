#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 1: Install Operators"
echo "========================================="

echo "1. Creating operator namespaces and subscriptions..."
oc apply -k "${MANIFESTS_DIR}/operators/"

echo "2. Waiting for operator CSVs to succeed..."
echo "   This may take 2-5 minutes..."

# oc wait returns immediately when the selector matches nothing, which is the
# usual state right after the Subscription is created. Poll until the CSV exists.
wait_csv() {
  local ns="$1"
  local selector="$2"
  local label="$3"
  local timeout="${4:-600}"
  local elapsed=0
  local phase=""
  while true; do
    phase=$(oc get csv -n "$ns" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Succeeded" ]]; then
      echo "   ${label}: Succeeded"
      return 0
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      echo "   WARNING: ${label} not Succeeded after ${timeout}s (phase=${phase:-missing})"
      return 0
    fi
    if [[ $((elapsed % 30)) -eq 0 ]]; then
      echo "   Waiting for ${label}... (${elapsed}s / ${timeout}s, phase=${phase:-missing})"
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
}

wait_csv redhat-ods-operator operators.coreos.com/rhods-operator.redhat-ods-operator="" "RHOAI"
wait_csv openshift-operators operators.coreos.com/rhcl-operator.openshift-operators="" "Red Hat Connectivity Link"
wait_csv cert-manager-operator operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator="" "cert-manager"
wait_csv openshift-operators operators.coreos.com/servicemeshoperator3.openshift-operators="" "Service Mesh"
wait_csv openshift-lws-operator operators.coreos.com/leader-worker-set.openshift-lws-operator="" "LeaderWorkerSet"
wait_csv openshift-nfd operators.coreos.com/nfd.openshift-nfd="" "Node Feature Discovery"
wait_csv nvidia-gpu-operator operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator="" "NVIDIA GPU Operator"
wait_csv openshift-operators operators.coreos.com/devspaces.openshift-operators="" "Dev Spaces"
wait_csv openshift-operators operators.coreos.com/web-terminal.openshift-operators="" "Web Terminal" 300
wait_csv openshift-operators operators.coreos.com/cluster-observability-operator.openshift-operators="" "Cluster Observability Operator"
wait_csv openshift-operators operators.coreos.com/opentelemetry-product.openshift-operators="" "OpenTelemetry"
wait_csv openshift-operators operators.coreos.com/tempo-product.openshift-operators="" "Tempo"

echo "3. Installing MCP lifecycle operator (Developer Preview, for MCP Catalog)..."
oc apply -f https://github.com/kubernetes-sigs/mcp-lifecycle-operator/releases/latest/download/install.yaml 2>/dev/null || \
  echo "   WARNING: MCP lifecycle operator install failed. MCP Catalog deploy will be unavailable."
oc wait deployment mcp-lifecycle-operator-controller-manager \
  -n mcp-lifecycle-operator-system --for=condition=Available --timeout=120s 2>/dev/null || true

echo "4. Creating GPU operand instances..."
oc apply -f "${MANIFESTS_DIR}/operators/gpu/nfd-instance.yaml"

echo "   Waiting for NFD to be ready before creating ClusterPolicy..."
sleep 30

oc apply -f "${MANIFESTS_DIR}/operators/gpu/cluster-policy.yaml"

echo "5. Waiting for ClusterPolicy to reach ready state..."
echo "   This takes 5-10 minutes as NVIDIA drivers are installed on GPU nodes..."
oc wait clusterpolicy gpu-cluster-policy \
  --for=jsonpath='{.status.state}'=ready --timeout=600s 2>/dev/null || \
  echo "   WARNING: ClusterPolicy not yet ready. Drivers may still be installing."

echo ""
echo "Phase 1 complete: All operators installed."
echo "========================================="
