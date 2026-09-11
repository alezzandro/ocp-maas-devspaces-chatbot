#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

LLM_NAME="qwen3-8b-fp8"
MAAS_REF_NAME="qwen3-8b-fp8"

echo "========================================="
echo "Phase 7: Verify MaaS"
echo "========================================="

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  if [[ "$result" == "true" || "$result" == "True" || "$result" == "Running" || "$result" == "ok" ]]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc (got: $result)"
    FAIL=$((FAIL + 1))
  fi
}

echo "1. Infrastructure health..."
GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
check "Gateway Programmed" "$GW_STATUS"

PG_READY=$(oc get statefulset postgres -n redhat-ods-applications \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
check "PostgreSQL ready" "$([ "$PG_READY" -ge 1 ] 2>/dev/null && echo true || echo false)"

MAAS_API=$(oc get deployment maas-api -n redhat-ai-gateway-infra \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [[ "${MAAS_API}" -lt 1 ]]; then
  MAAS_API=$(oc get deployment maas-api -n redhat-ods-applications \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
fi
check "maas-api running" "$([ "$MAAS_API" -ge 1 ] 2>/dev/null && echo true || echo false)"

DSC_STATUS=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || echo "")
if [[ -z "$DSC_STATUS" ]]; then
  DSC_STATUS=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}' 2>/dev/null || echo "Unknown")
fi
check "ModelsAsAServiceReady" "$DSC_STATUS"

echo ""
echo "2. Model readiness..."
IS_READY=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
check "LLMInferenceService Ready" "$IS_READY"

GPU_NODE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
check "GPU node Ready" "$([ "$GPU_NODE" -ge 1 ] && echo true || echo false)"

echo ""
echo "3. MaaS Gateway routing..."
MODELREF_PHASE=$(oc get maasmodelref "${MAAS_REF_NAME}" -n models-as-a-service \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
check "MaaSModelRef ${MAAS_REF_NAME} Ready" "$([ "$MODELREF_PHASE" == "Ready" ] && echo true || echo false)"
if oc get maasmodelref qwen3-8b -n models-as-a-service &>/dev/null; then
  check "No leftover MaaSModelRef/qwen3-8b" "false"
else
  check "No leftover MaaSModelRef/qwen3-8b" "true"
fi

TOKEN=$(oc whoami -t)
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/${LLM_NAME}/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
check "Gateway serves model list (200 or 403)" "$([ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "403" ] && echo true || echo false)"

echo ""
echo "4. Model Registry..."
MR_READY=$(oc get deployment default-registry -n rhoai-model-registries \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
check "Model Registry server" "$([ "$MR_READY" -ge 1 ] 2>/dev/null && echo true || echo false)"

MODEL_COUNT=$(oc exec deployment/default-registry -n rhoai-model-registries -c rest-container -- \
  curl -sS -m 20 "http://127.0.0.1:8080/api/model_registry/v1alpha3/registered_models" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('size',0))" 2>/dev/null || echo "0")
check "Model registered in registry" "$([ "$MODEL_COUNT" -ge 1 ] 2>/dev/null && echo true || echo false)"

echo ""
echo "5. Observability (Perses)..."
PERSES_READY=$(oc get pods -n redhat-ods-monitoring -l app.kubernetes.io/managed-by=perses-operator \
  --no-headers 2>/dev/null | grep -c "Running" || echo "0")
check "Perses server running" "$([ "$PERSES_READY" -ge 1 ] 2>/dev/null && echo true || echo false)"

DASHBOARDS=$(oc get persesdashboard -A -o jsonpath='{.items[*].status.conditions[0].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
check "Perses dashboards synced" "$([ "$DASHBOARDS" -ge 2 ] 2>/dev/null && echo true || echo false)"

echo ""
echo "6. Direct model inference test..."
POD_NAME=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | head -1)
if [[ -n "$POD_NAME" ]]; then
  RESPONSE=$(oc exec "$POD_NAME" -n models-as-a-service -c main -- \
    curl -sk https://localhost:8000/v1/models 2>/dev/null || echo "")
  HAS_DATA=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if 'data' in d else 'false')" 2>/dev/null || echo "false")
  check "Model endpoint responds" "$HAS_DATA"
else
  check "Model pod running" "false"
fi

echo ""
echo "7. OpenShift AI 3.5 dashboard / control plane..."
GENAI=$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.genAiStudio}' 2>/dev/null || echo "")
MCP=$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.mcpCatalog}' 2>/dev/null || echo "")
check "genAiStudio enabled" "$([ "${GENAI}" == "true" ] && echo true || echo false)"
check "mcpCatalog enabled" "$([ "${MCP}" == "true" ] && echo true || echo false)"

OGX=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || echo "")
if [[ -z "${OGX}" ]]; then
  OGX=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.spec.components.ogxoperator.managementState}' 2>/dev/null || echo "")
fi
PIPE=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.aipipelines.managementState}' 2>/dev/null || echo "")
if [[ -z "${PIPE}" ]]; then
  PIPE=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.spec.components.datasciencepipelines.managementState}' 2>/dev/null || echo "")
fi
RAY=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.ray.managementState}' 2>/dev/null || echo "")
check "DSC OGX Managed" "$([ "${OGX}" == "Managed" ] && echo true || echo false)"
check "DSC AI Pipelines Managed" "$([ "${PIPE}" == "Managed" ] && echo true || echo false)"
check "DSC Ray still Removed" "$([ "${RAY}" == "Removed" ] && echo true || echo false)"

echo ""
echo "8. Gen AI Playground..."
OGX_SRV=$(oc get ogxserver ogx-genai-playground -n models-as-a-service \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ -z "${OGX_SRV}" ]]; then
  OGX_SRV=$(oc get ogxserver ogx-genai-playground -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "missing")
fi
check "OGXServer Ready" "$([[ "${OGX_SRV}" == "Ready" || "${OGX_SRV}" == "True" ]] && echo true || echo false)"
PG_OK=$(oc get pod -n models-as-a-service -l app=ogx-postgres --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running" {c++} END {print c+0}')
check "OGX PostgreSQL Running" "$([[ "${PG_OK}" -ge 1 ]] && echo true || echo false)"
MCP_OK=$(oc get mcpserver openshift-mcp-server -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
check "OpenShift MCP Server Ready" "$([ "${MCP_OK}" == "True" ] && echo true || echo false)"

OGX_POD=$(oc get pod -n models-as-a-service -l app=ogx --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${OGX_POD}" ]]; then
  OGX_MODELS=$(oc exec -n models-as-a-service "${OGX_POD}" -- \
    curl -sS -m 8 http://127.0.0.1:8321/v1/models 2>/dev/null || echo "")
  HAS_QWEN=$(echo "${OGX_MODELS}" | grep -qiE 'qwen3-8b' && echo true || echo false)
  HAS_GRANITE=$(echo "${OGX_MODELS}" | grep -q 'granite-embedding-125m-english' && echo true || echo false)
  check "OGX lists Qwen inference model" "${HAS_QWEN}"
  check "OGX lists granite-embedding-125m-english" "${HAS_GRANITE}"
else
  check "OGX pod Running for /v1/models" "false"
fi

echo ""
echo "========================================="
echo "MaaS Verification Summary"
echo "========================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "Status: ALL CHECKS PASSED"
else
  echo "Status: SOME CHECKS FAILED (non-critical checks may fail during initial setup)"
fi
echo "========================================="
