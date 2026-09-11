# In-cluster demo bootstrapper

Run this demo’s `setup/full-setup.sh` **on the OpenShift cluster** so the laptop can disconnect. The bootstrapper pod **stays Running** after success or failure so you can attach later.

Image: [`quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1`](https://quay.io/repository/aarrichi/rh-demo-bootstrapper) (UBI9; sources in [`apps/demo-bootstrapper/`](../apps/demo-bootstrapper/)).

This demo targets **OpenShift AI 3.5** (`stable-3.x`) with Qwen3-8B-FP8 (1 GPU). After clone, setup discovers KServe presets and MaaS CRs on the cluster. See [architecture.md](architecture.md#validated-on-openshift-ai-350).

Default `DEMO_GIT_REF` is **`rhoai-3.5`** (the 3.5 backport branch). After that branch is merged, set `DEMO_GIT_REF=main`. The branch must be pushed before in-cluster clone can succeed.

## Prerequisites

1. OpenShift **4.22+** with **cluster-admin** (enough to apply YAML once).
2. **Web Terminal Operator** from the Red Hat catalog (`redhat-operators`, channel `fast`, namespace `openshift-operators`). Applying the bootstrapper kustomization (or `kickoff.yaml`) installs this Subscription. Refresh the console until the command-line icon appears in the masthead. Docs: [OpenShift Web terminal](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/web_console/web-terminal).
3. Cluster can pull `quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1`. If the Quay repository is **private**, create an image pull secret and attach it to ServiceAccount `demo-runner`.
4. Egress to `github.com`, `quay.io`, `registry.redhat.io`, `registry.access.redhat.com`, and `ghcr.io`.

## Kickoff (then close the laptop)

### CLI

```bash
# Optional: your OpenShift user for MaaS groups / dashboard login
export DEMO_ADMIN_USER="$(oc whoami)"

oc apply -k manifests/bootstrapper/

# Optional: set the human admin after apply
oc set env deploy/demo-bootstrapper -n rh-demo-bootstrapper \
  DEMO_ADMIN_USER="${DEMO_ADMIN_USER}"

# Follow logs until you are satisfied it started, then disconnect
oc logs -f -n rh-demo-bootstrapper deploy/demo-bootstrapper
```

Default `DEMO_GIT_REPO` in [`deployment.yaml`](../manifests/bootstrapper/deployment.yaml) is this repository. For a fork:

```bash
oc set env deploy/demo-bootstrapper -n rh-demo-bootstrapper \
  DEMO_GIT_REPO=https://github.com/<org>/<demo>.git \
  DEMO_GIT_REF=rhoai-3.5 \
  DEMO_SETUP_SCRIPT=setup/full-setup.sh
```

### OpenShift console (no ongoing CLI)

1. Administrator → **Import YAML**
2. Paste [`manifests/bootstrapper/kickoff.yaml`](../manifests/bootstrapper/kickoff.yaml)
3. Replace `DEMO_GIT_REPO_PLACEHOLDER` with the git HTTPS URL (for this demo: `https://github.com/alezzandro/ocp-maas-devspaces-chatbot.git`)
4. Optionally set `DEMO_ADMIN_USER` to your kubeadmin / SSO username
5. Create. Close the laptop.

Private git: create Secret `demo-git-token` in `rh-demo-bootstrapper` with key `GIT_TOKEN` before the pod starts.

## Environment contract

| Variable | Default | Purpose |
|---|---|---|
| `DEMO_GIT_REPO` | this repo (Deployment) / placeholder (kickoff) | HTTPS git URL |
| `DEMO_GIT_REF` | `rhoai-3.5` | Branch or tag |
| `DEMO_SETUP_SCRIPT` | `setup/full-setup.sh` | Path inside the clone |
| `DEMO_SETUP_ARGS` | empty | Extra args (start phase, e.g. `6`) |
| `DEMO_RETRY` | `false` | Set `true` to rerun after a recorded success/failure |
| `DEMO_ADMIN_USER` | empty | Extra OpenShift user added to demo groups |
| `GIT_TOKEN` | optional Secret | Private GitHub token |

The cloned repo must provide an idempotent `setup/full-setup.sh` that uses in-cluster `oc` (no `oc login`).

Status is stored on the PVC: `/work/status` (`running` / `succeeded` / `failed`), `/work/setup.log`, `/work/src`.

## Troubleshoot (pod never exits)

```bash
oc logs -n rh-demo-bootstrapper deploy/demo-bootstrapper
oc rsh -n rh-demo-bootstrapper deploy/demo-bootstrapper
# inside: cat /work/status /work/exit_code; tail -100 /work/setup.log
```

- **Pod Terminal:** Workloads → Pods → `demo-bootstrapper-*` → Terminal
- **Web Terminal:** masthead icon, then `oc rsh -n rh-demo-bootstrapper deploy/demo-bootstrapper`

Rerun after a failure:

```bash
oc set env deploy/demo-bootstrapper -n rh-demo-bootstrapper DEMO_RETRY=true
# Recreate so the entrypoint runs again (PVC keeps /work)
oc delete pod -n rh-demo-bootstrapper -l app=demo-bootstrapper
```

When setup has **already succeeded**, turn retry off. Otherwise a later pod restart (node drain, image pull, `oc set env`) re-runs the start phase and can overwrite `/work/status` with `failed` while the demo itself is fine:

```bash
oc exec -n rh-demo-bootstrapper deploy/demo-bootstrapper -- \
  sh -c 'echo succeeded > /work/status; echo 0 > /work/exit_code'
oc set env deploy/demo-bootstrapper -n rh-demo-bootstrapper \
  DEMO_RETRY=false DEMO_SETUP_ARGS-
```

Do **not** scale the Deployment to 0 while setup is running.

`oc logs` only shows PID 1 (the entrypoint). After a failure the container `sleep infinity`; an `oc exec` resume does **not** appear in `oc logs`. To rerun setup in the log stream, set `DEMO_RETRY=true` (and optionally `DEMO_SETUP_ARGS=<phase>`) then delete the pod.

Git may report `detected dubious ownership` on `/work/src` (PVC vs container UID). The entrypoint runs `git config --global --add safe.directory /work/src` (`HOME=/work` on the PVC). If you attach to an older image without that line, run the same `git config` once in the pod.

`setup/health-check.sh --fix` clears a leftover `DEMO_RETRY=true` after serving is healthy so an overnight restart does not re-run a phase.

## Rebuild and push the image

```bash
podman build -t quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1 \
  -f apps/demo-bootstrapper/Containerfile apps/demo-bootstrapper
podman tag quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1 \
  quay.io/aarrichi/rh-demo-bootstrapper:latest
podman push quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1
podman push quay.io/aarrichi/rh-demo-bootstrapper:latest
```

Bump the tag in `deployment.yaml` / `kickoff.yaml` when you publish a breaking image change.

## Security note

ServiceAccount `demo-runner` is bound to **cluster-admin** so it can install operators and scale GPU MachineSets. That is appropriate for a short-lived booth cluster. Remove the ClusterRoleBinding (or the namespace) when the demo is torn down; `setup/uninstall-demo.sh` deletes the bootstrapper namespace and binding but **leaves** the Web Terminal Operator installed.
