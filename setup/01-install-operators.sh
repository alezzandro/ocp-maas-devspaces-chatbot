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

oc wait csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for RHOAI..."

oc wait csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for RHCL..."

oc wait csv -n cert-manager-operator -l operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for cert-manager..."

oc wait csv -n openshift-operators -l operators.coreos.com/servicemeshoperator3.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for Service Mesh..."

oc wait csv -n openshift-lws-operator -l operators.coreos.com/leader-worker-set.openshift-lws-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for LWS..."

oc wait csv -n openshift-nfd -l operators.coreos.com/nfd.openshift-nfd="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for NFD..."

oc wait csv -n nvidia-gpu-operator -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for NVIDIA GPU..."

oc wait csv -n openshift-operators -l operators.coreos.com/cluster-observability-operator.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for COO..."

oc wait csv -n openshift-operators -l operators.coreos.com/opentelemetry-product.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for OpenTelemetry..."

oc wait csv -n openshift-operators -l operators.coreos.com/tempo-product.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || echo "   Waiting for Tempo..."

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
