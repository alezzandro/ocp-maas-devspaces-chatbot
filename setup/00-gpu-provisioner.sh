#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GPU_PROVISIONER_DIR="${REPO_ROOT}/ocp-gpu-provisioner-aws"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 0: GPU Provisioner"
echo "========================================="

echo "1. Cloning ocp-gpu-provisioner-aws..."
if [[ -d "$GPU_PROVISIONER_DIR" ]]; then
  echo "   Already cloned, pulling latest..."
  git -C "$GPU_PROVISIONER_DIR" pull --quiet
else
  git clone https://github.com/alezzandro/ocp-gpu-provisioner-aws.git "$GPU_PROVISIONER_DIR"
fi

echo "2. Setting up Python virtual environment..."
cd "$GPU_PROVISIONER_DIR"
if [[ ! -d ".venv" ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -e . --quiet

echo "3. Running GPU provisioner (g6.2xlarge, 1 replica)..."
ocp-gpu-provisioner --instance-type g6.2xlarge --replicas 1

echo "   Scaling down extra GPU MachineSets (only need 1 GPU node)..."
GPU_MACHINESETS=$(oc get machinesets -n openshift-machine-api --no-headers -o custom-columns='NAME:.metadata.name' | grep gpu || true)
FIRST_GPU_MS=""
for ms in $GPU_MACHINESETS; do
  if [[ -z "$FIRST_GPU_MS" ]]; then
    FIRST_GPU_MS="$ms"
  else
    oc scale machineset "$ms" -n openshift-machine-api --replicas=0 2>/dev/null || true
  fi
done
echo "   Keeping only: ${FIRST_GPU_MS}"

echo "4. Waiting for GPU MachineSet to scale up..."
echo "   This may take 5-10 minutes for the AWS instance to launch..."
TIMEOUT=600
INTERVAL=30
ELAPSED=0
while true; do
  GPU_NODES=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | grep -c " Ready" || true)
  if [[ "$GPU_NODES" -ge 1 ]]; then
    echo "   GPU node is Ready!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timeout waiting for GPU node to become Ready"
    exit 1
  fi
  echo "   Waiting... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "5. Verifying nvidia.com/gpu resource..."
GPU_CAPACITY=$(oc get nodes -l node-role.kubernetes.io/worker-gpu -o jsonpath='{.items[0].status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [[ "$GPU_CAPACITY" -ge 1 ]]; then
  echo "   GPU resource available: nvidia.com/gpu=${GPU_CAPACITY}"
else
  echo "   WARNING: nvidia.com/gpu not yet reported. GPU operators may still be installing drivers."
  echo "   The GPU resource will appear after NFD and NVIDIA operators complete (Phase 1)."
fi

deactivate
cd "$REPO_ROOT"

echo ""
echo "Phase 0 complete: GPU worker node provisioned."
echo "========================================="
