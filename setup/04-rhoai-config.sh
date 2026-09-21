#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 4: RHOAI Configuration"
echo "========================================="

dsc_has_component() {
  oc explain "datasciencecluster.spec.components.${1}" &>/dev/null
}

# Merge-patch a DSC component managementState when the live CRD has that field.
# Used so phase 4 stays idempotent across 3.5 field names (ogx vs llamastackoperator,
# aipipelines vs datasciencepipelines) without a one-off oc patch outside setup.
ensure_dsc_component() {
  local key="$1"
  local state="$2"
  if dsc_has_component "${key}"; then
    echo "   DSC component ${key}: ${state}"
    oc patch datasciencecluster default-dsc --type merge \
      -p "{\"spec\":{\"components\":{\"${key}\":{\"managementState\":\"${state}\"}}}}"
  else
    echo "   Skipping DSC component ${key} (not on this CRD)"
  fi
}

echo "1. Applying DataScienceCluster..."
if oc apply -f "${MANIFESTS_DIR}/rhoai-config/datasciencecluster.yaml"; then
  echo "   Applied manifests/rhoai-config/datasciencecluster.yaml"
else
  echo "   WARNING: DSC apply failed (unknown fields on this CRD?). Patching known components."
fi

# Prefer OpenShift AI 3.5 names; fall back so a slightly older CRD still gets operators.
if dsc_has_component ogx; then
  ensure_dsc_component ogx Managed
elif dsc_has_component ogxoperator; then
  ensure_dsc_component ogxoperator Managed
elif dsc_has_component llamastackoperator; then
  ensure_dsc_component llamastackoperator Managed
fi

if dsc_has_component aipipelines; then
  ensure_dsc_component aipipelines Managed
elif dsc_has_component datasciencepipelines; then
  ensure_dsc_component datasciencepipelines Managed
fi

ensure_dsc_component trustyai Managed
ensure_dsc_component mlflowoperator Managed
ensure_dsc_component kueue Removed
ensure_dsc_component ray Removed
ensure_dsc_component trainingoperator Removed
if dsc_has_component llamastackoperator && dsc_has_component ogx; then
  ensure_dsc_component llamastackoperator Removed
fi

echo "2. Applying DSCInitialization..."
oc apply -f "${MANIFESTS_DIR}/rhoai-config/dscinitializaton.yaml"

echo "3. Waiting for OdhDashboardConfig to be created by the operator..."
TIMEOUT=120
INTERVAL=10
ELAPSED=0
while true; do
  if oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; then
    echo "   OdhDashboardConfig is available."
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: OdhDashboardConfig not found after ${TIMEOUT}s. Patch may fail."
    break
  fi
  echo "   Waiting for OdhDashboardConfig... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "4. Enabling RHOAI dashboard features (OpenShift AI 3.5 flags)..."
# Do not set spec.dashboardConfig.maasAuthPolicies — the CRD CEL rule
# rejects adding that deprecated key if it was not already present:
#   DEPRECATED: spec.dashboardConfig.maasAuthPolicies must be removed or left unchanged.
# Skip llmdTemplates on this 1-GPU three-demo (no llm-d booth beat).
# Flag names: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_resources/customizing-the-dashboard
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{
    "spec": {
      "dashboardConfig": {
        "disableModelCatalog": false,
        "disablePipelines": false,
        "disableLMEval": false,
        "modelAsService": true,
        "genAiStudio": true,
        "observabilityDashboard": true,
        "vLLMDeploymentOnMaaS": true,
        "llmGatewayField": true,
        "promptManagement": true,
        "aiAssetCustomEndpoints": true,
        "mcpCatalog": true,
        "mcpRegistry": true,
        "agentsCatalog": true,
        "agentOps": true,
        "agentConfigManagement": true,
        "externalModels": true,
        "autorag": true,
        "guardrails": true,
        "genAiTracing": true,
        "globalProjectPrompts": true,
        "automl": true,
        "toolCalling": true
      },
      "genAiStudioConfig": {
        "aiAssetCustomEndpoints": {
          "externalProviders": true,
          "clusterDomains": []
        }
      }
    }
  }'
echo "   Dashboard: Gen AI Studio, MCP catalog/registry, agents, AutoRAG, guardrails,"
echo "   tracing, AutoML, Eval Hub, tool calling, external models."

