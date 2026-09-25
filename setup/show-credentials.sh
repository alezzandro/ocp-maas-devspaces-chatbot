#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

LLM_NAME="qwen3-8b-fp8"

echo "========================================="
echo "  Demo Credentials and URLs"
echo "========================================="

echo ""
echo "--- OpenShift ---"
echo "Console: https://console-openshift-console.${CLUSTER_DOMAIN}"
echo "User: $(oc whoami)"

echo ""
echo "--- OpenShift AI Dashboard ---"
RHOAI_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
echo "URL: https://${RHOAI_URL}"

echo ""
echo "--- MaaS ---"
echo "MaaS API: ${MAAS_URL}"
echo "Health: ${MAAS_URL}/maas-api/health"
echo "Model endpoint: ${MAAS_URL}/models-as-a-service/${LLM_NAME}/v1"
echo "LLMInferenceService: ${LLM_NAME} (1 replica, Qwen3-8B-FP8-dynamic)"

echo ""
echo "--- Dev Spaces ---"
DEVSPACES_URL=$(oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "N/A")
echo "Dashboard: ${DEVSPACES_URL}"
echo "Workspace: ${DEVSPACES_URL}/#https://github.com/alezzandro/ocp-maas-devspaces-chatbot?devfilePath=devspaces-workspace/devfile.yaml"
echo "After first workspace start, re-run setup/09-deploy-devspaces.sh so Continue ConfigMaps land in the user namespace."

echo ""
echo "--- Chatbot (Open WebUI) ---"
CHATBOT_URL=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
echo "URL: https://${CHATBOT_URL}"
echo "First login creates admin account."

echo ""
echo "--- Gen AI Playground (trusted in-cluster path, bypasses MaaS) ---"
echo "OpenShift AI → Gen AI studio → Playground"
echo "Project: models-as-a-service"
echo "OGXServer: ogx-genai-playground (CPU; HTTPS ClusterIP to Qwen, bypasses MaaS)"
echo "Prompt: Write a short Ansible task to install and start nginx on RHEL 9"
echo "Optional MCP: How many pods are running in models-as-a-service?"
echo "Playground tokens are not counted on Observability → Usage."

echo ""
echo "--- API Keys ---"
DEVSPACES_KEY=$(oc get secret devspaces-maas-apikey -n openshift-devspaces -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || echo "N/A")
CHATBOT_KEY=$(oc get secret chatbot-maas-apikey -n open-webui -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || echo "N/A")
echo "Dev Spaces key: ${DEVSPACES_KEY:0:20}..."
echo "Chatbot key:    ${CHATBOT_KEY:0:20}..."

echo ""
echo "--- Agent identity (optional) ---"
AGENT_CONSOLE=$(oc get route agent-console -n agent-governance -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "${AGENT_CONSOLE}" ]]; then
  echo "Presenter page: https://${AGENT_CONSOLE}"
else
  echo "Not installed. After phases 0-10: bash setup/11-agent-identity.sh"
fi

echo ""
echo "========================================="
