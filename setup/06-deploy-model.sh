#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"
LLM_NAME="qwen3-8b-fp8"
MAAS_REF_NAME="qwen3-8b-fp8"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 6: Deploy Model"
echo "========================================="

echo "1. Ensuring models-as-a-service namespace (visible in OpenShift AI Projects)..."
oc apply -f "${MANIFESTS_DIR}/model/models-as-a-service-namespace.yaml"
oc label namespace models-as-a-service \
  maas.opendatahub.io/gateway-access=true \
  opendatahub.io/dashboard=true \
  opendatahub.io/generated-namespace=true \
  modelmesh-enabled=false \
  --overwrite
oc annotate namespace models-as-a-service \
  openshift.io/display-name="Models as a Service" \
  openshift.io/description="MaaS governed Qwen3-8B pool (Dev Spaces + Chatbot + Playground)" \
  --overwrite

echo "2. Creating OCI ModelCar connection (required for OpenShift AI Deployments Edit)..."
oc apply -f "${MANIFESTS_DIR}/model/oci-connection.yaml"

echo "3. Creating LLMInferenceService for Qwen3-8B-FP8-dynamic..."
NVIDIA_PRESET=$(oc get llminferenceserviceconfig -n redhat-ods-applications \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
  grep -E 'kserve-config-llm-single-node-template-nvidia-cuda$|kserve-config-llm-template-nvidia-cuda$' | \
  grep -v multi-node | sort | tail -1 || true)
if [[ -z "${NVIDIA_PRESET}" ]]; then
  echo "ERROR: No NVIDIA CUDA LLMInferenceServiceConfig preset found in redhat-ods-applications."
  oc get llminferenceserviceconfig -n redhat-ods-applications --no-headers
  exit 1
fi
echo "   Using KServe preset: ${NVIDIA_PRESET}"
sed "s/v3-4-2-kserve-config-llm-template-nvidia-cuda/${NVIDIA_PRESET}/" \
  "${MANIFESTS_DIR}/model/llm-inference-service.yaml" | oc apply -f -
oc annotate llminferenceservice "${LLM_NAME}" -n models-as-a-service \
  opendatahub.io/connections=qwen3-8b-fp8-connection \
  --overwrite

echo "4. Waiting for LLMInferenceService to be Ready..."
echo "   This takes 5-15 minutes (image pull + model loading into GPU memory)..."
TIMEOUT=900
INTERVAL=30
ELAPSED=0
while true; do
  IS_READY=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  READY_PODS=$(oc get pods -n models-as-a-service \
    -l app.kubernetes.io/name="${LLM_NAME}" --no-headers 2>/dev/null | grep -c " Running" || true)
  TOTAL_PODS=$(oc get pods -n models-as-a-service \
    -l app.kubernetes.io/name="${LLM_NAME}" --no-headers 2>/dev/null | wc -l || true)
  if [[ "$IS_READY" == "True" ]]; then
    echo "   LLMInferenceService is Ready! (pods Running: ${READY_PODS}/${TOTAL_PODS})"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timeout waiting for model deployment"
    oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service -o yaml | tail -80
    exit 1
  fi
  echo "   Ready=${IS_READY} | pods=${READY_PODS}/${TOTAL_PODS} (${ELAPSED}s / ${TIMEOUT}s)"
  if [[ "$ELAPSED" -ge 60 ]]; then
    PRESET_MSG=$(oc get llminferenceservice "${LLM_NAME}" -n models-as-a-service \
      -o jsonpath='{.status.conditions[?(@.reason=="ConfigNotFound")].message}' 2>/dev/null || true)
    if [[ -n "$PRESET_MSG" ]]; then
      echo "ERROR: KServe preset missing: ${PRESET_MSG}"
      exit 1
    fi
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

STUCK=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}" \
  --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}')
if [[ -n "${STUCK}" ]]; then
  echo "   Removing leftover Failed/Init pods from a prior node event..."
  # shellcheck disable=SC2086
  oc delete pod -n models-as-a-service ${STUCK} --force --grace-period=0 --ignore-not-found || true
fi