echo "5. Creating MCP servers ConfigMap for Gen AI Playground..."
oc apply -f "${MANIFESTS_DIR}/rhoai-config/mcp-servers-configmap.yaml"

echo "6. Creating HardwareProfile for L4 GPU..."
# Replace avoids stale last-applied fields from the pre-3.5 profile shape
# (displayName/enabled/nodeSelectors at spec root were dropped by the CRD).
oc delete hardwareprofile gpu-l4-nvidia -n redhat-ods-applications --ignore-not-found
oc apply -f "${MANIFESTS_DIR}/rhoai-config/hardware-profile.yaml"
HP_SCHED=$(oc get hardwareprofile gpu-l4-nvidia -n redhat-ods-applications \
  -o jsonpath='{.spec.scheduling.type}' 2>/dev/null || echo "")
HP_NAME=$(oc get hardwareprofile gpu-l4-nvidia -n redhat-ods-applications \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/display-name}' 2>/dev/null || echo "")
if [[ "$HP_SCHED" == "Node" && -n "$HP_NAME" ]]; then
  echo "   HardwareProfile ready: display-name='${HP_NAME}', scheduling=${HP_SCHED}"
else
  echo "   WARNING: HardwareProfile may be incomplete (scheduling='${HP_SCHED}', display-name='${HP_NAME}')."
  echo "   OpenShift AI Deployments edit form can render empty without a valid profile."
fi

echo "7. Waiting for ModelsAsServiceReady condition..."
TIMEOUT=300
INTERVAL=15
ELAPSED=0
while true; do
  STATUS=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || echo "Unknown")
  if [[ -z "$STATUS" || "$STATUS" == "Unknown" ]]; then
    STATUS=$(oc get datasciencecluster default-dsc \
      -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}' 2>/dev/null || echo "Unknown")
  fi
  if [[ "$STATUS" == "True" ]]; then
    echo "   MaaS is ready!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: MaaS not yet ready after ${TIMEOUT}s. Check DSC status."
    break
  fi
  echo "   ModelsAsServiceReady: ${STATUS} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "7b. Waiting for MaaS Gateway Programmed (GatewayClass exists after MaaS)..."
TIMEOUT=180
INTERVAL=15
ELAPSED=0
while true; do
  GW=$(oc get gateway maas-default-gateway -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$GW" == "True" ]]; then
    echo "   Gateway is Programmed!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: Gateway not Programmed after ${TIMEOUT}s (status=${GW})."
    break
  fi
  echo "   Gateway Programmed=${GW} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "7c. Re-labeling ServiceMonitors created by RHOAI (suppress bearerTokenFile rejections)..."
oc label servicemonitor odh-model-controller-metrics-monitor -n redhat-ods-applications \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
oc label servicemonitor controller-manager-metrics-monitor -n redhat-ods-applications \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true

echo "8. Waiting for control-plane DSC components (up to 180s)..."
# Condition type names vary slightly by CSV; match on substring.
wait_dsc_ready_substring() {
  local label="$1"
  local needle="$2"
  local timeout="${3:-180}"
  local interval=15
  local elapsed=0
  while true; do
    local hit
    hit=$(oc get datasciencecluster default-dsc -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
needle='${needle}'.lower()
for c in d.get('status',{}).get('conditions',[]):
    t=(c.get('type') or '').lower()
    if needle in t:
        print(c.get('status',''))
        break
" 2>/dev/null || true)
    if [[ "${hit}" == "True" ]]; then
      echo "   ${label}: Ready"
      return 0
    fi
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      echo "   WARNING: ${label} not Ready after ${timeout}s (status='${hit:-missing}'). Dashboard nav may lag."
      return 0
    fi
    echo "   ${label}: ${hit:-pending} (${elapsed}s / ${timeout}s)"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
}

wait_dsc_ready_substring "OGX" "ogx" 180
wait_dsc_ready_substring "AI Pipelines" "pipeline" 180
wait_dsc_ready_substring "TrustyAI" "trusty" 180
wait_dsc_ready_substring "MLflow" "mlflow" 180

echo ""
echo "Phase 4 complete: RHOAI configured with MaaS, Model Registry, Model Catalog,"
echo "and OpenShift AI 3.5 dashboard / control-plane features (no extra GPU jobs)."
echo "========================================="
