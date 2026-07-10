#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "  Demo Credentials and URLs"
echo "========================================="

echo ""
echo "--- OpenShift ---"
echo "Console: https://console-openshift-console.${CLUSTER_DOMAIN}"
echo "User: $(oc whoami)"

echo ""
echo "--- RHOAI Dashboard ---"
RHOAI_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
echo "URL: https://${RHOAI_URL}"

echo ""
echo "--- MaaS ---"
echo "MaaS API: ${MAAS_URL}"
echo "Health: ${MAAS_URL}/maas-api/health"

echo ""
echo "--- Dev Spaces ---"
DEVSPACES_URL=$(oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "N/A")
echo "Dashboard: ${DEVSPACES_URL}"
echo "Workspace: ${DEVSPACES_URL}/#https://github.com/alezzandro/ocp-maas-devspaces-chatbot?devfilePath=devspaces-workspace/devfile.yaml"

echo ""
echo "--- Chatbot (Open WebUI) ---"
CHATBOT_URL=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
echo "URL: https://${CHATBOT_URL}"
echo "First login creates admin account."

echo ""
echo "--- API Keys ---"
DEVSPACES_KEY=$(oc get secret devspaces-maas-apikey -n openshift-devspaces -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || echo "N/A")
CHATBOT_KEY=$(oc get secret chatbot-maas-apikey -n open-webui -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || echo "N/A")
echo "Dev Spaces key: ${DEVSPACES_KEY:0:20}..."
echo "Chatbot key:    ${CHATBOT_KEY:0:20}..."

echo ""
echo "========================================="
