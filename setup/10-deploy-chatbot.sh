#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"
LLM_NAME="qwen3-8b-fp8"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 10: Deploy Chatbot (Open WebUI)"
echo "========================================="

MAAS_ENDPOINT="${MAAS_URL}/models-as-a-service/${LLM_NAME}/v1"

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

# ConfigVars persist on the PVC after first start, so env alone does not update
# an existing instance. Patch sqlite, then restart so in-memory config reloads.
echo "7. Forcing legacy function calling (Open WebUI 0.10+ Native/Agentic default)..."
oc exec -n open-webui deploy/open-webui -- python3 -c '
import json, sqlite3, time
db = "/app/backend/data/webui.db"
con = sqlite3.connect(db)
cur = con.cursor()
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
    print("set", key, stored)
con.commit()
print("webui config patched")
' && oc rollout restart deployment/open-webui -n open-webui && \
  oc rollout status deployment/open-webui -n open-webui --timeout=180s || \
  echo "   WARNING: could not patch Open WebUI sqlite; new PVCs still pick DEFAULT_MODEL_PARAMS from env."

ROUTE_URL=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo ""
echo "Phase 10 complete: Open WebUI deployed (ops MaaS subscription)."
echo "Chatbot URL: https://${ROUTE_URL}"
echo "========================================="
