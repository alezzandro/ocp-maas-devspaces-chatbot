#!/bin/bash
# Optional agent-identity lab. Not called by setup/full-setup.sh.
# Requires the Models-as-a-Service lab (phases 0-10) to already be in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS="${REPO_ROOT}/manifests/agent-governance"
PART="agent-identity-lab"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Optional: Agent identity (SPIFFE + MCP)"
echo "========================================="

STORAGE_CLASS="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' | head -1)"
if [[ -z "${STORAGE_CLASS}" ]]; then
  echo "ERROR: no default StorageClass. SPIRE Server needs a 1Gi persistent volume."
  exit 1
fi

TRUST_DOMAIN="${CLUSTER_DOMAIN}"
JWT_ISSUER="https://oidc-discovery.${CLUSTER_DOMAIN}"
OIDC_JWKS_URL="http://oidc-pending.invalid/keys"
AGENT_IMAGE="image-registry.openshift-image-registry.svc:5000/agent-governance/platform-agent:latest"

render() {
  sed \
    -e "s|__CLUSTER_DOMAIN__|${CLUSTER_DOMAIN}|g" \
    -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
    -e "s|__JWT_ISSUER__|${JWT_ISSUER}|g" \
    -e "s|__TRUST_DOMAIN__|${TRUST_DOMAIN}|g" \
    -e "s|__OIDC_JWKS_URL__|${OIDC_JWKS_URL}|g" \
    -e "s|__AGENT_IMAGE__|${AGENT_IMAGE}|g" \
    "$1"
}

apply_rendered() {
  render "$1" | oc apply -f -
}

