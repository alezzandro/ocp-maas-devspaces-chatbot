# Prerequisites

## Cluster Requirements

- **OpenShift 4.22+** on AWS (IPI installation)
- **cluster-admin** access via `oc` CLI
- **Python 3.9+** (for the GPU provisioner tool)
- Standard CLI tools: `curl`, `openssl`, `git`, `base64`

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
| `github.com` | GPU provisioner clone, devfile workspace |
| `quay.io` | Universal developer image for Dev Spaces |

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

## Cluster Sizing

The demo adds one GPU worker node. Total cluster resources:

| Resource | Purpose | Minimum |
|---|---|---|
| Control plane | 3x m6i.xlarge (default IPI) | Standard |
| Compute workers | 2x m6i.xlarge (default IPI) | Standard |
| GPU worker | 1x g6.2xlarge (L4 GPU, 22GB VRAM) | Added by script |

Additional storage:
- PostgreSQL PVC: 10Gi
- MySQL PVC: 10Gi
- Open WebUI PVC: 5Gi
- Dev Spaces user PVC: 10Gi (per-user, auto-provisioned)
