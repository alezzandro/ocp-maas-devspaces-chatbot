# OpenShift AI MaaS + Dev Spaces + Chatbot Demo

Enterprise AI governance demo showcasing Red Hat OpenShift AI 3.4 Models-as-a-Service (MaaS) with two independent consumers:

1. **OpenShift Dev Spaces** -- AI-assisted Ansible playbook writing via the Continue extension
2. **Open WebUI** -- Chatbot interface for operations teams

Both consumers use the same LLM (Qwen3-8B-FP8-dynamic) served through MaaS, but with **independent subscriptions and API keys** for separate token consumption tracking.

## What This Demo Shows

| Feature | Product | Description |
|---|---|---|
| Model Catalog | OpenShift AI 3.4 | Curated library of Red Hat AI validated models with performance benchmarks |
| Model Registry | OpenShift AI 3.4 | Version control and governance metadata for deployed models |
| Models-as-a-Service | OpenShift AI 3.4 | Subscription-based access control, API keys, token limits, rate limiting |
| AI Coding Assistant | Dev Spaces + Continue | Cloud IDE with pre-configured LLM for Ansible development |
| Chatbot Interface | Open WebUI | Self-hosted chat UI connected to the governed model endpoint |
| GPU Model Serving | KServe + vLLM | Production-grade inference on NVIDIA L4 GPU |

## Quick Start

```bash
# Clone the repository
git clone https://github.com/alezzandro/ocp-maas-devspaces-chatbot.git
cd ocp-maas-devspaces-chatbot

# Ensure you're logged in as cluster-admin
oc login --server=https://<api-server>:6443

# Run full setup (30-45 minutes)
bash setup/full-setup.sh

# Or resume from a specific phase after a failure
bash setup/full-setup.sh 4
```

## Prerequisites

- OpenShift 4.22+ on AWS with cluster-admin access
- `oc` CLI authenticated
- Python 3.9+ (for GPU provisioner)
- `curl`, `jq`, `openssl` on PATH

See [docs/prerequisites.md](docs/prerequisites.md) for full details.

## Architecture

![Architecture Diagram](images/Gemini_Generated_Architecture.png)

## Demo Overview

![Demo Infographic](images/Gemini_Generated_Infographics.png)

## Setup Phases

| Phase | Script | Duration | Description |
|---|---|---|---|
| 0 | `00-gpu-provisioner.sh` | 5-10 min | Add GPU worker node (g6.2xlarge) |
| 1 | `01-install-operators.sh` | 5-10 min | All operator subscriptions |
| 2 | `02-platform-config.sh` | 5-10 min | Kuadrant, Gateway, Monitoring |
| 3 | `03-maas-platform.sh` | 5 min | PostgreSQL, DB secret, TLS |
| 4 | `04-rhoai-config.sh` | 5-10 min | DSC, Dashboard, HardwareProfile |
| 5 | `05-model-registry.sh` | 5 min | MySQL, ModelRegistry, register model |
| 6 | `06-deploy-model.sh` | 5-15 min | ServingRuntime, InferenceService, MaaS |
| 7 | `07-verify-maas.sh` | 2 min | End-to-end verification |
| 8 | `08-setup-subscriptions.sh` | 2 min | Two subscriptions + API keys |
| 9 | `09-deploy-devspaces.sh` | 5-10 min | CheCluster + workspace config |
| 10 | `10-deploy-chatbot.sh` | 2-5 min | Open WebUI deployment |

## Operational Scripts

```bash
# Check all components are healthy
bash setup/health-check.sh

# Display all URLs and credentials
bash setup/show-credentials.sh

# Reset demo state between runs
bash setup/reset-demo.sh

# Full teardown
bash setup/uninstall-demo.sh
```

## Demo Delivery

See [docs/demo-guide.md](docs/demo-guide.md) for the full presenter script with:
- Exact UI navigation steps
- Talking points per screen
- Live interaction prompts
- Competitive differentiators
- Objection handling

## Model

**RedHatAI/Qwen3-8B-FP8-dynamic** -- Red Hat AI validated (September 2025)
- 8B parameters, FP8 dynamic quantization
- OCI ModelCar: `registry.redhat.io/rhelai1/modelcar-qwen3-8b-fp8-dynamic:1.5`
- Runtime: vLLM CUDA on NVIDIA L4 (22GB VRAM)
- Context: 16k tokens, ~8-9 GB VRAM for weights

## References

- [RHOAI 3.4 MaaS Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)
- [RHOAI MaaS Guide](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/index.html)
- [OCP GPU Provisioner](https://github.com/alezzandro/ocp-gpu-provisioner-aws)
- [AI Code Assistants with Dev Spaces](https://developers.redhat.com/articles/2026/01/28/guide-ai-code-assistants-red-hat-openshift-dev-spaces)
- [Open WebUI on OpenShift](https://www.stephan.michard.io/2026/bringing-open-webui-to-openshift/)

## License

Apache-2.0
