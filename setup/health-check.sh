#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

LLM_NAME="qwen3-8b-fp8"

echo "========================================="
echo "Health Check & Post-Reboot Recovery"
echo "========================================="
echo ""

ERRORS=0

check_pass() { echo "  ✓ $1"; }
check_fail() { echo "  ✗ $1"; ERRORS=$((ERRORS + 1)); }
check_warn() { echo "  ! $1"; }

# ─── 1. Nodes ───────────────────────────────────────────────────────────────────
echo "1. Cluster Nodes"
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | { grep -cv " Ready " || true; })
GPU_NODES=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | wc -l)
if [[ "$NOT_READY" -gt 0 ]]; then
  check_fail "$NOT_READY node(s) not Ready"
else
  check_pass "All nodes Ready"
fi
if [[ "$GPU_NODES" -gt 0 ]]; then
  check_pass "GPU node(s) present: $GPU_NODES"
else
  check_fail "No GPU nodes found"
fi
echo ""

# ─── 2. GPU Operator ────────────────────────────────────────────────────────────
echo "2. NVIDIA GPU Operator"
GPU_STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || echo "missing")
# OnDelete driver DaemonSets keep numberReady=desired while updatedNumberScheduled
# stays 0 until the pod is recreated. ClusterPolicy then reports state-driver
# notReady even though the GPU is allocatable. JSON omitempty hides a 0.
DRIVER_UPDATED_LAG=0
if [[ "$GPU_STATE" != "ready" ]]; then
  DRIVER_UPDATED_LAG=$(oc get ds -n nvidia-gpu-operator -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(0)
    sys.exit(0)
lag = 0
for ds in data.get("items", []):
    name = ds.get("metadata", {}).get("name", "")
    if "driver-daemonset" not in name:
        continue
    st = ds.get("status", {})
    desired = int(st.get("desiredNumberScheduled") or 0)
    ready = int(st.get("numberReady") or 0)
    updated = int(st.get("updatedNumberScheduled") or 0)
    if desired >= 1 and ready >= desired and updated < desired:
        lag = 1
print(lag)
' || echo 0)
fi
if [[ "$GPU_STATE" == "ready" ]]; then
  check_pass "ClusterPolicy: ready"
elif [[ "$DRIVER_UPDATED_LAG" == "1" ]]; then
  check_warn "ClusterPolicy: ${GPU_STATE} because the driver DaemonSet is one OnDelete revision behind. --fix recreates that pod only when no model pod is Running."
else
  check_warn "ClusterPolicy: $GPU_STATE (may need recovery — see below)"
fi

GPU_ALLOC=$(oc get nodes -l node-role.kubernetes.io/worker-gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [[ "$GPU_ALLOC" -ge 1 ]]; then
  check_pass "GPU allocatable: $GPU_ALLOC"
else
  check_fail "No GPU allocatable on GPU node"
fi
echo ""

# ─── 3. LLM Inference Service ───────────────────────────────────────────────────
echo "3. LLM Inference Service"
DASH_LABEL=$(oc get ns models-as-a-service -o jsonpath='{.metadata.labels.opendatahub\.io/dashboard}' 2>/dev/null || echo "")
if [[ "$DASH_LABEL" == "true" ]]; then
  check_pass "Namespace models-as-a-service labeled for OpenShift AI Projects"
else
  check_fail "Namespace models-as-a-service missing opendatahub.io/dashboard=true (hidden in RHOAI Projects)"
fi

HP_SCHED=$(oc get hardwareprofile gpu-l4-nvidia -n redhat-ods-applications \
  -o jsonpath='{.spec.scheduling.type}' 2>/dev/null || echo "")
HP_NAME=$(oc get hardwareprofile gpu-l4-nvidia -n redhat-ods-applications \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/display-name}' 2>/dev/null || echo "")
if [[ "$HP_SCHED" == "Node" && -n "$HP_NAME" ]]; then
  check_pass "HardwareProfile gpu-l4-nvidia (scheduling=Node, display-name set)"
else
  check_fail "HardwareProfile gpu-l4-nvidia incomplete (edit form may be empty)"
fi

CONN=$(oc get secret qwen3-8b-fp8-connection -n models-as-a-service \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
LLMIS_CONN=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/connections}' 2>/dev/null || echo "")
if [[ -n "$CONN" && "$LLMIS_CONN" == "qwen3-8b-fp8-connection" ]]; then
  check_pass "OCI connection linked on LLMInferenceService (Deployments Edit)"
else
  check_fail "Missing OCI connection / opendatahub.io/connections (Deployments Edit empty)"
fi

LLM_READY=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "$LLM_READY" == "True" ]]; then
  check_pass "LLMInferenceService ${LLM_NAME}: Ready"
else
  check_fail "LLMInferenceService ${LLM_NAME}: Not Ready ($LLM_READY)"
fi

LLM_RUNNING=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}" \
  --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
LLM_STUCK_PODS=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}" \
  --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}')
LLM_STUCK_COUNT=$(printf '%s\n' "${LLM_STUCK_PODS}" | awk 'NF' | wc -l)
if [[ "${LLM_RUNNING}" -ge 1 ]]; then
  check_pass "Workload pods Running: ${LLM_RUNNING}"
else
  check_fail "Workload pods Running: ${LLM_RUNNING} (expected 1)"
fi
if [[ "${LLM_STUCK_COUNT}" -gt 0 ]]; then
  check_warn "Leftover inference pod(s) not Running (${LLM_STUCK_COUNT}): leftover Init/Unknown after node drain — --fix force-deletes them"
fi