refuse_foreign() {
  local kind="$1"
  local name="$2"
  local ns="${3:-}"
  local args=(get "$kind" "$name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')
  if [[ -n "$ns" ]]; then
    args=(get "$kind" "$name" -n "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')
  fi
  if ! oc get "$kind" "$name" ${ns:+-n "$ns"} >/dev/null 2>&1; then
    return 0
  fi
  local part
  part="$(oc "${args[@]}" 2>/dev/null || true)"
  if [[ "$part" != "$PART" ]]; then
    echo "ERROR: ${kind}/${name} already exists and is not labeled ${PART}."
    echo "       Refusing to replace an identity or policy stack this lab did not create."
    exit 1
  fi
}

assert_maas() {
  local enf prog url
  enf="$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo missing)"
  prog="$(oc get gateway maas-default-gateway -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo missing)"
  url="$(oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications \
    -o jsonpath='{.data.OpenShift-MCP-Server}' 2>/dev/null || echo missing)"
  if [[ "$enf" != "True" || "$prog" != "True" ]]; then
    echo "ERROR: MaaS gateway check failed (Enforced=${enf} Programmed=${prog})."
    return 1
  fi
  if [[ "$url" != *"openshift-mcp-server.models-as-a-service.svc.cluster.local"* ]]; then
    echo "ERROR: playground MCP URL is no longer the ClusterIP."
    echo "$url"
    return 1
  fi
  local target
  target="$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
    -o jsonpath='{.spec.targetRef.name}' 2>/dev/null || echo missing)"
  if [[ "$target" != "maas-default-gateway" ]]; then
    echo "ERROR: maas-gateway-auth target is ${target}."
    return 1
  fi
  echo "   MaaS gateway Programmed, maas-gateway-auth Enforced, playground MCP URL unchanged."
}

rollback_agent_gateway() {
  echo "   Removing the agent MCP gateway so it cannot stay attached to the MaaS listener."
  oc delete authpolicy agent-mcp-auth -n openshift-ingress --ignore-not-found
  oc delete httproute agent-mcp -n agent-governance --ignore-not-found
  oc delete envoyfilter agent-mcp-gateway-authn-ssl -n openshift-ingress --ignore-not-found
  oc delete gateway agent-mcp-gateway -n openshift-ingress --ignore-not-found
  sleep 20
}

wait_named() {
  local kind="$1"
  local ns="$2"
  local name="$3"
  local timeout="$4"
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local ready desired
    if [[ "$kind" == "daemonset" ]]; then
      ready="$(oc get daemonset "$name" -n "$ns" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
      desired="$(oc get daemonset "$name" -n "$ns" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
    elif [[ "$kind" == "statefulset" ]]; then
      ready="$(oc get statefulset "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
      desired="$(oc get statefulset "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    else
      ready="$(oc get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
      desired="$(oc get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    fi
    ready="${ready:-0}"
    desired="${desired:-0}"
    if [[ "$desired" != "0" && "$ready" == "$desired" ]]; then
      echo "   ${kind}/${name} ready (${ready}/${desired})."
      return 0
    fi
    echo "   waiting ${kind}/${name} ${ready}/${desired} (${elapsed}s / ${timeout}s)"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  oc get "$kind" "$name" -n "$ns" -o wide || true
  oc describe "$kind" "$name" -n "$ns" | tail -30 || true
  return 1
}

echo "1. Confirming the existing MaaS lab is intact..."
assert_maas

echo "2. Refusing to overwrite a SPIRE or Gatekeeper install this lab did not create..."
refuse_foreign spireserver.operator.openshift.io cluster
refuse_foreign gatekeeper.operator.gatekeeper.sh gatekeeper

echo "3. Namespace, quota, NetworkPolicy, ServiceAccounts..."
oc apply -f "${MANIFESTS}/namespace.yaml"
oc apply -f "${MANIFESTS}/resource-quota.yaml"
oc apply -f "${MANIFESTS}/limitrange.yaml"
oc apply -f "${MANIFESTS}/network-policy.yaml"
oc apply -f "${MANIFESTS}/serviceaccounts.yaml"

echo "4. Zero Trust Workload Identity Manager operator..."
oc apply -f "${MANIFESTS}/zero-trust/subscription.yaml"
echo "   Waiting for the CSV to succeed..."
CSV_OK=0
for _ in $(seq 1 60); do
  PHASE="$(oc get csv -n zero-trust-workload-identity-manager -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    if item["metadata"]["name"].startswith("zero-trust-workload-identity-manager"):
        print(item.get("status", {}).get("phase", ""))
        break
')"
  if [[ "$PHASE" == "Succeeded" ]]; then
    CSV_OK=1
    break
  fi
  if [[ "$PHASE" == "Failed" ]]; then
    oc get csv -n zero-trust-workload-identity-manager -o name | grep zero-trust || true
    echo "ERROR: Zero Trust Workload Identity Manager CSV failed."
    exit 1
  fi
  sleep 10
done
if [[ "$CSV_OK" != "1" ]]; then
  oc get csv -n zero-trust-workload-identity-manager | grep zero-trust || true
  echo "ERROR: Zero Trust Workload Identity Manager did not become Succeeded."
  exit 1
fi
echo "   CSV Succeeded."
oc wait --for=condition=Established crd/zerotrustworkloadidentitymanagers.operator.openshift.io --timeout=180s

echo "5. SPIRE operands (manager, server, agent, CSI, OIDC)..."
apply_rendered "${MANIFESTS}/zero-trust/ztwim.yaml"
apply_rendered "${MANIFESTS}/zero-trust/spire-server.yaml"
wait_named statefulset zero-trust-workload-identity-manager spire-server 600
apply_rendered "${MANIFESTS}/zero-trust/spire-agent.yaml"
wait_named daemonset zero-trust-workload-identity-manager spire-agent 600
apply_rendered "${MANIFESTS}/zero-trust/spiffe-csi.yaml"
wait_named daemonset zero-trust-workload-identity-manager spire-spiffe-csi-driver 600
apply_rendered "${MANIFESTS}/zero-trust/oidc.yaml"
wait_named deployment zero-trust-workload-identity-manager spire-spiffe-oidc-discovery-provider 600

echo "6. Workload registration..."
CLASS_NAME="$(oc get clusterspiffeid -o jsonpath='{.items[0].spec.className}' 2>/dev/null || true)"
if [[ -z "$CLASS_NAME" ]]; then
  CLASS_NAME="zero-trust-workload-identity-manager-spire"
fi
sed "s|zero-trust-workload-identity-manager-spire|${CLASS_NAME}|g" \
  "${MANIFESTS}/clusterspiffeid.yaml" | oc apply -f -
echo "   ClusterSPIFFEID class ${CLASS_NAME}."

echo "7. OIDC JWKS URL for the policy proxy..."
OIDC_SVC="$(oc get svc -n zero-trust-workload-identity-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -i oidc | head -1 || true)"
if [[ -z "$OIDC_SVC" ]]; then
  echo "ERROR: SPIRE OIDC Service was not created."
  exit 1
fi
OIDC_PORT="$(oc get svc "$OIDC_SVC" -n zero-trust-workload-identity-manager -o jsonpath='{.spec.ports[0].port}')"
OIDC_JWKS_URL="https://${OIDC_SVC}.zero-trust-workload-identity-manager.svc:${OIDC_PORT}/keys"
echo "   JWKS ${OIDC_JWKS_URL}"
ROUTE_HOST="$(oc get route -n zero-trust-workload-identity-manager -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
if [[ -n "$ROUTE_HOST" && "$ROUTE_HOST" != "oidc-discovery.${CLUSTER_DOMAIN}" ]]; then
  echo "   NOTE: OIDC route host is ${ROUTE_HOST}."
  echo "         JWT issuer stays ${JWT_ISSUER}. Confirm the route matches before the gateway demo."
fi

echo "8. Build the UBI9 platform-agent image..."
oc apply -f "${MANIFESTS}/build.yaml"
oc start-build platform-agent --from-dir="${REPO_ROOT}/agent" --follow -n agent-governance

echo "9. Proxy and agent Deployments..."
apply_rendered "${MANIFESTS}/workloads.yaml"
oc rollout status deployment/mcp-policy-proxy -n agent-governance --timeout=300s
oc rollout status deployment/platform-agent -n agent-governance --timeout=300s
oc rollout status deployment/untrusted-agent -n agent-governance --timeout=300s
oc rollout status deployment/agent-console -n agent-governance --timeout=300s
apply_rendered "${MANIFESTS}/route.yaml"

echo "10. MCP gateway and AuthPolicy (not the MaaS gateway)..."
RENDERED="$(mktemp)"
render "${MANIFESTS}/authpolicy.yaml" > "$RENDERED"
if grep -A3 'targetRef:' "$RENDERED" | grep -q 'maas-default-gateway'; then
  echo "ERROR: agent AuthPolicy targets maas-default-gateway. Refusing to apply."
  rm -f "$RENDERED"
  exit 1
fi
apply_rendered "${MANIFESTS}/gateway.yaml"
apply_rendered "${MANIFESTS}/httproute.yaml"
oc apply -f "${MANIFESTS}/authn-ssl-envoyfilter.yaml"
oc apply -f "$RENDERED"
rm -f "$RENDERED"
sleep 20
if ! assert_maas; then
  rollback_agent_gateway
  if ! assert_maas; then
    echo "ERROR: MaaS gateway did not recover after removing the agent gateway."
    echo "       Do not patch maas-default-gateway or maas-gateway-auth."
    exit 1
  fi
  echo "   Agent gateway removed. Tool policy remains on the in-namespace proxy."
else
  TARGET="$(oc get authpolicy agent-mcp-auth -n openshift-ingress -o jsonpath='{.spec.targetRef.name}')"
  if [[ "$TARGET" != "agent-mcp-gateway" ]]; then
    echo "ERROR: agent-mcp-auth target is ${TARGET}."
    rollback_agent_gateway
    exit 1
  fi
  echo "   AuthPolicy agent-mcp-auth targets agent-mcp-gateway only."
fi

echo "11. Gatekeeper, namespace-scoped runAsNonRoot..."
oc apply -f "${MANIFESTS}/gatekeeper/subscription.yaml"
GK_OK=0
for _ in $(seq 1 60); do
  PHASE="$(oc get csv -n openshift-operators -o name 2>/dev/null | grep gatekeeper || true)"
  if [[ -n "$PHASE" ]]; then
    CSV_NAME="${PHASE#csv.apps.openshift.io/}"
    CSV_NAME="${CSV_NAME#*/}"
    STATUS="$(oc get csv "$CSV_NAME" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$STATUS" == "Succeeded" ]]; then
      GK_OK=1
      break
    fi
  fi
  sleep 10
