#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"
LLM_NAME="qwen3-8b-fp8"
MODEL_ID="qwen3-8b-fp8"
MAAS_MODEL_PATH="models-as-a-service/${LLM_NAME}/v1"

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

# Do not put Open VSX HTML URLs in CheCluster defaultPlugins — Che fetches those
# URIs as plugin YAML and the factory fails (mapping values are not allowed).
CHE_PLUGINS=$(oc get checluster devspaces -n openshift-devspaces \
  -o jsonpath='{.spec.devEnvironments.defaultPlugins}' 2>/dev/null || echo "")
if echo "${CHE_PLUGINS}" | grep -qi 'open-vsx.org'; then
  echo "   Removing CheCluster defaultPlugins Open VSX URIs (they break factory YAML parse)..."
  oc patch checluster devspaces -n openshift-devspaces --type json \
    -p '[{"op":"remove","path":"/spec/devEnvironments/defaultPlugins"}]' 2>/dev/null || true
fi

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
    controller.devfile.io/mount-path: "/etc/continue-config"
    controller.devfile.io/mount-as: "subpath"
type: Opaque
stringData:
  config.json: |
    {
      "models": [
        {
          "title": "Qwen3-8B via MaaS",
          "model": "${MODEL_ID}",
          "apiBase": "https://maas.${CLUSTER_DOMAIN}/${MAAS_MODEL_PATH}",
          "provider": "openai",
          "apiKey": "${DEVSPACES_KEY}"
        }
      ],
      "tabAutocompleteModel": {
        "title": "Qwen3-8B via MaaS",
        "model": "${MODEL_ID}",
        "apiBase": "https://maas.${CLUSTER_DOMAIN}/${MAAS_MODEL_PATH}",
        "provider": "openai",
        "apiKey": "${DEVSPACES_KEY}"
      },
      "tabAutocompleteOptions": {
        "useCopyBuffer": false,
        "maxPromptTokens": 2048,
        "prefixPercentage": 0.5
      }
    }
  config.yaml: |
    name: Local Assistant
    version: 1.0.0
    schema: v1
    models:
      - name: Qwen3-8B via MaaS
        provider: openai
        model: ${MODEL_ID}
        apiBase: https://maas.${CLUSTER_DOMAIN}/${MAAS_MODEL_PATH}
        apiKey: "${DEVSPACES_KEY}"
        roles:
          - chat
          - edit
          - apply
          - autocomplete
EOF
echo "   Continue config Secret created (mounted to /etc/continue-config/)."

echo "4. Installing VS Code recommendations (Continue) into Dev Spaces user namespaces..."
# che-code looks up ConfigMap vscode-editor-configurations in the *workspace*
# namespace (e.g. admin-devspaces), not in openshift-devspaces.
# https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/3.29/html/administration_guide/configuring-visual-studio-code
USER_NS=$(oc get ns -l app.kubernetes.io/component=workspaces-namespace \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "${USER_NS}" ]]; then
  echo "   No user workspace namespaces yet. Re-run this script after the first DevWorkspace is created."
else
  while IFS= read -r ns; do
    [[ -z "${ns}" ]] && continue
    oc apply -n "${ns}" -f "${MANIFESTS_DIR}/devspaces/vscode-editor-configurations.yaml"
    oc apply -n "${ns}" -f "${MANIFESTS_DIR}/devspaces/vscode-default-extensions.yaml"
    echo "   Applied vscode-editor-configurations + vscode-default-extensions in ${ns}"
    # Restart so che-code re-reads editor ConfigMaps.
    oc delete pod -n "${ns}" -l controller.devfile.io/devworkspace --ignore-not-found 2>/dev/null || true
  done <<< "${USER_NS}"
fi

DEVSPACES_URL=$(oc get checluster devspaces -n openshift-devspaces \
  -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "")

echo ""
echo "   MaaS endpoint: https://maas.${CLUSTER_DOMAIN}/${MAAS_MODEL_PATH}"
echo "   Dev Spaces URL: ${DEVSPACES_URL}"
echo ""
echo "   The Continue extension config is auto-mounted into all workspaces."
echo "   No git commit needed -- credentials are injected dynamically."
echo "   After the first workspace exists, re-run this script so Continue ConfigMaps land in the user namespace."
echo ""
echo "   To create a workspace, navigate to:"
echo "   ${DEVSPACES_URL}/#https://github.com/alezzandro/ocp-maas-devspaces-chatbot?devfilePath=devspaces-workspace/devfile.yaml"

echo ""
echo "Phase 9 complete: Dev Spaces ready."
echo "========================================="