MAAS_REF=$(oc get maasmodelref "${LLM_NAME}" -n models-as-a-service -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$MAAS_REF" == "Ready" ]]; then
  check_pass "MaaSModelRef ${LLM_NAME}: Ready"
else
  check_fail "MaaSModelRef ${LLM_NAME}: $MAAS_REF (name must match the inference URL path)"
fi
if oc get maasmodelref qwen3-8b -n models-as-a-service &>/dev/null; then
  check_warn "Leftover MaaSModelRef qwen3-8b (Usage 403s on /qwen3-8b-fp8/ path); --fix retargets subscriptions"
fi
echo ""

# ─── 4. MaaS Gateway ────────────────────────────────────────────────────────────
echo "4. MaaS Gateway"
GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
if [[ "$GW_STATUS" == "True" ]]; then
  check_pass "Gateway: Programmed"
else
  check_fail "Gateway not Programmed: $GW_STATUS"
fi
ENABLE_AUTH=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service \
  -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}' 2>/dev/null || echo "")
if [[ "${ENABLE_AUTH}" == "true" ]]; then
  check_pass "LLMInferenceService enable-auth=true (no anonymous route AuthPolicy)"
else
  check_fail "LLMInferenceService enable-auth=${ENABLE_AUTH:-unset} (anonymous *-kserve-route-authn zeros Usage); --fix sets true"
fi
if oc get authpolicy "${LLM_NAME}-kserve-route-authn" -n models-as-a-service &>/dev/null; then
  check_fail "AuthPolicy ${LLM_NAME}-kserve-route-authn present (wipes MaaS identity; Usage stays 0); --fix deletes it"
else
  check_pass "No competing HTTPRoute AuthPolicy"
fi
MAAS_AUTH_ENF=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "Unknown")
MAAS_AUTH_MSG=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null || echo "")
if [[ "${MAAS_AUTH_ENF}" == "True" && "${MAAS_AUTH_MSG}" != *"partially"* ]]; then
  check_pass "maas-gateway-auth: Enforced"
else
  check_fail "maas-gateway-auth Enforced=${MAAS_AUTH_ENF} (${MAAS_AUTH_MSG:-no message})"
fi
CONFLICT_TRUE=$(oc get maasauthpolicy -n models-as-a-service \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="ConflictingAuthPolicy")].status}{"\n"}{end}' \
  2>/dev/null | grep -c True || true)
if [[ "${CONFLICT_TRUE}" -gt 0 ]]; then
  check_fail "MaaSAuthPolicy ConflictingAuthPolicy=True (competing AuthPolicy); --fix removes it"
else
  check_pass "MaaSAuthPolicy: no conflicting AuthPolicies"
fi
echo ""

# ─── 5. Observability ───────────────────────────────────────────────────────────
echo "5. Observability Stack"
MON_READY=$(oc get monitoring default-monitoring -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "$MON_READY" == "True" ]]; then
  check_pass "Monitoring component: Ready"
else
  check_warn "Monitoring component: $MON_READY"
fi

PERSES_PODS=$(oc get pods -n redhat-ods-monitoring -l app.kubernetes.io/managed-by=perses-operator --no-headers 2>/dev/null | grep "Running" | wc -l)
if [[ "$PERSES_PODS" -ge 1 ]]; then
  check_pass "Perses: Running"
else
  check_warn "Perses: not running"
fi

TP_EXISTS=$(oc get telemetrypolicy maas-telemetry -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "Unknown")
if [[ "$TP_EXISTS" == "True" ]]; then
  check_pass "TelemetryPolicy: Enforced (Usage Dashboard labels)"
else
  check_warn "TelemetryPolicy: $TP_EXISTS (Usage Dashboard may not show subscription data)"
fi
echo ""

# ─── 6. Gen AI Playground ───────────────────────────────────────────────────────
echo "6. Gen AI Playground"
OGX_PHASE=$(oc get ogxserver ogx-genai-playground -n models-as-a-service \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ -z "${OGX_PHASE}" ]]; then
  OGX_PHASE=$(oc get ogxserver ogx-genai-playground -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "missing")
fi
if [[ "${OGX_PHASE}" == "Ready" || "${OGX_PHASE}" == "True" ]]; then
  check_pass "OGXServer ogx-genai-playground: Ready"
else
  check_fail "OGXServer ogx-genai-playground: ${OGX_PHASE} (Playground needs this; --fix applies manifests)"
fi
PG_READY=$(oc get pod -n models-as-a-service -l app=ogx-postgres --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running" {c++} END {print c+0}')
if [[ "${PG_READY}" -ge 1 ]]; then
  check_pass "OGX PostgreSQL: Running"
else
  check_fail "OGX PostgreSQL not Running (rh distro needs POSTGRES_*; --fix applies postgres.yaml)"
fi
MCP_READY=$(oc get mcpserver openshift-mcp-server -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "${MCP_READY}" == "True" ]]; then
  check_pass "OpenShift MCP Server: Ready"
else
  check_warn "OpenShift MCP Server: ${MCP_READY}"
fi
if oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications &>/dev/null; then
  check_pass "MCP catalog ConfigMap gen-ai-aa-mcp-servers present"
else
  check_warn "MCP catalog ConfigMap missing (Playground MCP list empty); --fix applies it"
