#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"
LLM_NAME="qwen3-8b-fp8"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 8: Setup Subscriptions"
echo "========================================="

CURRENT_USER=$(oc whoami)
KEY_OWNER="${DEMO_ADMIN_USER:-}"
if [[ -z "${KEY_OWNER}" || "${KEY_OWNER}" == system:* ]]; then
  if [[ "${CURRENT_USER}" != system:* ]]; then
    KEY_OWNER="${CURRENT_USER}"
  else
    KEY_OWNER="admin"
  fi
fi

echo "1. Creating OpenShift groups..."
# Do not `oc apply` an empty Group: last-applied users:null wipes members.
for g in devspaces-users chatbot-users; do
  oc get group "${g}" &>/dev/null || oc adm groups new "${g}"
done

echo "2. Adding users to both groups (key owner: ${KEY_OWNER})..."
for g in devspaces-users chatbot-users; do
  oc adm groups add-users "${g}" "${KEY_OWNER}" 2>/dev/null || true
  if [[ "${CURRENT_USER}" != "${KEY_OWNER}" && "${CURRENT_USER}" != system:* ]]; then
    oc adm groups add-users "${g}" "${CURRENT_USER}" 2>/dev/null || true
  fi
done

echo "3. Ensuring models-as-a-service namespace (RHOAI project labels)..."
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

echo "4. Ensuring MaaS Gateway AuthPolicy is enforced..."
# RHOAI 3.5: Gateway opendatahub.io/managed=false prevents {gateway}-authn
# from overriding maas-gateway-auth. LLMInferenceService enable-auth must
# stay true: false creates anonymous *-kserve-route-authn, which wipes
# auth.identity so Limitador/Usage never increment.
# https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/
oc annotate gateway maas-default-gateway -n openshift-ingress \
  opendatahub.io/managed=false --overwrite
oc annotate llminferenceservice "${LLM_NAME}" -n models-as-a-service \
  security.opendatahub.io/enable-auth=true --overwrite 2>/dev/null || true
oc delete authpolicy maas-default-gateway-authn -n openshift-ingress --ignore-not-found
oc delete authpolicy "${LLM_NAME}-kserve-route-authn" -n models-as-a-service --ignore-not-found
AUTH_REASON=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || echo "")
if [[ "$AUTH_REASON" == "MissingDependency" ]]; then
  echo "   Kuadrant still reports Authorino missing. Recreating the operator pod..."
  oc delete pod -n openshift-operators -l app=kuadrant,control-plane=controller-manager \
    --wait=true 2>/dev/null || true
  oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=180s \
    2>/dev/null || true
fi
TLS_ON=$(oc get authorino authorino -n kuadrant-system \
  -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo "false")
if [[ "$TLS_ON" != "true" ]] && oc get svc authorino-authorino-authorization -n kuadrant-system &>/dev/null; then
  echo "   Enabling Authorino listener TLS so the gateway auth cluster can connect..."
  oc annotate service authorino-authorino-authorization -n kuadrant-system \
    service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
  for _ in $(seq 1 30); do
    oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && break
    sleep 2
  done
  oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
    "spec": {"listener": {"tls": {"enabled": true, "certSecretRef": {"name": "authorino-server-cert"}}}}
  }' 2>/dev/null || true
fi
AUTH_WAIT=180
AUTH_ELAPSED=0
while true; do
  ENFORCED=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "False")
  if [[ "${ENFORCED}" == "True" ]]; then
    echo "   maas-gateway-auth is Enforced."
    break
  fi
  if [[ "${AUTH_ELAPSED}" -ge "${AUTH_WAIT}" ]]; then
    echo "   WARNING: maas-gateway-auth not Enforced after ${AUTH_WAIT}s (status=${ENFORCED})."
    oc get authpolicy -n openshift-ingress
    break
  fi
  echo "   Waiting for maas-gateway-auth Enforced=True (${AUTH_ELAPSED}s / ${AUTH_WAIT}s)"
  sleep 5
  AUTH_ELAPSED=$((AUTH_ELAPSED + 5))
done

echo "5. Applying MaaS Subscriptions..."
oc apply -f "${MANIFESTS_DIR}/subscriptions/devspaces-subscription.yaml"
oc apply -f "${MANIFESTS_DIR}/subscriptions/chatbot-subscription.yaml"
oc apply -f "${MANIFESTS_DIR}/model/maas-model-ref.yaml"
oc delete maasmodelref qwen3-8b -n models-as-a-service --ignore-not-found

echo "6. Applying MaaS Auth Policies..."
oc apply -f "${MANIFESTS_DIR}/subscriptions/devspaces-auth-policy.yaml"
oc apply -f "${MANIFESTS_DIR}/subscriptions/chatbot-auth-policy.yaml"

echo "   Waiting for MaaSAuthPolicies to leave Pending..."
POL_WAIT=120
POL_ELAPSED=0
while true; do
  PENDING=$(oc get maasauthpolicy -n models-as-a-service \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Pending || true)
  if [[ "${PENDING}" -eq 0 ]]; then
    echo "   MaaSAuthPolicies are no longer Pending."
    break
  fi
  if [[ "${POL_ELAPSED}" -ge "${POL_WAIT}" ]]; then
    echo "   WARNING: MaaSAuthPolicy still Pending after ${POL_WAIT}s."
    oc get maasauthpolicy -n models-as-a-service
    break
  fi
  echo "   Pending policies: ${PENDING} (${POL_ELAPSED}s / ${POL_WAIT}s)"
  sleep 5
  POL_ELAPSED=$((POL_ELAPSED + 5))
