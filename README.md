# OpenShift AI MaaS + Dev Spaces + Chatbot Demo

Enterprise AI governance demo showcasing Red Hat OpenShift AI 3.5 Models-as-a-Service (MaaS) with three consumers of the same Qwen3-8B-FP8-dynamic model:

1. **OpenShift Dev Spaces** -- AI-assisted Ansible playbook writing via the Continue extension
2. **Open WebUI** -- Chatbot interface for operations teams
3. **Gen AI Playground** -- OpenShift AI Gen AI studio (OGX; trusted in-cluster path, bypasses MaaS)

Dev Spaces and Open WebUI use **independent subscriptions and API keys** for separate token consumption tracking. Playground does not go through MaaS and does not increment Observability → Usage.

## What This Demo Shows

| Feature | Product | Description |
|---|---|---|
| Model Catalog | OpenShift AI 3.5 | Curated library of Red Hat AI validated models with performance benchmarks |
| Model Registry | OpenShift AI 3.5 | Version control and governance metadata for deployed models |
| Models-as-a-Service | OpenShift AI 3.5 | Subscription-based access control, API keys, token limits, rate limiting |
| AI Coding Assistant | Dev Spaces + Continue | Cloud IDE with pre-configured LLM for Ansible development |
| Chatbot Interface | Open WebUI | Self-hosted chat UI connected to the governed model endpoint |
| Gen AI Playground | OpenShift AI 3.5 OGX | Prompt testing with Granite embeddings + optional OpenShift MCP |
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

**In-cluster (close the laptop after apply):** clone this repo on the cluster and run setup in a keep-alive pod. See [docs/bootstrapper.md](docs/bootstrapper.md).

```bash
oc apply -k manifests/bootstrapper/
oc logs -f -n rh-demo-bootstrapper deploy/demo-bootstrapper
```

Or **Import YAML** [`manifests/bootstrapper/kickoff.yaml`](manifests/bootstrapper/kickoff.yaml) in the OpenShift console (replace `DEMO_GIT_REPO_PLACEHOLDER`). Default branch is `rhoai-3.5` until that work is merged to `main`.

## Prerequisites

- OpenShift 4.22+ on AWS with cluster-admin access
- OpenShift AI 3.5 (channel `stable-3.x`)
- `oc` CLI authenticated **or** in-cluster bootstrapper (Web Terminal Operator from the Red Hat catalog)
- Python 3.9+ (for GPU provisioner; included in the bootstrapper image)
- `curl`, `jq`, `openssl` on PATH (included in the bootstrapper image)

See [docs/prerequisites.md](docs/prerequisites.md). In-cluster kickoff: [docs/bootstrapper.md](docs/bootstrapper.md).

## Architecture

![Architecture Diagram](images/Gemini_Generated_Architecture.png)

See [docs/architecture.md](docs/architecture.md) for the 3.5 request path, OGX Playground, in-cluster bootstrapper, and validated operational notes (AuthPolicy, Usage ref name, Continue ConfigMaps, Open WebUI legacy function calling).

## Demo Overview

![Demo Infographic](images/Gemini_Generated_Infographics.png)

## Setup Phases

| Phase | Script | Duration | Description |
|---|---|---|---|
| 0 | `00-gpu-provisioner.sh` | 5-10 min | Add GPU worker node (g6.2xlarge) |
| 1 | `01-install-operators.sh` | 5-10 min | All operator subscriptions |
| 2 | `02-platform-config.sh` | 5-10 min | Kuadrant, Gateway, Monitoring |
| 3 | `03-maas-platform.sh` | 5 min | PostgreSQL, DB secret, TLS |
| 4 | `04-rhoai-config.sh` | 5-10 min | DSC (OGX), 3.5 dashboard flags, HardwareProfile |
| 5 | `05-model-registry.sh` | 5 min | MySQL, ModelRegistry, register model |
| 6 | `06-deploy-model.sh` | 5-15 min | LLMInferenceService, MaaSModelRef, OGX Playground |
| 7 | `07-verify-maas.sh` | 2 min | End-to-end verification |
| 8 | `08-setup-subscriptions.sh` | 2 min | Two subscriptions + API keys |
| 9 | `09-deploy-devspaces.sh` | 5-10 min | CheCluster + Continue ConfigMaps |
| 10 | `10-deploy-chatbot.sh` | 2-5 min | Open WebUI (legacy function calling) |

Laptop-free: apply `manifests/bootstrapper/` instead of running phases on a laptop. The keep-alive pod clones this git repo and executes `setup/full-setup.sh` (phases 0–10). See [docs/bootstrapper.md](docs/bootstrapper.md).

## Operational Scripts

```bash
# Check all components are healthy
bash setup/health-check.sh

# Attempt automatic recovery (WASM 503, AuthPolicies, leftover pods, OGX, Continue, WebUI, bootstrapper retry)
bash setup/health-check.sh --fix

# Display all URLs and credentials
bash setup/show-credentials.sh

# Reset demo state between runs
bash setup/reset-demo.sh

# Full teardown (also removes rh-demo-bootstrapper; keeps Web Terminal Operator)
bash setup/uninstall-demo.sh
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/prerequisites.md](docs/prerequisites.md) | Cluster, AWS, network, storage, laptop vs in-cluster |
| [docs/architecture.md](docs/architecture.md) | Request path, MaaS identity, OGX Playground, 3.5 notes |
| [docs/bootstrapper.md](docs/bootstrapper.md) | In-cluster kickoff, Web Terminal, `DEMO_RETRY`, image rebuild |
| [docs/demo-guide.md](docs/demo-guide.md) | Presenter script, talking points, overnight recovery |

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
- Serving identity: `LLMInferenceService` / `MaaSModelRef` **`qwen3-8b-fp8`** (must match the MaaS URL path)

## References

- [OpenShift AI 3.5](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/)
- [Govern LLM access with Models-as-a-Service (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/)
- [Working with OGX (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/)
- [Experimenting with models in the Gen AI Playground (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/experimenting_with_models_in_the_gen_ai_playground/index)
- [OCP GPU Provisioner](https://github.com/alezzandro/ocp-gpu-provisioner-aws)
- [AI Code Assistants with Dev Spaces](https://developers.redhat.com/articles/2026/01/28/guide-ai-code-assistants-red-hat-openshift-dev-spaces)
- [In-cluster demo bootstrapper](docs/bootstrapper.md) — UBI9 image `apps/demo-bootstrapper/Containerfile`, `quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1`

## License

Apache-2.0