fi
OGX_POD=$(oc get pod -n models-as-a-service -l app=ogx --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${OGX_POD}" ]]; then
  OGX_MODELS=$(oc exec -n models-as-a-service "${OGX_POD}" -- \
    curl -sS -m 8 http://127.0.0.1:8321/v1/models 2>/dev/null || echo "")
  if echo "${OGX_MODELS}" | grep -qiE 'qwen3-8b'; then
    check_pass "OGX lists Qwen (HTTPS ClusterIP to vLLM)"
  else
    check_fail "OGX /v1/models missing Qwen (need https:// workload svc + VLLM_TLS_VERIFY=false)"
  fi
  if echo "${OGX_MODELS}" | grep -q 'granite-embedding-125m-english'; then
    check_pass "OGX lists granite-embedding-125m-english (Playground vector store)"
  else
    check_fail "OGX /v1/models missing granite-embedding-125m-english (Playground CreateVectorStore popup)"
  fi
else
  check_fail "No Running OGX pod to query /v1/models"
fi
echo ""

# ─── 7. Open WebUI ──────────────────────────────────────────────────────────────
echo "7. Open WebUI (Chatbot)"
WEBUI_READY=$(oc get deploy open-webui -n open-webui -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$WEBUI_READY" -ge 1 ]]; then
  check_pass "Open WebUI: Running"
else
  check_fail "Open WebUI: not ready"
fi
WEBUI_PARAMS=$(oc set env deploy/open-webui -n open-webui --list 2>/dev/null | grep '^DEFAULT_MODEL_PARAMS=' || true)
if echo "${WEBUI_PARAMS}" | grep -q 'legacy'; then
  check_pass "Open WebUI function calling: legacy (no native builtin tools)"
else
  check_warn "Open WebUI DEFAULT_MODEL_PARAMS missing function_calling=legacy (v0.10+ injects grep_knowledge_files); --fix patches sqlite"
fi
echo ""

# ─── 8. Dev Spaces ──────────────────────────────────────────────────────────────
echo "8. OpenShift Dev Spaces"
CHE_PHASE=$(oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "Unknown")
if [[ "$CHE_PHASE" == "Active" ]]; then
  check_pass "CheCluster: Active"
else
  check_warn "CheCluster phase: $CHE_PHASE"
fi
if oc get secret continue-ai-config -n openshift-devspaces &>/dev/null; then
  check_pass "Continue config Secret present"
else
  check_fail "continue-ai-config Secret missing (Continue has no MaaS endpoint)"
fi
CHE_PLUGINS=$(oc get checluster devspaces -n openshift-devspaces \
  -o jsonpath='{.spec.devEnvironments.defaultPlugins}' 2>/dev/null || echo "")
if echo "${CHE_PLUGINS}" | grep -qi 'open-vsx.org'; then
  check_fail "CheCluster defaultPlugins points at Open VSX HTML (factory YAML parse fails); --fix removes it"
fi
VSCODE_CM_NS=$(oc get ns -l app.kubernetes.io/component=workspaces-namespace \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "${VSCODE_CM_NS}" ]]; then
  check_warn "No Dev Spaces user namespace yet (create the workspace, then re-run setup/09-deploy-devspaces.sh)"
else
  MISSING_CM=0
  while IFS= read -r ns; do
    [[ -z "${ns}" ]] && continue
    if ! oc get configmap vscode-editor-configurations -n "${ns}" &>/dev/null; then
      MISSING_CM=$((MISSING_CM + 1))
    fi
  done <<< "${VSCODE_CM_NS}"
  if [[ "${MISSING_CM}" -eq 0 ]]; then
    check_pass "vscode-editor-configurations ConfigMap present in Dev Spaces user namespace(s)"
  else
    check_warn "vscode-editor-configurations missing in ${MISSING_CM} user namespace(s); --fix applies it"
  fi
fi
echo ""

# ─── 9. Model Registry ──────────────────────────────────────────────────────────
echo "9. Model Registry"
MR_PODS=$(oc get pods -n rhoai-model-registries --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "$MR_PODS" -ge 1 ]]; then
  check_pass "Model Registry API: Running"
else
  check_warn "Model Registry API: not running"
fi
echo ""

# ─── 10. MaaS endpoint test ─────────────────────────────────────────────────────
echo "10. MaaS Endpoint Test"
TOKEN=$(oc whoami -t)
HTTP_CODE=$(timeout 10 curl -sk -o /dev/null -w "%{http_code}" \
  "${MAAS_URL}/models-as-a-service/${LLM_NAME}/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "403" ]]; then
  check_pass "MaaS endpoint reachable (HTTP $HTTP_CODE)"
else
  check_fail "MaaS endpoint returned HTTP $HTTP_CODE"
  if [[ "$HTTP_CODE" == "503" ]]; then
    check_warn "HTTP 503 with an otherwise Ready Gateway is usually Kuadrant WASM fail-closed after a gateway/operator restart; --fix bounces MaaS gateway pods"
  fi
fi
echo ""

# ─── 11. OpenShift AI 3.5 dashboard / control plane (warn only) ─────────────────
echo "11. OpenShift AI 3.5 dashboard features"
dash_flag() {
  oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
    -o jsonpath="{.spec.dashboardConfig.${1}}" 2>/dev/null || echo ""
}
GENAI=$(dash_flag genAiStudio)
MCP=$(dash_flag mcpCatalog)
LMEVAL=$(dash_flag disableLMEval)
if [[ "${GENAI}" == "true" && "${MCP}" == "true" ]]; then
  check_pass "OdhDashboardConfig: genAiStudio, mcpCatalog enabled"
else
  check_warn "OdhDashboardConfig flags incomplete (genAiStudio=${GENAI:-?} mcpCatalog=${MCP:-?}); re-run setup/04-rhoai-config.sh"
fi
if [[ "${LMEVAL}" == "false" ]]; then
  check_pass "Eval Hub visible (disableLMEval=false)"
else
  check_warn "disableLMEval=${LMEVAL:-?} (Eval Hub hidden unless false)"
fi

dsc_state() {
  oc get datasciencecluster default-dsc \
    -o jsonpath="{.spec.components.${1}.managementState}" 2>/dev/null || echo ""
}
OGX_STATE=$(dsc_state ogx)
if [[ -z "${OGX_STATE}" ]]; then
  OGX_STATE=$(dsc_state ogxoperator)
fi
PIPE_STATE=$(dsc_state aipipelines)
if [[ -z "${PIPE_STATE}" ]]; then
  PIPE_STATE=$(dsc_state datasciencepipelines)
fi
RAY_STATE=$(dsc_state ray)
TRAIN_STATE=$(dsc_state trainingoperator)
KUEUE_STATE=$(dsc_state kueue)

if [[ "${OGX_STATE}" == "Managed" ]]; then
  check_pass "DSC OGX: Managed"
else
  check_warn "DSC OGX: ${OGX_STATE:-missing} (Gen AI Studio Playground needs OGX Managed)"
fi
if [[ "${PIPE_STATE}" == "Managed" ]]; then
  check_pass "DSC AI Pipelines: Managed"
else
  check_warn "DSC AI Pipelines: ${PIPE_STATE:-missing}"
fi
if [[ "${RAY_STATE}" == "Removed" && "${TRAIN_STATE}" == "Removed" && "${KUEUE_STATE}" == "Removed" ]]; then
  check_pass "DSC Ray/Kueue/TrainingOperator: Removed (keeps the single L4 for Qwen)"
else
  check_warn "DSC Ray=${RAY_STATE:-?} Kueue=${KUEUE_STATE:-?} Training=${TRAIN_STATE:-?} (should stay Removed)"
fi
echo ""

# ─── 12. In-cluster demo bootstrapper (optional) ────────────────────────────────
echo "12. Demo bootstrapper (optional)"
if oc get ns rh-demo-bootstrapper &>/dev/null; then
  BS_READY=$(oc get deploy demo-bootstrapper -n rh-demo-bootstrapper -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${BS_READY:-0}" -ge 1 ]]; then
    check_pass "demo-bootstrapper Deployment: Ready"
  else
    check_fail "demo-bootstrapper Deployment: not ready"
  fi
  WTO=$(oc get csv -n openshift-operators --no-headers 2>/dev/null | awk '/web-terminal/ {print $NF; exit}')
  if [[ "${WTO}" == "Succeeded" ]]; then
    check_pass "Web Terminal Operator: Succeeded"
  else
    check_warn "Web Terminal Operator: ${WTO:-missing} (refresh console for masthead terminal)"
  fi
  BS_STATUS=$(oc exec -n rh-demo-bootstrapper deploy/demo-bootstrapper -- cat /work/status 2>/dev/null || echo "unknown")
  if [[ "${BS_STATUS}" == "succeeded" ]]; then
    check_pass "Bootstrapper setup status: succeeded"
  elif [[ "${BS_STATUS}" == "running" ]]; then
    check_warn "Bootstrapper setup status: running (see oc logs -n rh-demo-bootstrapper deploy/demo-bootstrapper)"
  elif [[ "${BS_STATUS}" == "failed" ]]; then
    check_warn "Bootstrapper setup status: failed (stale PVC / leftover retry; ignore if sections 1–11 passed; --fix clears DEMO_RETRY)"
  else
    check_warn "Bootstrapper setup status: ${BS_STATUS}"
  fi
else
  check_warn "Namespace rh-demo-bootstrapper not present (laptop setup, or not kicked off yet)"
fi
echo ""

# ─── 13. Agent identity (optional overlay) ──────────────────────────────────────
echo "13. Agent identity (optional)"
AGENT_IDENTITY_INSTALLED=0
SPIRE_DESIRED=0
SPIRE_READY=0
OIDC_READY=0
if oc get ns zero-trust-workload-identity-manager &>/dev/null; then
  AGENT_IDENTITY_INSTALLED=1
  SPIRE_DESIRED=$(oc get ds spire-agent -n zero-trust-workload-identity-manager \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  SPIRE_READY=$(oc get ds spire-agent -n zero-trust-workload-identity-manager \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  SPIRE_DESIRED=${SPIRE_DESIRED:-0}
  SPIRE_READY=${SPIRE_READY:-0}
  if [[ "$SPIRE_DESIRED" -ge 1 && "$SPIRE_READY" -ge "$SPIRE_DESIRED" ]]; then
    check_pass "SPIRE agent: ${SPIRE_READY}/${SPIRE_DESIRED} Ready"
  else
    check_fail "SPIRE agent: ${SPIRE_READY}/${SPIRE_DESIRED} Ready (stale bundle after a server CA rotation; --fix restarts agents that are not Ready)"
  fi
  OIDC_READY=$(oc get deploy spire-spiffe-oidc-discovery-provider \
    -n zero-trust-workload-identity-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  OIDC_READY=${OIDC_READY:-0}
  if [[ "$OIDC_READY" -ge 1 ]]; then
    check_pass "SPIRE OIDC discovery provider: Ready"
  else
    check_fail "SPIRE OIDC discovery provider: not Ready (--fix restarts it once the agents are Ready)"
  fi
  if oc get ns agent-governance &>/dev/null; then
    for dep in platform-agent untrusted-agent mcp-policy-proxy agent-console; do
      DEP_READY=$(oc get deploy "${dep}" -n agent-governance \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      DEP_READY=${DEP_READY:-0}
      if [[ "$DEP_READY" -ge 1 ]]; then
        check_pass "agent-governance/${dep}: Ready"
      else
        check_fail "agent-governance/${dep}: not Ready"
      fi
    done
  fi
else
  check_warn "Zero Trust Workload Identity Manager is not installed (optional lab)"
fi
echo ""

# ─── Summary ────────────────────────────────────────────────────────────────────
echo "========================================="
if [[ "$ERRORS" -eq 0 ]]; then
  echo "All checks PASSED. Demo is ready."
else
  echo "$ERRORS check(s) FAILED."
  echo "Run 'setup/health-check.sh --fix' to attempt automatic recovery."
fi
echo "========================================="

# ─── Auto-fix mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--fix" ]]; then
  echo ""
  echo "========================================="
  echo "Attempting automatic recovery..."
  echo "========================================="

  # Fix 1: GPU driver stuck after reboot.
  # ClusterPolicy stays notReady when the OnDelete driver pod is one revision
  # behind, even with the GPU allocatable. Scaling inference to 0 in that case
  # takes down a working model. Recreate the driver pod only when the GPU is
  # idle. The full reinstall runs only when the node is not advertising a GPU.
  LLM_RUNNING_NOW=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}" \
    --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
  if [[ "$DRIVER_UPDATED_LAG" == "1" && "$GPU_ALLOC" -ge 1 && "${LLM_RUNNING_NOW}" -ge 1 ]]; then
    echo ""
    echo ">>> GPU is allocatable and inference is Running."
    echo "    Leaving the OnDelete driver pod in place so the model keeps the device."
  elif [[ "$DRIVER_UPDATED_LAG" == "1" && "$GPU_ALLOC" -ge 1 ]]; then
    echo ""
    echo ">>> Recreating NVIDIA driver pods to finish the OnDelete rollout..."
    oc delete pod -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
      --wait=false 2>/dev/null || true
    TIMEOUT=300
    INTERVAL=15
    ELAPSED=0
    while true; do
      STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
      UPDATED=$(oc get ds -n nvidia-gpu-operator -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(0)
    sys.exit(0)
updated = 0
for ds in data.get("items", []):
    if "driver-daemonset" not in ds.get("metadata", {}).get("name", ""):
        continue
    updated = int(ds.get("status", {}).get("updatedNumberScheduled") or 0)
print(updated)
' || echo 0)
      if [[ "$STATE" == "ready" || "$UPDATED" -ge 1 ]]; then
        echo "    Driver rollout refreshed (ClusterPolicy: ${STATE}, updated: ${UPDATED})."
        break
      fi
      if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "    WARNING: driver DaemonSet still not updated after ${TIMEOUT}s."
        break
      fi
      echo "    GPU state: $STATE updated=${UPDATED} (${ELAPSED}s / ${TIMEOUT}s)"
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  elif [[ "$GPU_STATE" != "ready" || "$GPU_ALLOC" -lt 1 ]]; then
    echo ""
    echo ">>> Fixing GPU driver (post-reboot recovery)..."

    echo "    Scaling down inference service..."
    oc patch llminferenceservice "${LLM_NAME}" -n models-as-a-service --type merge -p '{"spec":{"replicas":0}}' 2>/dev/null || true
    sleep 5
    oc delete pods -n models-as-a-service --all --force --grace-period=0 2>/dev/null || true
    sleep 5

    echo "    Force-deleting stuck NVIDIA pods..."
    oc get pods -n nvidia-gpu-operator --no-headers | grep -v "Running\|Completed" | awk '{print $1}' | \
      xargs -r -I{} oc delete pod {} -n nvidia-gpu-operator --force --grace-period=0 2>/dev/null

    echo "    Uncordoning GPU node..."
    GPU_NODE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu -o name | head -1)
    oc adm uncordon ${GPU_NODE} 2>/dev/null || true

    echo "    Waiting for GPU driver to install (up to 300s)..."
    TIMEOUT=300
    INTERVAL=30
    ELAPSED=0
    while true; do
      STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
      if [[ "$STATE" == "ready" ]]; then
        echo "    GPU ClusterPolicy is ready!"
        break
      fi
      if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "    WARNING: GPU not ready after ${TIMEOUT}s. May need manual intervention."
        echo "    Try: oc delete pod -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --force --grace-period=0"
        break
      fi
      DRIVER_LOG=$(oc logs -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -c k8s-driver-manager --tail=3 2>/dev/null || true)
      if echo "$DRIVER_LOG" | grep -q "cannot delete Pods with local storage"; then
        echo "    Driver blocked by inference pod — cleaning..."
        oc delete pods -n models-as-a-service --all --force --grace-period=0 2>/dev/null || true
        oc delete pod -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --force --grace-period=0 2>/dev/null || true
      fi
      echo "    GPU state: $STATE (${ELAPSED}s / ${TIMEOUT}s)"
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  fi

  # Fix 2: Restore LLM Inference Service
  LLM_REPLICAS=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$LLM_REPLICAS" -lt 1 ]]; then
    echo ""
    echo ">>> Restoring LLM Inference Service replicas..."
    oc patch llminferenceservice "${LLM_NAME}" -n models-as-a-service --type merge -p '{"spec":{"replicas":1}}'
  fi

  # Fix 2b: leftover Failed/Init pods after node drain or UnexpectedAdmissionError.
  STUCK_FIX=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}" \
    --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}')
  if [[ -n "${STUCK_FIX}" ]]; then
    echo ""
    echo ">>> Deleting leftover inference pods (not Running)..."
    # shellcheck disable=SC2086
    oc delete pod -n models-as-a-service ${STUCK_FIX} --force --grace-period=0 --ignore-not-found || true
  fi

  # Fix 3: Wait for inference to become ready
  echo ""
  echo ">>> Waiting for LLM Inference Service to become Ready (up to 600s)..."
  TIMEOUT=600
  INTERVAL=30
  ELAPSED=0
  while true; do
    READY=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$READY" == "True" ]]; then
      echo "    LLMInferenceService is Ready!"
      break
    fi
    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
      echo "    WARNING: LLM not ready after ${TIMEOUT}s. Check logs:"
      echo "    oc logs -n models-as-a-service -l app=${LLM_NAME}-kserve -c main --tail=20"
      break
    fi
    echo "    Status: $READY (${ELAPSED}s / ${TIMEOUT}s)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  # Fix 4: Re-apply ServiceMonitor labels (operators recreate them on restart)
  echo ""
  echo ">>> Re-labeling operator ServiceMonitors (suppress bearerTokenFile rejections)..."
  oc label servicemonitor nfd-controller-manager-metrics-monitor -n openshift-nfd \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor odh-model-controller-metrics-monitor -n redhat-ods-applications \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor controller-manager-metrics-monitor -n redhat-ods-applications \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor tempo-operator-controller-manager-metrics-monitor -n openshift-operators \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor opentelemetry-operator-metrics-monitor -n openshift-operators \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true

  if oc get podmonitor istio-pod-monitor -n openshift-ingress &>/dev/null; then
    if ! oc get podmonitor istio-pod-monitor -n openshift-ingress -o yaml | grep -q 'regex: "15021"'; then
      echo ">>> Dropping Istio health port 15021 from istio-pod-monitor..."
      oc patch podmonitor istio-pod-monitor -n openshift-ingress --type json -p '[
        {"op":"add","path":"/spec/podMetricsEndpoints/0/relabelings/-","value":{
          "action":"drop",
          "regex":"15021",
          "sourceLabels":["__meta_kubernetes_pod_container_port_number"]
        }},
        {"op":"add","path":"/spec/podMetricsEndpoints/0/relabelings/-","value":{
          "action":"drop",
          "regex":".*:15021$",
          "sourceLabels":["__address__"]
        }}
      ]' 2>/dev/null || true
    fi
  fi

  # Fix 5: Prometheus secret (monitoring stack)
  if oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
    if ! oc get secret prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
      echo ""
      echo ">>> Creating prometheus-web-tls-ca secret..."
      CA_DATA=$(oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring -o jsonpath='{.data.service-ca\.crt}')
      oc create secret generic prometheus-web-tls-ca -n redhat-ods-monitoring --from-literal=service-ca.crt="$CA_DATA"
      oc delete pod -n redhat-ods-monitoring -l app.kubernetes.io/name=prometheus --ignore-not-found 2>/dev/null || true
    fi
  fi

  # Fix 6: Kuadrant Perses datasource secret (may be GC'd on restart)
  if ! oc get secret kuadrant-prometheus-datasource-secret -n redhat-ods-applications &>/dev/null; then
    echo ""
    echo ">>> Recreating kuadrant-prometheus-datasource-secret..."
    DS_TOKEN=$(oc create token data-science-prometheus-cluster-proxy -n redhat-ods-monitoring --duration=8760h)
    CA_CERT=$(oc get secret cluster-prometheus-datasource-secret -n redhat-ods-monitoring -o jsonpath='{.data.ca\.crt}' | base64 -d)
    oc create secret generic kuadrant-prometheus-datasource-secret \
      -n redhat-ods-applications \
      --from-literal=token="${DS_TOKEN}" \
      --from-literal=ca.crt="${CA_CERT}"
    echo "   Secret recreated."
  fi

  # Fix 7: RBAC for Thanos tenancy in kuadrant-system
  if ! oc get rolebinding kuadrant-metrics-reader -n kuadrant-system &>/dev/null; then
    echo ""
    echo ">>> Creating kuadrant-system RoleBinding for Perses datasource..."
    oc adm policy add-role-to-user view \
      system:serviceaccount:redhat-ods-monitoring:data-science-prometheus-cluster-proxy \
      -n kuadrant-system 2>/dev/null || true
  fi

  # Fix 8: Perses service alias
  if ! oc get svc perses -n redhat-ods-monitoring &>/dev/null; then
    echo ""
    echo ">>> Recreating 'perses' service alias..."
    cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: perses
  namespace: redhat-ods-monitoring
  labels:
    app: perses-alias
spec:
  type: ExternalName
  externalName: data-science-perses.redhat-ods-monitoring.svc.cluster.local
EOF
  fi

  # Fix 9: Usage dashboard zeros — anonymous HTTPRoute AuthPolicy wipes
  # auth.identity so Limitador never increments authorized_hits/_calls.
  echo ""
  echo ">>> Restoring MaaS identity for Usage metrics (enable-auth=true, drop competing AuthPolicies)..."
  oc annotate gateway maas-default-gateway -n openshift-ingress \
    opendatahub.io/managed=false --overwrite 2>/dev/null || true
  oc annotate llminferenceservice "${LLM_NAME}" -n models-as-a-service \
    security.opendatahub.io/enable-auth=true --overwrite 2>/dev/null || true
  oc delete authpolicy maas-default-gateway-authn -n openshift-ingress --ignore-not-found || true
  oc delete authpolicy "${LLM_NAME}-kserve-route-authn" -n models-as-a-service --ignore-not-found || true
  if [[ -f "${REPO_ROOT}/manifests/model/maas-model-ref.yaml" ]]; then
    oc apply -f "${REPO_ROOT}/manifests/model/maas-model-ref.yaml" 2>/dev/null || true
  fi
  for sub in chatbot-subscription devspaces-subscription; do
    CUR=$(oc get maassubscription "${sub}" -n models-as-a-service \
      -o jsonpath='{.spec.modelRefs[0].name}' 2>/dev/null || echo "")
    if [[ -n "${CUR}" && "${CUR}" != "${LLM_NAME}" ]]; then
      oc patch maassubscription "${sub}" -n models-as-a-service --type json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/0/name\",\"value\":\"${LLM_NAME}\"}]" \
        2>/dev/null || true
    fi
  done
  for pol in chatbot-access devspaces-access; do
    CUR=$(oc get maasauthpolicy "${pol}" -n models-as-a-service \
      -o jsonpath='{.spec.modelRefs[0].name}' 2>/dev/null || echo "")
    if [[ -n "${CUR}" && "${CUR}" != "${LLM_NAME}" ]]; then
      oc patch maasauthpolicy "${pol}" -n models-as-a-service --type json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/0/name\",\"value\":\"${LLM_NAME}\"}]" \
        2>/dev/null || true
    fi
  done
  oc delete maasmodelref qwen3-8b -n models-as-a-service --ignore-not-found || true

  # Kuadrant caches MissingDependency until its pod is recreated, and the
  # gateway auth cluster requires Authorino listener TLS. Without both, every
  # MaaS call is HTTP 500 (wasm: gRPC status code is not OK) or anonymous 200.
  AUTH_REASON=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || echo "")
  if [[ "$AUTH_REASON" == "MissingDependency" ]]; then
    echo ""
    echo ">>> Recreating the Kuadrant operator pod (Authorino dependency was cached as missing)..."
    oc delete pod -n openshift-operators -l app=kuadrant,control-plane=controller-manager \
      --wait=true 2>/dev/null || true
    oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=180s \
      2>/dev/null || true
  fi
  TLS_ON=$(oc get authorino authorino -n kuadrant-system \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo "false")
  if [[ "$TLS_ON" != "true" ]] && oc get svc authorino-authorino-authorization -n kuadrant-system &>/dev/null; then
    echo ""
    echo ">>> Enabling Authorino listener TLS for the MaaS gateway auth cluster..."
    oc annotate service authorino-authorino-authorization -n kuadrant-system \
      service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite 2>/dev/null || true
    for _ in $(seq 1 30); do
      oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && break
      sleep 2
    done
    oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
      "spec": {"listener": {"tls": {"enabled": true, "certSecretRef": {"name": "authorino-server-cert"}}}}
    }' 2>/dev/null || true
  fi

  # Fix 10: Gen AI Playground (CPU OGXServer + OpenShift MCP)
  echo ""
  echo ">>> Ensuring Gen AI Playground (OGXServer + MCP)..."
  oc apply -f "${REPO_ROOT}/manifests/rhoai-config/mcp-servers-configmap.yaml" 2>/dev/null || true
  if ! oc get secret ogx-postgres-credentials -n models-as-a-service &>/dev/null; then
    oc create secret generic ogx-postgres-credentials -n models-as-a-service \
      --from-literal=password="$(openssl rand -base64 24)" 2>/dev/null || true
  fi
  oc apply -f "${REPO_ROOT}/manifests/playground/postgres.yaml" 2>/dev/null || true
  oc apply -f "${REPO_ROOT}/manifests/playground/ogx-configmap.yaml" 2>/dev/null || true
  if [[ -f "${REPO_ROOT}/manifests/playground/ogx-server.yaml" ]]; then
    python3 -c "
from pathlib import Path
import sys
p = Path(sys.argv[1])
print(p.read_text().replace('INFERENCE_MODEL_PLACEHOLDER', sys.argv[2]))
" "${REPO_ROOT}/manifests/playground/ogx-server.yaml" "${LLM_NAME}" | oc apply -f - 2>/dev/null || true
  fi
  oc apply -f "${REPO_ROOT}/manifests/playground/openshift-mcp-server.yaml" 2>/dev/null || true

  # Fix 11: MaaS HTTP 503 — Envoy Kuadrant WASM fail-closed after a raced
  # gateway / kuadrant-operator restart. vLLM can be healthy while every
  # Gateway route returns empty 503 (access log: wasm_fail_stream).
  if [[ "${HTTP_CODE}" == "503" ]]; then
    echo ""
    echo ">>> MaaS returned HTTP 503 — restarting MaaS gateway pods to reload Kuadrant WASM..."
    oc delete pod -n openshift-ingress \
      -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
      --wait=false 2>/dev/null || true
    TIMEOUT=120
    INTERVAL=5
    ELAPSED=0
    while true; do
      GW_READY=$(oc get deploy -n openshift-ingress \
        -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
        -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
      GW_WANT=$(oc get deploy -n openshift-ingress \
        -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
        -o jsonpath='{.items[0].status.replicas}' 2>/dev/null || echo "0")
      if [[ "${GW_READY:-0}" -ge 1 && "${GW_READY}" == "${GW_WANT}" ]]; then
        echo "    MaaS gateway replicas Ready (${GW_READY}/${GW_WANT})"
        break
      fi
      if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "    WARNING: MaaS gateway not Ready after ${TIMEOUT}s"
        break
      fi
      echo "    Waiting for gateway pods (${GW_READY:-0}/${GW_WANT:-?} ${ELAPSED}s / ${TIMEOUT}s)"
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
    sleep 8
    HTTP_CODE=$(timeout 10 curl -sk -o /dev/null -w "%{http_code}" \
      "${MAAS_URL}/models-as-a-service/${LLM_NAME}/v1/models" \
      -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
    echo "    Re-probe after WASM reload: HTTP ${HTTP_CODE}"
  fi

  # Fix 12: Continue auto-install ConfigMap must live in the user workspace
  # namespace (che-code does not read it from openshift-devspaces).
  echo ""
  echo ">>> Applying vscode-editor-configurations (Continue) to Dev Spaces user namespaces..."
  USER_NS_FIX=$(oc get ns -l app.kubernetes.io/component=workspaces-namespace \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [[ -z "${USER_NS_FIX}" ]]; then
    echo "    No user workspace namespaces yet"
  else
    while IFS= read -r ns; do
      [[ -z "${ns}" ]] && continue
      oc apply -n "${ns}" -f "${REPO_ROOT}/manifests/devspaces/vscode-editor-configurations.yaml" \
        2>/dev/null || true
      oc apply -n "${ns}" -f "${REPO_ROOT}/manifests/devspaces/vscode-default-extensions.yaml" \
        2>/dev/null || true
    done <<< "${USER_NS_FIX}"
  fi

  CHE_PLUGINS_NOW=$(oc get checluster devspaces -n openshift-devspaces \
    -o jsonpath='{.spec.devEnvironments.defaultPlugins}' 2>/dev/null || echo "")
  if echo "${CHE_PLUGINS_NOW}" | grep -qi 'open-vsx.org'; then
    echo ""
    echo ">>> Removing CheCluster defaultPlugins Open VSX URIs (they break factory YAML parse)..."
    oc patch checluster devspaces -n openshift-devspaces --type json \
      -p '[{"op":"remove","path":"/spec/devEnvironments/defaultPlugins"}]' 2>/dev/null || true
  fi

  # Fix 13: Open WebUI legacy function calling (env ignored after first start)
  if oc get deploy open-webui -n open-webui &>/dev/null; then
    echo ""
    echo ">>> Patching Open WebUI sqlite ConfigVars (function_calling=legacy)..."
    oc set env deploy/open-webui -n open-webui \
      DEFAULT_MODEL_PARAMS='{"function_calling":"legacy"}' \
      ENABLE_WEB_SEARCH=false ENABLE_IMAGE_GENERATION=false \
      ENABLE_CODE_INTERPRETER=false ENABLE_CODE_EXECUTION=false \
      2>/dev/null || true
    PATCHED=0
    for _ in $(seq 1 24); do
      if oc exec -n open-webui deploy/open-webui -- python3 -c '
import json, sqlite3, time
db = "/app/backend/data/webui.db"
con = sqlite3.connect(db)
cur = con.cursor()
tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type=\"table\"")]
if "config" not in tables:
    raise SystemExit(1)
now = int(time.time() * 1000)
updates = {
    "models.default_params": {"function_calling": "legacy"},
    "code_interpreter.enable": False,
    "code_execution.enable": False,
    "web.search.enable": False,
    "image_generation.enable": False,
}
for key, value in updates.items():
    stored = json.dumps(value)
    cur.execute(
        "INSERT INTO config(key, value, updated_at) VALUES(?, ?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        (key, stored, now),
    )
con.commit()
print("webui config patched")
'; then
        PATCHED=1
        break
      fi
      echo "    Waiting for the Open WebUI config table..."
      sleep 5
    done
    if [[ "$PATCHED" -ne 1 ]]; then
      echo "    WARNING: could not patch Open WebUI sqlite"
    fi
  fi

  # Leftover bootstrapper retry after a completed install. Do not re-run setup.
  # Clear DEMO_RETRY first so a Recreate cannot start phase N again.
  if oc get ns rh-demo-bootstrapper &>/dev/null \
     && [[ "${LLM_READY}" == "True" ]] \
     && [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "403" ]]; then
    BS_STATUS_NOW=$(oc exec -n rh-demo-bootstrapper deploy/demo-bootstrapper -- cat /work/status 2>/dev/null || echo "unknown")
    RETRY_NOW=$(oc get deploy demo-bootstrapper -n rh-demo-bootstrapper \
      -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DEMO_RETRY")]}{.value}{end}' 2>/dev/null || echo "")
    if [[ "${BS_STATUS_NOW}" == "failed" || "${RETRY_NOW}" == "true" ]]; then
      echo ""
      echo ">>> Clearing leftover bootstrapper retry (setup already finished; not re-running)..."
      oc exec -n rh-demo-bootstrapper deploy/demo-bootstrapper -- \
        sh -c 'echo succeeded > /work/status; echo 0 > /work/exit_code' 2>/dev/null || true
      oc set env deploy/demo-bootstrapper -n rh-demo-bootstrapper \
        DEMO_RETRY=false DEMO_SETUP_ARGS- 2>/dev/null || true
    fi
  fi

  # Fix 14: SPIRE agents keep a stale SVID on emptyDir across a reboot. After the
  # server rotates an expired CA, attestation fails with "Trust Bundle and Server
  # dont agree" until the agent rebootstraps. Skip this when the optional lab
  # is not installed.
  if [[ "${AGENT_IDENTITY_INSTALLED}" == "1" ]]; then
    wait_spire_agents() {
      local timeout="$1"
      local elapsed=0
      local ready desired
      while true; do
        ready=$(oc get ds spire-agent -n zero-trust-workload-identity-manager \
          -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
        desired=$(oc get ds spire-agent -n zero-trust-workload-identity-manager \
          -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
        ready=${ready:-0}
        desired=${desired:-0}
        if [[ "$desired" -ge 1 && "$ready" -ge "$desired" ]]; then
          echo "    SPIRE agent ${ready}/${desired} Ready"
          return 0
        fi
        if [[ "$elapsed" -ge "$timeout" ]]; then
          echo "    SPIRE agent still ${ready}/${desired} after ${timeout}s"
          return 1
        fi
        echo "    SPIRE agent ${ready}/${desired} (${elapsed}s / ${timeout}s)"
        sleep 15
        elapsed=$((elapsed + 15))
      done
    }

    if [[ "${SPIRE_READY}" -lt "${SPIRE_DESIRED}" || "${SPIRE_DESIRED}" -lt 1 ]]; then
      echo ""
      echo ">>> Recovering SPIRE agents after server CA rotation..."
      oc wait --for=condition=Ready pod/spire-server-0 \
        -n zero-trust-workload-identity-manager --timeout=180s 2>/dev/null || true
      if ! wait_spire_agents 180; then
        echo "    Restarting SPIRE agent pods that are not Ready..."
        oc get pods -n zero-trust-workload-identity-manager \
          -l app.kubernetes.io/name=spire-agent --no-headers 2>/dev/null \
          | awk '$2 != "1/1" {print $1}' \
          | xargs -r oc delete pod -n zero-trust-workload-identity-manager --wait=false
        wait_spire_agents 720 || true
      fi
    fi

    OIDC_NOW=$(oc get deploy spire-spiffe-oidc-discovery-provider \
      -n zero-trust-workload-identity-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    OIDC_NOW=${OIDC_NOW:-0}
    SPIRE_NOW=$(oc get ds spire-agent -n zero-trust-workload-identity-manager \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    SPIRE_NOW=${SPIRE_NOW:-0}
    if [[ "$OIDC_NOW" -lt 1 && "$SPIRE_NOW" -ge 1 ]]; then
      echo ""
      echo ">>> Restarting the SPIRE OIDC discovery provider (workload socket was missing)..."
      oc rollout restart deploy/spire-spiffe-oidc-discovery-provider \
        -n zero-trust-workload-identity-manager 2>/dev/null || true
      oc rollout status deploy/spire-spiffe-oidc-discovery-provider \
        -n zero-trust-workload-identity-manager --timeout=180s 2>/dev/null || true
    fi

    if oc get ns agent-governance &>/dev/null && [[ "$SPIRE_NOW" -ge 1 ]]; then
      for dep in platform-agent untrusted-agent mcp-policy-proxy agent-console; do
        DEP_NOW=$(oc get deploy "${dep}" -n agent-governance \
          -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DEP_NOW=${DEP_NOW:-0}
        if [[ "$DEP_NOW" -lt 1 ]]; then
          echo ">>> Restarting agent-governance/${dep}..."
          oc rollout restart "deploy/${dep}" -n agent-governance 2>/dev/null || true
          oc rollout status "deploy/${dep}" -n agent-governance --timeout=180s 2>/dev/null || true
        fi
      done
    fi
  fi

  echo ""
  echo "========================================="
  echo "Recovery complete. Run this script again without --fix to verify."
  echo "========================================="
fi

exit $ERRORS