done
if [[ "$GK_OK" != "1" ]]; then
  oc get csv -n openshift-operators | grep -i gatekeeper || true
  echo "ERROR: Gatekeeper operator did not become Succeeded."
  exit 1
fi
oc apply -f "${MANIFESTS}/gatekeeper/gatekeeper.yaml"
echo "   Waiting for the Gatekeeper webhook..."
for _ in $(seq 1 60); do
  if oc get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
FP="$(oc get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
  -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null || echo missing)"
if [[ "$FP" != "Ignore" ]]; then
  echo "ERROR: Gatekeeper webhook failurePolicy is ${FP}, expected Ignore."
  echo "       Leaving the constraint unapplied so MaaS admissions are not coupled to this webhook."
  exit 1
fi
oc apply -f "${MANIFESTS}/gatekeeper/constraint-template.yaml"
for _ in $(seq 1 30); do
  if oc get crd k8srequirerunasnonroots.constraints.gatekeeper.sh >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
oc apply -f "${MANIFESTS}/gatekeeper/constraint.yaml"

echo "12. Proving the constraint scope..."
ROOT_POD="$(mktemp)"
cat > "$ROOT_POD" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gatekeeper-root-denied
  namespace: agent-governance
  labels:
    app.kubernetes.io/part-of: agent-identity-lab
