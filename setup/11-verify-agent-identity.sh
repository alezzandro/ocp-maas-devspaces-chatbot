#!/bin/bash
# Checks for the optional agent-identity lab, plus the MaaS objects it must not change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  if [[ "$result" == "true" || "$result" == "True" || "$result" == "ok" ]]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc (got: $result)"
    FAIL=$((FAIL + 1))
  fi
}

echo "========================================="
echo "Verify agent identity lab"
echo "========================================="

echo "1. Policy decision self-test..."
if python3 "${REPO_ROOT}/agent/app.py" self-test; then
  check "tool policy matrix" "true"
else
  check "tool policy matrix" "false"
fi

echo "2. MaaS objects this lab must not own..."
ENF="$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo missing)"
check "maas-gateway-auth Enforced" "$ENF"
TARGET="$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
  -o jsonpath='{.spec.targetRef.name}' 2>/dev/null || echo missing)"
check "maas-gateway-auth still targets maas-default-gateway" "$([[ "$TARGET" == "maas-default-gateway" ]] && echo true || echo false)"
PROG="$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo missing)"
check "maas-default-gateway Programmed" "$PROG"
URL="$(oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications \
  -o jsonpath='{.data.OpenShift-MCP-Server}' 2>/dev/null || echo missing)"
check "playground MCP URL is still the ClusterIP" "$([[ "$URL" == *"openshift-mcp-server.models-as-a-service.svc.cluster.local"* ]] && echo true || echo false)"
if oc get catalogsource kuadrant-operator-catalog -n kuadrant-system >/dev/null 2>&1; then
  check "no community Kuadrant catalog" "false"
else
  check "no community Kuadrant catalog" "true"
fi

AGENT_TARGET="$(oc get authpolicy agent-mcp-auth -n openshift-ingress \
  -o jsonpath='{.spec.targetRef.name}' 2>/dev/null || echo missing)"
if [[ "$AGENT_TARGET" == "missing" ]]; then
  echo "  [NOTE] agent-mcp-auth is absent; tool checks use the in-namespace proxy."
elif [[ "$AGENT_TARGET" == "agent-mcp-gateway" ]]; then
  check "agent AuthPolicy targets agent-mcp-gateway" "true"
  GW_HOST="$(oc get gateway agent-mcp-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || echo "")"
  GW_CODE="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "https://${GW_HOST}/mcp" -H 'Content-Type: application/json' -d '{}' || echo curl-failed)"
  check "agent gateway rejects a missing token with 401" "$([[ "$GW_CODE" == "401" ]] && echo true || echo "$GW_CODE")"
  CONSOLE_CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://agent-console.${CLUSTER_DOMAIN}/" || echo curl-failed)"
  check "presenter page is served" "$([[ "$CONSOLE_CODE" == "200" ]] && echo true || echo "$CONSOLE_CODE")"
else
  check "agent AuthPolicy targets agent-mcp-gateway" "false"
fi

echo "3. SPIFFE token and tool decisions..."
exec_check() {
  local deploy="$1"
  local tool="$2"
  local expect="$3"
  local desc="$4"
  local out rc
  set +e
  out="$(oc exec -n agent-governance "deploy/${deploy}" -- python3 /opt/app/app.py call "$tool" "$expect" 2>&1)"
  rc=$?
  set -e
  echo "$out" | tail -20
  check "$desc" "$([[ "$rc" -eq 0 ]] && echo true || echo false)"
}

exec_check platform-agent pods_list 200 "platform-agent pods_list allowed"
exec_check platform-agent pods_log 403 "platform-agent pods_log denied"
exec_check untrusted-agent pods_list 403 "untrusted-agent pods_list denied"

echo "4. Direct vLLM call (bypasses MaaS)..."
set +e
MODEL_OUT="$(oc exec -n agent-governance deploy/platform-agent -- python3 /opt/app/app.py ask-model 2>&1)"
MODEL_RC=$?
set -e
echo "$MODEL_OUT" | tail -20
if [[ "$MODEL_RC" -eq 0 ]]; then
  check "platform-agent reached vLLM without a MaaS API key" "true"
else
  echo "  [NOTE] vLLM call failed. The model pod may still be starting. This does not change MaaS auth."
  check "platform-agent reached vLLM without a MaaS API key" "false"
fi

echo ""
echo "Passed: ${PASS}  Failed: ${FAIL}"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "========================================="
