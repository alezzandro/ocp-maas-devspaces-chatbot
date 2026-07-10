#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 4: RHOAI Configuration"
echo "========================================="

echo "1. Applying DataScienceCluster..."
oc apply -f "${MANIFESTS_DIR}/rhoai-config/datasciencecluster.yaml"

echo "2. Applying DSCInitialization..."
oc apply -f "${MANIFESTS_DIR}/rhoai-config/dscinitializaton.yaml"

echo "3. Enabling Model Catalog and MaaS in dashboard..."
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{
    "spec": {
      "dashboardConfig": {
        "disableModelCatalog": false,
        "modelAsService": true,
        "genAiStudio": true,
        "maasAuthPolicies": true,
        "observabilityDashboard": true
      }
    }
  }' 2>/dev/null || echo "   Dashboard config not yet available, will be patched on next reconcile."

echo "4. Creating HardwareProfile for L4 GPU..."
oc apply -f "${MANIFESTS_DIR}/rhoai-config/hardware-profile.yaml"

echo "5. Waiting for ModelsAsServiceReady condition..."
TIMEOUT=300
INTERVAL=15
ELAPSED=0
while true; do
  STATUS=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$STATUS" == "True" ]]; then
    echo "   MaaS is ready!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: MaaS not yet ready after ${TIMEOUT}s. Check DSC status."
    break
  fi
  echo "   ModelsAsServiceReady: ${STATUS} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
echo "Phase 4 complete: RHOAI configured with MaaS, Model Registry, and Model Catalog."
echo "========================================="