done

echo "7. Generating API keys for each subscription..."
# In-cluster bootstrapper uses a ServiceAccount token. Authorino would mint
# keys as system:serviceaccount:… unless we pass X-MaaS-Username / X-MaaS-Group.
MAAS_API_NS="redhat-ai-gateway-infra"
if ! oc get deploy maas-api -n "${MAAS_API_NS}" &>/dev/null; then
  MAAS_API_NS="redhat-ods-applications"
fi

mint_maas_key() {
  local name="$1"
  local subscription="$2"
  local groups_json="$3"
  oc exec -n "${MAAS_API_NS}" deploy/maas-api -- \
    curl -sk -S -m 30 -X POST "https://127.0.0.1:8443/v1/api-keys" \
      -H "Content-Type: application/json" \
      -H "X-MaaS-Username: ${KEY_OWNER}" \
      -H "X-MaaS-Group: ${groups_json}" \
      -d "{\"name\":\"${name}\",\"subscription\":\"${subscription}\",\"expiresIn\":\"90d\"}"
}

secret_key() {
  oc get secret "$1" -n "$2" -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || true
}

maas_key_works() {
  local key="$1"
  [[ -n "${key}" ]] || return 1
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" -m 15 \
    -H "Authorization: Bearer ${key}" \
    "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/${LLM_NAME}/v1/models" 2>/dev/null || echo "000")
  [[ "${code}" == "200" ]]
}

echo "   Creating Dev Spaces API key (owner=${KEY_OWNER})..."
DEVSPACES_KEY="$(secret_key devspaces-maas-apikey openshift-devspaces)"
if maas_key_works "${DEVSPACES_KEY}"; then
  echo "   Reusing existing Dev Spaces API key (still valid)."
else
  DEVSPACES_RESP=$(mint_maas_key "devspaces-key" "devspaces-subscription" '["devspaces-users"]')
  DEVSPACES_KEY=$(python3 -c "import sys,json; print(json.loads(sys.argv[1]).get('key',''))" "${DEVSPACES_RESP}" 2>/dev/null || echo "")
  if [[ -z "${DEVSPACES_KEY}" ]]; then
    echo "   Dev Spaces key response: ${DEVSPACES_RESP}"
  fi
fi

echo "   Creating Chatbot API key (owner=${KEY_OWNER})..."
CHATBOT_KEY="$(secret_key chatbot-maas-apikey open-webui)"
if maas_key_works "${CHATBOT_KEY}"; then
  echo "   Reusing existing Chatbot API key (still valid)."
else
  CHATBOT_RESP=$(mint_maas_key "chatbot-key" "chatbot-subscription" '["chatbot-users"]')
  CHATBOT_KEY=$(python3 -c "import sys,json; print(json.loads(sys.argv[1]).get('key',''))" "${CHATBOT_RESP}" 2>/dev/null || echo "")
  if [[ -z "${CHATBOT_KEY}" ]]; then
    echo "   Chatbot key response: ${CHATBOT_RESP}"
  fi
fi

echo "8. Storing API keys in secrets..."
oc create namespace openshift-devspaces --dry-run=client -o yaml | oc apply -f -
oc create namespace open-webui --dry-run=client -o yaml | oc apply -f -

if [[ -n "$DEVSPACES_KEY" ]]; then
  oc create secret generic devspaces-maas-apikey \
    -n openshift-devspaces \
    --from-literal=api-key="${DEVSPACES_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "   Dev Spaces API key stored."
else
  echo "   ERROR: Could not generate Dev Spaces API key."
  exit 1
fi

if [[ -n "$CHATBOT_KEY" ]]; then
  oc create secret generic chatbot-maas-apikey \
    -n open-webui \
    --from-literal=api-key="${CHATBOT_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "   Chatbot API key stored."
else
  echo "   ERROR: Could not generate Chatbot API key."
  exit 1
fi

echo "9. Enabling MaaS telemetry for Usage Dashboard..."
TELEMETRY_PATCH='{
  "spec": {
    "telemetry": {
      "enabled": true,
      "metrics": {
        "captureOrganization": false,
        "captureUser": true,
        "captureGroup": false,
        "captureModelUsage": true
      }
    }
  }
}'
if oc get maastenantconfig default-tenant -n models-as-a-service &>/dev/null; then
  oc patch maastenantconfig default-tenant -n models-as-a-service --type merge -p "${TELEMETRY_PATCH}"
  echo "   MaasTenantConfig/default-tenant telemetry enabled."
elif oc get tenants.maas.opendatahub.io default-tenant -n models-as-a-service &>/dev/null; then
  oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service --type merge -p "${TELEMETRY_PATCH}"
  echo "   Tenant/default-tenant telemetry enabled."
else
  echo "   WARNING: No default-tenant (MaasTenantConfig or Tenant) found; skipping telemetry patch."
fi

echo "   Waiting for TelemetryPolicy to be created..."
TIMEOUT=60
INTERVAL=5
ELAPSED=0
while true; do
  if oc get telemetrypolicy maas-telemetry -n openshift-ingress &>/dev/null; then
    echo "   TelemetryPolicy is available."
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: TelemetryPolicy not found after ${TIMEOUT}s."
    break
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
echo "Phase 8 complete: Two independent subscriptions with API keys and telemetry configured."
echo "========================================="
