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

echo "3. Creating Continue AI extension config (auto-mounted into workspaces)..."
DEVSPACES_KEY=$(oc get secret devspaces-maas-apikey -n openshift-devspaces \
  -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || echo "PLACEHOLDER_KEY")

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: continue-ai-config
  namespace: openshift-devspaces
  labels:
    app.kubernetes.io/part-of: che.eclipse.org
    app.kubernetes.io/component: workspaces-config
    controller.devfile.io/mount-to-devworkspace: "true"
    controller.devfile.io/watch-secret: "true"
  annotations:
    controller.devfile.io/mount-path: "/home/user/.continue"
    controller.devfile.io/mount-as: "subpath"
type: Opaque
stringData:
  config.json: |
    {
      "models": [
        {
          "title": "Qwen3-8B via MaaS",
          "model": "qwen3-8b-fp8",
          "apiBase": "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/qwen3-8b-fp8/v1",
          "provider": "openai",
          "apiKey": "${DEVSPACES_KEY}"
        }
      ],
      "tabAutocompleteModel": {
        "title": "Qwen3-8B via MaaS",
        "model": "qwen3-8b-fp8",
        "apiBase": "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/qwen3-8b-fp8/v1",
        "provider": "openai",
        "apiKey": "${DEVSPACES_KEY}"
      },
      "tabAutocompleteOptions": {
        "useCopyBuffer": false,
        "maxPromptTokens": 2048,
        "prefixPercentage": 0.5
      }
    }
EOF
echo "   Continue config Secret created (auto-mounted to /home/user/.continue/config.json)."

DEVSPACES_URL=$(oc get checluster devspaces -n openshift-devspaces \
  -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "")

echo ""
echo "   MaaS endpoint: https://maas.${CLUSTER_DOMAIN}/models-as-a-service/qwen3-8b-fp8/v1"
echo "   Dev Spaces URL: ${DEVSPACES_URL}"
echo ""
echo "   The Continue extension config is auto-mounted into all workspaces."
echo "   No git commit needed -- credentials are injected dynamically."
echo ""
echo "   To create a workspace, navigate to:"
echo "   ${DEVSPACES_URL}/#https://github.com/alezzandro/ocp-maas-devspaces-chatbot?devfilePath=devspaces-workspace/devfile.yaml"

echo ""
echo "Phase 9 complete: Dev Spaces ready."
echo "========================================="
