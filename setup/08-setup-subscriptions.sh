#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 8: Setup Subscriptions"
echo "========================================="

CURRENT_USER=$(oc whoami)

echo "1. Creating OpenShift groups..."
oc adm groups new devspaces-users --dry-run=client -o yaml | oc apply -f -
oc adm groups new chatbot-users --dry-run=client -o yaml | oc apply -f -

echo "2. Adding current user (${CURRENT_USER}) to both groups..."
oc adm groups add-users devspaces-users "${CURRENT_USER}" 2>/dev/null || true
oc adm groups add-users chatbot-users "${CURRENT_USER}" 2>/dev/null || true

echo "3. Creating models-as-a-service namespace..."
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f -

echo "4. Applying MaaS Subscriptions..."
oc apply -f "${MANIFESTS_DIR}/subscriptions/devspaces-subscription.yaml"
oc apply -f "${MANIFESTS_DIR}/subscriptions/chatbot-subscription.yaml"

echo "5. Applying MaaS Auth Policies..."
oc apply -f "${MANIFESTS_DIR}/subscriptions/devspaces-auth-policy.yaml"
oc apply -f "${MANIFESTS_DIR}/subscriptions/chatbot-auth-policy.yaml"

echo "6. Generating API keys for each subscription..."
TOKEN=$(oc whoami -t)

echo "   Creating Dev Spaces API key..."
DEVSPACES_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "devspaces-key", "subscription": "devspaces-subscription"}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")

echo "   Creating Chatbot API key..."
CHATBOT_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "chatbot-key", "subscription": "chatbot-subscription"}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")

echo "7. Storing API keys in secrets..."
oc create namespace openshift-devspaces --dry-run=client -o yaml | oc apply -f -
oc create namespace open-webui --dry-run=client -o yaml | oc apply -f -

if [[ -n "$DEVSPACES_KEY" ]]; then
  oc create secret generic devspaces-maas-apikey \
    -n openshift-devspaces \
    --from-literal=api-key="${DEVSPACES_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "   Dev Spaces API key stored."
else
  echo "   WARNING: Could not generate Dev Spaces API key."
fi

if [[ -n "$CHATBOT_KEY" ]]; then
  oc create secret generic chatbot-maas-apikey \
    -n open-webui \
    --from-literal=api-key="${CHATBOT_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "   Chatbot API key stored."
else
  echo "   WARNING: Could not generate Chatbot API key."
fi

echo ""
echo "Phase 8 complete: Two independent subscriptions with API keys configured."
echo "========================================="
