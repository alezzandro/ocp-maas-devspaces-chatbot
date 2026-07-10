#!/bin/bash
# Verify oc is authenticated and has cluster-admin access
if ! command -v oc &>/dev/null; then
  echo "ERROR: 'oc' CLI not found. Install it from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

if ! oc auth can-i create clusterrole --all-namespaces &>/dev/null; then
  echo "ERROR: Current user does not have cluster-admin privileges."
  echo "       Logged in as: $(oc whoami)"
  exit 1
fi

export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export MAAS_URL="https://maas.${CLUSTER_DOMAIN}"

echo "Authenticated as: $(oc whoami)"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