spec:
  restartPolicy: Never
  containers:
    - name: root
      image: registry.access.redhat.com/ubi9/ubi-micro:latest
      command: ["sleep", "30"]
      securityContext:
        runAsUser: 0
        runAsNonRoot: false
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
EOF
DENIED=0
for _ in $(seq 1 20); do
  ERR="$(mktemp)"
  if ! oc apply -f "$ROOT_POD" >"$ERR" 2>&1; then
    if grep -Eqi 'runAsNonRoot|denied|gatekeeper' "$ERR"; then
      DENIED=1
      rm -f "$ERR"
      break
    fi
  else
    oc delete pod gatekeeper-root-denied -n agent-governance --ignore-not-found --wait=false >/dev/null
  fi
  rm -f "$ERR"
  sleep 3
done
rm -f "$ROOT_POD"
if [[ "$DENIED" != "1" ]]; then
  echo "ERROR: Gatekeeper did not deny a root pod in agent-governance."
  exit 1
fi
echo "   Root pod denied in agent-governance."

PROBE="$(mktemp)"
cat > "$PROBE" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: maas-admission-probe
  namespace: models-as-a-service
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-micro:latest
      command: ["sleep", "1"]
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
EOF
if ! oc apply --dry-run=server -f "$PROBE" >/dev/null; then
  echo "ERROR: server dry-run in models-as-a-service was rejected."
  rm -f "$PROBE"
  exit 1
fi
rm -f "$PROBE"
echo "   models-as-a-service dry-run still accepted."

assert_maas
echo ""
echo "Agent identity lab is installed."
echo "Presenter page: https://agent-console.${CLUSTER_DOMAIN}"
echo "Run: bash setup/11-verify-agent-identity.sh"
echo "Undo: bash setup/11-uninstall-agent-identity.sh"
echo "========================================="
