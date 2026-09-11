#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "  Uninstall Demo"
echo "========================================="
echo "WARNING: This will remove all demo components."
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "1. Removing chatbot..."
oc delete -k "${REPO_ROOT}/manifests/chatbot/" --ignore-not-found 2>/dev/null || true

echo "2. Removing Dev Spaces CheCluster..."
oc delete checluster devspaces -n openshift-devspaces --ignore-not-found 2>/dev/null || true

echo "3. Removing MaaS subscriptions and policies..."
oc delete -k "${REPO_ROOT}/manifests/subscriptions/" --ignore-not-found 2>/dev/null || true

echo "4. Removing Gen AI Playground (OGX + postgres + MCP)..."
oc delete ogxserver ogx-genai-playground -n models-as-a-service --ignore-not-found 2>/dev/null || true
oc delete -f "${REPO_ROOT}/manifests/playground/ogx-server.yaml" --ignore-not-found 2>/dev/null || true
oc delete -f "${REPO_ROOT}/manifests/playground/ogx-configmap.yaml" --ignore-not-found 2>/dev/null || true
oc delete -f "${REPO_ROOT}/manifests/playground/openshift-mcp-server.yaml" --ignore-not-found 2>/dev/null || true
oc delete -f "${REPO_ROOT}/manifests/playground/postgres.yaml" --ignore-not-found 2>/dev/null || true
oc delete secret ogx-postgres-credentials -n models-as-a-service --ignore-not-found 2>/dev/null || true
oc delete pvc postgres-data-ogx-postgres-0 ogx-genai-playground-pvc -n models-as-a-service --ignore-not-found 2>/dev/null || true
oc delete configmap gen-ai-aa-mcp-servers -n redhat-ods-applications --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding mcp-viewer-models-as-a-service --ignore-not-found 2>/dev/null || true
oc delete llamastackdistribution --all -n models-as-a-service --ignore-not-found 2>/dev/null || true

echo "5. Removing LLMInferenceService and MaaS model refs..."
oc delete llminferenceservice qwen3-8b-fp8 -n models-as-a-service --ignore-not-found 2>/dev/null || true
oc delete maasmodelref qwen3-8b-fp8 qwen3-8b -n models-as-a-service --ignore-not-found 2>/dev/null || true
oc delete secret qwen3-8b-fp8-connection -n models-as-a-service --ignore-not-found 2>/dev/null || true
# Legacy kustomize (InferenceService in llm) — ignore if already unused.
oc delete -k "${REPO_ROOT}/manifests/model/" --ignore-not-found 2>/dev/null || true

echo "6. Removing model registry..."
oc delete -f "${REPO_ROOT}/manifests/model-registry/mysql/mysql.yaml" --ignore-not-found 2>/dev/null || true

echo "7. Removing MaaS platform (PostgreSQL)..."
oc delete -f "${REPO_ROOT}/manifests/maas-platform/postgres/postgres.yaml" --ignore-not-found 2>/dev/null || true
oc delete secret maas-db-config maas-postgres-credentials -n redhat-ods-applications --ignore-not-found 2>/dev/null || true

echo "8. Removing DataScienceCluster..."
oc delete datasciencecluster default-dsc --ignore-not-found 2>/dev/null || true

echo "9. Removing Gateway..."
oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found 2>/dev/null || true

echo "10. Removing groups..."
oc delete group devspaces-users chatbot-users --ignore-not-found 2>/dev/null || true

echo "11. Removing in-cluster demo bootstrapper (keeps Web Terminal Operator)..."
oc delete deployment demo-bootstrapper -n rh-demo-bootstrapper --ignore-not-found 2>/dev/null || true
oc delete pvc demo-work -n rh-demo-bootstrapper --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding rh-demo-bootstrapper-cluster-admin --ignore-not-found 2>/dev/null || true
oc delete project rh-demo-bootstrapper --ignore-not-found 2>/dev/null || true

echo ""
echo "Demo uninstalled. Operators are still installed (including Web Terminal unless you remove that Subscription)."
echo "========================================="
