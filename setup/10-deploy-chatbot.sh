#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 10: Deploy Chatbot (Open WebUI)"
echo "========================================="

MAAS_ENDPOINT="${MAAS_URL}/models-as-a-service/qwen3-8b-fp8/v1"

echo "1. Creating namespace and SCC..."
oc apply -f "${MANIFESTS_DIR}/chatbot/namespace.yaml"
oc apply -f "${MANIFESTS_DIR}/chatbot/scc.yaml"

echo "2. Creating session secret..."
oc create secret generic open-webui-secret \
  -n open-webui \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -f -

echo "3. Creating PVC..."
oc apply -f "${MANIFESTS_DIR}/chatbot/pvc.yaml"

echo "4. Deploying Open WebUI..."
sed "s|MAAS_ENDPOINT_PLACEHOLDER|${MAAS_ENDPOINT}|g" \
  "${MANIFESTS_DIR}/chatbot/deployment.yaml" | oc apply -f -

echo "5. Creating Service and Route..."
oc apply -f "${MANIFESTS_DIR}/chatbot/service.yaml"
oc apply -f "${MANIFESTS_DIR}/chatbot/route.yaml"

echo "6. Waiting for Open WebUI to be ready..."
oc wait deployment/open-webui -n open-webui \
  --for=condition=Available --timeout=120s 2>/dev/null || \
  echo "   Deployment may need more time to pull the image."

ROUTE_URL=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo ""
echo "Phase 10 complete: Open WebUI deployed."
echo "Chatbot URL: https://${ROUTE_URL}"
echo "========================================="
