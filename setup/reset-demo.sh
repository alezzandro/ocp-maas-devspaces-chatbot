#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "  Reset Demo State"
echo "========================================="
echo "This removes demo artifacts without uninstalling platform components."

echo "1. Deleting chatbot API keys..."
oc delete secret chatbot-maas-apikey -n open-webui --ignore-not-found
oc delete secret devspaces-maas-apikey -n openshift-devspaces --ignore-not-found

echo "2. Revoking MaaS API keys..."
TOKEN=$(oc whoami -t)
curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys/bulk-revoke" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' 2>/dev/null || true

echo "3. Restarting Open WebUI (clear session data)..."
oc rollout restart deployment/open-webui -n open-webui 2>/dev/null || true

echo "4. Deleting Dev Spaces workspaces..."
oc delete devworkspace --all -n openshift-devspaces 2>/dev/null || true

echo "5. Re-generating API keys..."
bash "${SCRIPT_DIR}/08-setup-subscriptions.sh" 2>/dev/null || true

echo ""
echo "Demo state reset. Run show-credentials.sh for new URLs/keys."
echo "========================================="
