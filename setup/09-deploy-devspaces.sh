#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 9: Deploy Dev Spaces"
echo "========================================="

echo "1. Creating CheCluster..."
oc apply -k "${MANIFESTS_DIR}/devspaces/"

echo "2. Waiting for Dev Spaces to be ready..."
TIMEOUT=600
INTERVAL=30
ELAPSED=0
while true; do
  PHASE=$(oc get checluster devspaces -n openshift-devspaces \
    -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "Unknown")
  if [[ "$PHASE" == "Active" ]]; then
    echo "   Dev Spaces is Active!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: Dev Spaces not Active after ${TIMEOUT}s."
    break
  fi
  echo "   CheCluster phase: ${PHASE} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "3. Configuring Continue extension with live MaaS credentials..."
DEVSPACES_KEY=$(oc get secret devspaces-maas-apikey -n openshift-devspaces \
  -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || echo "PLACEHOLDER_KEY")

CONTINUE_CONFIG="${REPO_ROOT}/devspaces-workspace/continue-config.json"
sed -i "s|CLUSTER_DOMAIN_PLACEHOLDER|${CLUSTER_DOMAIN}|g" "$CONTINUE_CONFIG"
sed -i "s|DEVSPACES_API_KEY_PLACEHOLDER|${DEVSPACES_KEY}|g" "$CONTINUE_CONFIG"
echo "   Updated continue-config.json with live credentials."

DEVSPACES_URL=$(oc get checluster devspaces -n openshift-devspaces \
  -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "")

echo ""
echo "   MaaS endpoint: ${MAAS_URL}/models-as-a-service/qwen3-8b-fp8/v1"
echo "   Dev Spaces URL: ${DEVSPACES_URL}"
echo ""
echo "   IMPORTANT: Commit and push continue-config.json so the workspace gets"
echo "   the correct credentials when it clones the repo."
echo ""
echo "   To create a workspace, navigate to:"
echo "   ${DEVSPACES_URL}/#https://github.com/alezzandro/ocp-maas-devspaces-chatbot?devfilePath=devspaces-workspace/devfile.yaml"

echo ""
echo "Phase 9 complete: Dev Spaces ready."
echo "========================================="
