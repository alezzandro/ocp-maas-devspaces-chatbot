#!/bin/bash
# Clone a demo git repo and run its setup script. Always keep the container
# alive so an operator can attach (oc rsh, pod Terminal, Web Terminal).
set -uo pipefail

WORK="${WORK_DIR:-/work}"
STATUS_FILE="${WORK}/status"
EXIT_FILE="${WORK}/exit_code"
LOG="${WORK}/setup.log"
SRC="${WORK}/src"

DEMO_GIT_REPO="${DEMO_GIT_REPO:-}"
DEMO_GIT_REF="${DEMO_GIT_REF:-master}"
DEMO_SETUP_SCRIPT="${DEMO_SETUP_SCRIPT:-setup/full-setup.sh}"
DEMO_SETUP_ARGS="${DEMO_SETUP_ARGS:-}"
DEMO_RETRY="${DEMO_RETRY:-false}"

mkdir -p "${WORK}"
touch "${LOG}"
git config --global --add safe.directory "${SRC}" 2>/dev/null || true

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG}"
}

keep_alive() {
  echo ""
  log "Container staying online for troubleshooting (sleep infinity)."
  log "Status: $(cat "${STATUS_FILE}" 2>/dev/null || echo unknown)  exit=$(cat "${EXIT_FILE}" 2>/dev/null || echo n/a)"
  log "Logs:   ${LOG}"
  log "Source: ${SRC}"
  log ""
  log "Attach:"
  log "  oc rsh -n rh-demo-bootstrapper deploy/demo-bootstrapper"
  log "  OpenShift console → Workloads → Pods → Terminal"
  log "  Web Terminal (console masthead) then: oc rsh -n rh-demo-bootstrapper deploy/demo-bootstrapper"
  exec sleep infinity
}

clone_url() {
  local url="${DEMO_GIT_REPO}"
  if [[ -n "${GIT_TOKEN:-}" && "${url}" == https://* ]]; then
    url="https://x-access-token:${GIT_TOKEN}@${url#https://}"
  fi
  echo "${url}"
}

if [[ -z "${DEMO_GIT_REPO}" ]]; then
  log "ERROR: DEMO_GIT_REPO is not set."
  echo "failed" > "${STATUS_FILE}"
  echo "1" > "${EXIT_FILE}"
  keep_alive
fi

prev="$(cat "${STATUS_FILE}" 2>/dev/null || true)"
if [[ "${prev}" == "succeeded" && "${DEMO_RETRY}" != "true" ]]; then
  log "Previous run succeeded; skipping setup (set DEMO_RETRY=true to rerun)."
  keep_alive
fi
if [[ "${prev}" == "failed" && "${DEMO_RETRY}" != "true" ]]; then
  log "Previous run failed; skipping setup (set DEMO_RETRY=true to rerun)."
  keep_alive
fi

echo "running" > "${STATUS_FILE}"
log "Starting demo bootstrap"
log "  repo=${DEMO_GIT_REPO}"
log "  ref=${DEMO_GIT_REF}"
log "  script=${DEMO_SETUP_SCRIPT} ${DEMO_SETUP_ARGS}"
log "  oc whoami=$(oc whoami 2>/dev/null || echo unknown)"

# Best-effort: Web Terminal Operator should already be subscribed via kickoff YAML.
if oc get csv -n openshift-operators 2>/dev/null | grep -q web-terminal; then
  log "Waiting for Web Terminal Operator CSV (up to 5 minutes)..."
  oc wait csv -n openshift-operators \
    -l operators.coreos.com/web-terminal.openshift-operators="" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s 2>/dev/null \
    && log "Web Terminal Operator: Succeeded" \
    || log "WARNING: Web Terminal CSV not Succeeded yet (console masthead may need a refresh)."
else
  log "WARNING: web-terminal CSV not found yet; install Subscription is applied with this bootstrapper."
fi

log "Cloning / updating source into ${SRC}..."
URL="$(clone_url)"
set +e
if [[ -d "${SRC}/.git" ]]; then
  git -C "${SRC}" remote set-url origin "${URL}" 2>/dev/null
  git -C "${SRC}" fetch --all --tags 2>&1 | tee -a "${LOG}"
  git -C "${SRC}" checkout "${DEMO_GIT_REF}" 2>&1 | tee -a "${LOG}"
  git -C "${SRC}" pull --ff-only 2>&1 | tee -a "${LOG}"
else
  rm -rf "${SRC}"
  git clone --depth 1 --branch "${DEMO_GIT_REF}" "${URL}" "${SRC}" 2>&1 | tee -a "${LOG}"
  clone_rc=${PIPESTATUS[0]}
  if [[ "${clone_rc}" -ne 0 ]]; then
    log "Shallow clone failed; retrying full clone..."
    rm -rf "${SRC}"
    git clone "${URL}" "${SRC}" 2>&1 | tee -a "${LOG}"
    git -C "${SRC}" checkout "${DEMO_GIT_REF}" 2>&1 | tee -a "${LOG}"
  fi
fi
git -C "${SRC}" remote set-url origin "${DEMO_GIT_REPO}" 2>/dev/null
set -u

if [[ ! -f "${SRC}/${DEMO_SETUP_SCRIPT}" ]]; then
  log "ERROR: ${DEMO_SETUP_SCRIPT} not found in cloned repo."
  echo "failed" > "${STATUS_FILE}"
  echo "1" > "${EXIT_FILE}"
  keep_alive
fi

chmod +x "${SRC}/${DEMO_SETUP_SCRIPT}" 2>/dev/null || true
cd "${SRC}"
export HOME="${WORK}"
# shellcheck disable=SC2086
set +e
bash "${DEMO_SETUP_SCRIPT}" ${DEMO_SETUP_ARGS} 2>&1 | tee -a "${LOG}"
rc=${PIPESTATUS[0]}
set -u

echo "${rc}" > "${EXIT_FILE}"
if [[ "${rc}" -eq 0 ]]; then
  echo "succeeded" > "${STATUS_FILE}"
  log "Setup finished successfully (exit ${rc})."
else
  echo "failed" > "${STATUS_FILE}"
  log "Setup FAILED (exit ${rc}). Container will stay Running for troubleshooting."
fi

keep_alive
