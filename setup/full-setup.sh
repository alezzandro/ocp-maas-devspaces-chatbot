#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo "  OCP MaaS + Dev Spaces + Chatbot Demo - Full Setup"
echo "============================================================"
echo ""
echo "This will run all setup phases sequentially."
echo "Estimated time: 30-45 minutes"
echo ""

START_PHASE=${1:-0}

run_phase() {
  local phase=$1
  local script=$2
  if [[ "$phase" -ge "$START_PHASE" ]]; then
    echo ""
    bash "${SCRIPT_DIR}/${script}"
    echo ""
  else
    echo "Skipping phase ${phase} (starting from phase ${START_PHASE})"
  fi
}

run_phase 0 "00-gpu-provisioner.sh"
run_phase 1 "01-install-operators.sh"
run_phase 2 "02-platform-config.sh"
run_phase 3 "03-maas-platform.sh"
run_phase 4 "04-rhoai-config.sh"
run_phase 5 "05-model-registry.sh"
run_phase 6 "06-deploy-model.sh"
run_phase 7 "07-verify-maas.sh"
run_phase 8 "08-setup-subscriptions.sh"
run_phase 9 "09-deploy-devspaces.sh"
run_phase 10 "10-deploy-chatbot.sh"

echo ""
echo "============================================================"
echo "  Setup Complete!"
echo "============================================================"
echo ""
bash "${SCRIPT_DIR}/show-credentials.sh"
