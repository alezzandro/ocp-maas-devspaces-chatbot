#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "  Uninstall Demo"
echo "========================================="
echo "WARNING: This will remove all demo components."
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "1. Removing chatbot..."
oc delete -k "${REPO_ROOT}/manifests/chatbot/" --ignore-not-found 2>/dev/null || true

echo "2. Removing Dev Spaces CheCluster..."
oc delete checluster devspaces -n openshift-devspaces --ignore-not-found 2>/dev/null || true

echo "3. Removing MaaS subscriptions and policies..."
oc delete -k "${REPO_ROOT}/manifests/subscriptions/" --ignore-not-found 2>/dev/null || true

echo "4. Removing model deployment..."
oc delete -k "${REPO_ROOT}/manifests/model/" --ignore-not-found 2>/dev/null || true

echo "5. Removing model registry..."
oc delete -f "${REPO_ROOT}/manifests/model-registry/mysql/mysql.yaml" --ignore-not-found 2>/dev/null || true

echo "6. Removing MaaS platform (PostgreSQL)..."
oc delete -f "${REPO_ROOT}/manifests/maas-platform/postgres/postgres.yaml" --ignore-not-found 2>/dev/null || true
oc delete secret maas-db-config maas-postgres-credentials -n redhat-ods-applications --ignore-not-found 2>/dev/null || true

echo "7. Removing DataScienceCluster..."
oc delete datasciencecluster default-dsc --ignore-not-found 2>/dev/null || true

echo "8. Removing Gateway..."
oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found 2>/dev/null || true

echo "9. Removing groups..."
oc delete group devspaces-users chatbot-users --ignore-not-found 2>/dev/null || true

echo ""
echo "Demo uninstalled. Operators are still installed."
echo "========================================="
