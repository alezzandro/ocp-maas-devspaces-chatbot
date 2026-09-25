#!/bin/bash
# Remove only the agent-identity lab. Does not run setup/uninstall-demo.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Uninstall agent identity lab"
echo "========================================="

oc delete -f "${SCRIPT_DIR}/../manifests/agent-governance/gatekeeper/constraint.yaml" --ignore-not-found
oc delete -f "${SCRIPT_DIR}/../manifests/agent-governance/gatekeeper/constraint-template.yaml" --ignore-not-found
oc delete gatekeeper gatekeeper --ignore-not-found
oc delete subscription gatekeeper-operator-product -n openshift-operators --ignore-not-found
oc delete csv -n openshift-operators -l operators.coreos.com/gatekeeper-operator-product.openshift-operators= --ignore-not-found || true

oc delete authpolicy agent-mcp-auth -n openshift-ingress --ignore-not-found
oc delete httproute agent-mcp -n agent-governance --ignore-not-found
oc delete envoyfilter agent-mcp-gateway-authn-ssl -n openshift-ingress --ignore-not-found
oc delete gateway agent-mcp-gateway -n openshift-ingress --ignore-not-found

oc delete clusterspiffeid agent-governance-workloads --ignore-not-found

oc delete spireoidcdiscoveryprovider cluster --ignore-not-found
oc delete spiffecsidriver cluster --ignore-not-found
oc delete spireagent cluster --ignore-not-found
oc delete spireserver cluster --ignore-not-found
oc delete zerotrustworkloadidentitymanager cluster --ignore-not-found

oc delete subscription openshift-zero-trust-workload-identity-manager \
  -n zero-trust-workload-identity-manager --ignore-not-found
oc delete namespace zero-trust-workload-identity-manager --ignore-not-found --wait=false
oc delete namespace agent-governance --ignore-not-found --wait=false

echo "Waiting for namespaces to finish deleting..."
for _ in $(seq 1 60); do
  if ! oc get namespace agent-governance >/dev/null 2>&1 \
    && ! oc get namespace zero-trust-workload-identity-manager >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

ENF="$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo missing)"
PROG="$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo missing)"
URL="$(oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications \
  -o jsonpath='{.data.OpenShift-MCP-Server}' 2>/dev/null || echo missing)"
echo "maas-gateway-auth Enforced=${ENF}"
echo "maas-default-gateway Programmed=${PROG}"
if [[ "$URL" == *"openshift-mcp-server.models-as-a-service.svc.cluster.local"* ]]; then
  echo "playground MCP URL still the ClusterIP"
else
  echo "WARNING: playground MCP URL changed"
  echo "$URL"
  exit 1
fi
if [[ "$ENF" != "True" || "$PROG" != "True" ]]; then
  echo "WARNING: MaaS gateway is not healthy after uninstall. Do not patch it from this script."
  exit 1
fi
echo "========================================="
