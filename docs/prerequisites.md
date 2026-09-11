# Prerequisites

## Cluster Requirements

- **OpenShift 4.22+** on AWS (IPI installation)
- **OpenShift AI 3.5** (operator channel `stable-3.x`)
- **cluster-admin** access via `oc` CLI (laptop) **or** apply the in-cluster bootstrapper once ([docs/bootstrapper.md](bootstrapper.md))
- **Python 3.9+** (for the GPU provisioner tool; included in the bootstrapper image)
- Standard CLI tools: `curl`, `openssl`, `git`, `base64` (included in the bootstrapper image)
- **Web Terminal Operator** (Red Hat catalog, package `web-terminal`, channel `fast` in `openshift-operators`) — required so you can troubleshoot from the console masthead without a laptop. Installed by `manifests/bootstrapper/` and by phase 1. Docs: [OpenShift Web terminal](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/web_console/web-terminal)

## AWS Requirements

- The cluster must be installed via IPI on AWS (MachineSets available in `openshift-machine-api`)
- IAM permissions to create new EC2 instances of type **g6.2xlarge**
- Sufficient EC2 quota for `g6.2xlarge` in at least one Availability Zone
- VPC and subnet configuration allowing new instances in the same VPC as the cluster

## Network Access

The cluster requires outbound access to:

| Destination | Purpose |
|---|---|
| `registry.redhat.io` | Model OCI images, operator images, vLLM runtime |
| `registry.access.redhat.com` | UBI base images, PostgreSQL, MySQL |
| `ghcr.io` | Open WebUI container image |
| `github.com` | GPU provisioner clone, Dev Spaces workspace git, bootstrapper `DEMO_GIT_REPO` |
| `quay.io` | Universal developer image for Dev Spaces; `quay.io/aarrichi/rh-demo-bootstrapper` |

## Time Estimate

| Phase | Script | Duration |
|---|---|---|
| GPU Provisioning | `00-gpu-provisioner.sh` | 5-10 min |
| Operator Installation | `01-install-operators.sh` | 5-10 min |
| Platform Configuration | `02-platform-config.sh` | 5-10 min |
| MaaS Platform | `03-maas-platform.sh` | 5 min |
| RHOAI Configuration | `04-rhoai-config.sh` | 5-10 min |
| Model Registry | `05-model-registry.sh` | 5 min |
| Model Deployment | `06-deploy-model.sh` | 5-15 min |
| Verification | `07-verify-maas.sh` | 2 min |
| Subscriptions | `08-setup-subscriptions.sh` | 2 min |
| Dev Spaces | `09-deploy-devspaces.sh` | 5-10 min |
| Chatbot | `10-deploy-chatbot.sh` | 2-5 min |
| **Total** | `full-setup.sh` | **~45-90 min** |

Laptop-free: skip the laptop CLI after a one-shot `oc apply` of [`manifests/bootstrapper/`](../manifests/bootstrapper/). The pod runs the same `full-setup.sh`. See [bootstrapper.md](bootstrapper.md).

## Pre-Flight Check

Before running setup:

```bash
# Verify oc is installed and authenticated
oc version
oc whoami

# Verify cluster-admin access
oc auth can-i create clusterrole --all-namespaces

# Verify Python 3.9+
python3 --version

# Verify the cluster is on AWS
oc get infrastructure cluster -o jsonpath='{.status.platform}'
# Should output: AWS

# Verify MachineSets exist (IPI cluster)
oc get machinesets -n openshift-machine-api
```

**In-cluster instead of a laptop:** you only need `oc` long enough to apply YAML (or Import YAML in the console). After that, follow logs from the Web Terminal:

```bash
oc apply -k manifests/bootstrapper/
oc logs -f -n rh-demo-bootstrapper deploy/demo-bootstrapper
```

Replace `DEMO_GIT_REPO_PLACEHOLDER` if you paste [`kickoff.yaml`](../manifests/bootstrapper/kickoff.yaml). Default git ref is `rhoai-3.5` until that branch is merged to `main`. Full contract: [bootstrapper.md](bootstrapper.md).

## Cluster Sizing

The demo adds one GPU worker node. Total cluster resources:

| Resource | Purpose | Minimum |
|---|---|---|
| Control plane | 3x m6i.xlarge (default IPI) | Standard |
| Compute workers | 2x m6i.xlarge (default IPI) | Standard |
| GPU worker | 1x g6.2xlarge (L4 GPU, 22GB VRAM) | Added by script |

Additional storage:
- PostgreSQL PVC (MaaS API keys): 10Gi
- MySQL PVC (Model Registry): 10Gi
- OGX PostgreSQL PVC: 5Gi
- OGXServer PVC: 20Gi
- Open WebUI PVC: 5Gi
- Dev Spaces user PVC: 10Gi (per-user, auto-provisioned)
- Bootstrapper work PVC: 10Gi

Laptop-free setup: apply [`manifests/bootstrapper/`](../manifests/bootstrapper/) (or Import YAML `kickoff.yaml`) so the cluster clones the git repo and runs `setup/full-setup.sh`. See [bootstrapper.md](bootstrapper.md).