# Discover the id vLLM actually advertises (do not assume it equals the CR name).
SERVED_MODEL="${LLM_NAME}"
VPOD=$(oc get pod -n models-as-a-service -l app.kubernetes.io/name="${LLM_NAME}",kserve.io/component=workload \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${VPOD}" ]]; then
  DISCOVERED=$(oc exec -n models-as-a-service "${VPOD}" -c main -- \
    curl -sk -m 10 https://127.0.0.1:8000/v1/models 2>/dev/null | \
    python3 -c "import sys,json
try:
  d=json.load(sys.stdin)
  ids=[x.get('id') for x in d.get('data') or [] if x.get('id')]
  print(ids[0] if ids else '')
except Exception:
  print('')
" 2>/dev/null || true)
  if [[ -n "${DISCOVERED}" ]]; then
    SERVED_MODEL="${DISCOVERED}"
    echo "   vLLM served model id: ${SERVED_MODEL}"
  fi
fi

echo "5. Creating MaaSModelRef..."
oc apply -f "${MANIFESTS_DIR}/model/maas-model-ref.yaml"
oc delete maasmodelref qwen3-8b -n models-as-a-service --ignore-not-found

echo "6. Waiting for MaaSModelRef to become Ready (HTTPRoute auto-created)..."
TIMEOUT=180
INTERVAL=10
ELAPSED=0
while true; do
  PHASE=$(oc get maasmodelref "${MAAS_REF_NAME}" -n models-as-a-service \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$PHASE" == "Ready" ]]; then
    echo "   MaaSModelRef is Ready!"
    ENDPOINT=$(oc get maasmodelref "${MAAS_REF_NAME}" -n models-as-a-service \
      -o jsonpath='{.status.endpoint}' 2>/dev/null || echo "")
    echo "   MaaS Endpoint: ${ENDPOINT}"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: MaaSModelRef not Ready yet (phase: ${PHASE}). May need more time."
    break
  fi
  echo "   MaaSModelRef phase: ${PHASE} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "7. Verifying model serves through MaaS Gateway..."
sleep 5
TOKEN=$(oc whoami -t)
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/${LLM_NAME}/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  echo "   MaaS Gateway returns 200 - Model accessible!"
elif [[ "$HTTP_CODE" == "403" ]]; then
  echo "   MaaS Gateway returns 403 (subscription required) - Auth working!"
elif [[ "$HTTP_CODE" == "401" ]]; then
  echo "   MaaS Gateway returns 401 (auth required) - Gateway routing works!"
else
  echo "   WARNING: Unexpected HTTP code: ${HTTP_CODE}. Check gateway routing."
fi

echo "8. Deploying Gen AI Playground (OGXServer)..."
# CPU-only rh distribution. Talks to Qwen over HTTPS ClusterIP (bypasses MaaS).
# The rh image expects PostgreSQL (not sqlite). Secret is generated, not committed.
# https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/deploying-ogx-server_rag
if ! oc get secret ogx-postgres-credentials -n models-as-a-service &>/dev/null; then
  oc create secret generic ogx-postgres-credentials -n models-as-a-service \
    --from-literal=password="$(openssl rand -base64 24)"
fi
oc apply -f "${MANIFESTS_DIR}/playground/postgres.yaml"
echo "   Waiting for ogx-postgres Ready..."
oc wait pod -n models-as-a-service -l app=ogx-postgres --for=condition=Ready --timeout=180s \
  2>/dev/null || echo "   WARNING: ogx-postgres not Ready yet."
oc apply -f "${MANIFESTS_DIR}/playground/ogx-configmap.yaml"
python3 -c "
from pathlib import Path
import sys
p = Path(sys.argv[1])
print(p.read_text().replace('INFERENCE_MODEL_PLACEHOLDER', sys.argv[2]))
" "${MANIFESTS_DIR}/playground/ogx-server.yaml" "${SERVED_MODEL}" | oc apply -f -

echo "   Waiting for OGXServer to become Ready..."
TIMEOUT=180
INTERVAL=10
ELAPSED=0
while true; do
  PHASE=$(oc get ogxserver ogx-genai-playground -n models-as-a-service \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ -z "${PHASE}" || "${PHASE}" == "Unknown" ]]; then
    PHASE=$(oc get ogxserver ogx-genai-playground -n models-as-a-service \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  fi
  if [[ "${PHASE}" == "Ready" || "${PHASE}" == "True" ]]; then
    echo "   Gen AI Playground OGXServer is Ready!"
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    echo "   WARNING: OGXServer not Ready after ${TIMEOUT}s (phase: ${PHASE})."
    oc get ogxserver ogx-genai-playground -n models-as-a-service -o wide 2>/dev/null || true
    break
  fi
  echo "   OGXServer phase: ${PHASE} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "9. Deploying OpenShift MCP Server..."
oc apply -f "${MANIFESTS_DIR}/playground/openshift-mcp-server.yaml"
oc wait mcpserver openshift-mcp-server -n models-as-a-service \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=90s 2>/dev/null || \
  echo "   WARNING: MCP Server not ready yet."
echo "   OpenShift MCP Server: $(oc get mcpserver openshift-mcp-server -n models-as-a-service -o jsonpath='{.status.address.url}' 2>/dev/null || echo 'pending')"

echo ""
echo "Phase 6 complete: Model deployed and exposed via MaaS."
echo "   Model: Qwen3-8B-FP8-dynamic (vLLM CUDA)"
echo "   MaaS Endpoint: https://maas.${CLUSTER_DOMAIN}/models-as-a-service/${LLM_NAME}/v1"
echo "   Gen AI Playground: OGXServer ogx-genai-playground (models-as-a-service)"
echo "   OpenShift MCP Server: openshift-mcp-server (models-as-a-service)"
echo "========================================="
