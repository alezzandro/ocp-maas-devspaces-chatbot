# Architecture

## Overview

This demo deploys a governed AI model serving platform on OpenShift using Red Hat OpenShift AI 3.5 Models-as-a-Service (MaaS).

```
┌──────────────────────────────────────────────────────────────────────┐
│                      OpenShift 4.22 on AWS                           │
│                                                                      │
│  ┌────────────────────────┐    ┌──────────────────────────────────┐ │
│  │  Model Lifecycle        │    │  MaaS Platform                    │ │
│  │                        │    │                                  │ │
│  │  Model Catalog ────►   │    │  Istio Gateway + Kuadrant        │ │
│  │  Model Registry ───►   │    │  Authorino (AuthN/AuthZ)         │ │
│  │  LLMInferenceService   │◄───│  PostgreSQL (API key DB)         │ │
│  │  (vLLM + L4 GPU)       │    │  MaaS Controller + API           │ │
│  └────────────────────────┘    └──────────────────────────────────┘ │
│                                           ▲           ▲              │
│                                           │           │              │
│  ┌────────────────────────┐  ┌───────────────────────────┐          │
│  │  Dev Spaces             │  │  Open WebUI                │          │
│  │  Continue Extension     │  │  Chat Interface            │          │
│  │  API Key A              │  │  API Key B                 │          │
│  │  (devspaces-sub)        │  │  (chatbot-sub)             │          │
│  │  50k tokens/min         │  │  50k tokens/min            │          │
│  └────────────────────────┘  └───────────────────────────┘          │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Gen AI Playground (OGXServer + Postgres)                     │   │
│  │  HTTPS ClusterIP to vLLM — trusted path, bypasses MaaS        │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

## Component Map

| Component | Purpose | Namespace |
|---|---|---|
| OpenShift AI Operator | Platform orchestration, reconciles DSC | `redhat-ods-operator` |
| DataScienceCluster | Enables KServe, MaaS, ModelRegistry, OGX | cluster-scoped |
| PostgreSQL | MaaS API key lifecycle and token tracking | `redhat-ods-applications` |
| MySQL | Model Registry metadata store (MLMD) | `rhoai-model-registries` |
| Istio Gateway | MaaS traffic routing + TLS termination | `openshift-ingress` |
| Kuadrant + Authorino | Authentication, authorization, rate limiting | `kuadrant-system` |
| LLMInferenceService | Model deployment (Qwen3-8B-FP8-dynamic, 1 replica) | `models-as-a-service` |
| MaaSModelRef | Registers model with MaaS (`qwen3-8b-fp8`) | `models-as-a-service` |
| MaaSSubscription (x2) | Independent token quotas per consumer group | `models-as-a-service` |
| MaaSAuthPolicy (x2) | Grants model access to specific groups | `models-as-a-service` |
| OGXServer | Gen AI Playground (CPU; Granite embeddings + FAISS) | `models-as-a-service` |
| ogx-postgres | Dedicated PostgreSQL for the `rh` OGX distro | `models-as-a-service` |
| CheCluster | Dev Spaces platform for cloud IDEs | `openshift-devspaces` |
| Open WebUI | Self-hosted chatbot interface | `open-webui` |
| Demo bootstrapper | Keep-alive pod that clones git and runs `setup/full-setup.sh` | `rh-demo-bootstrapper` |
| Web Terminal Operator | Console masthead terminal for in-cluster troubleshooting | `openshift-operators` |

## Request Flow

```
User (Dev Spaces / Open WebUI)
  │
  │ POST /models-as-a-service/qwen3-8b-fp8/v1/chat/completions
  │ Header: Authorization: Bearer <api-key>
  │
  ▼
┌─────────────────────────────┐
│  Istio Gateway               │  1. TLS termination
│  (maas-default-gateway)      │  2. Route matching
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│  Kuadrant WASM Extension     │  3. Extract API key
│  + Authorino                 │  4. Validate key against PostgreSQL
└──────────────┬──────────────┘  5. Check subscription quota
               │
               ▼
┌─────────────────────────────┐
│  MaaS Controller             │  6. Token rate limit check
│                              │  7. Record request metadata
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│  vLLM LLMInferenceService    │  8. Process inference on L4 GPU
│  (qwen3-8b-fp8)              │  9. Return completion response
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│  MaaS Controller             │  10. Record token consumption
│  (post-response)             │      against subscription quota
└─────────────────────────────┘
```

Gen AI Playground does **not** take this path. OGX talks to `https://qwen3-8b-fp8-kserve-workload-svc.models-as-a-service.svc.cluster.local:8000/v1` and **does not increment Observability → Usage**.

## Model Lifecycle Flow

```
                    ┌──────────────────┐
                    │  Model Catalog    │
                    │  (Red Hat AI)     │
                    │  Discover + eval  │
                    └────────┬─────────┘
                             │ Register
                             ▼
                    ┌──────────────────┐
                    │  Model Registry   │
                    │  Version + meta   │
                    │  Audit trail      │
                    └────────┬─────────┘
                             │ Deploy
                             ▼
                    ┌──────────────────┐
                    │ LLMInferenceService│
                    │  vLLM + L4 GPU    │
                    │  OCI ModelCar     │
                    └────────┬─────────┘
                             │ Expose
                             ▼
                    ┌──────────────────┐
                    │  MaaS Gateway     │
                    │  Subscriptions    │
                    │  Rate limiting    │
                    └──────────────────┘
```

## Subscription Model

```
┌─────────────────────────────────────────────────────────────────┐
│                    MaaS Governance Layer                          │
│                                                                  │
│  ┌─────────────────────────┐  ┌─────────────────────────┐      │
│  │  devspaces-subscription  │  │  chatbot-subscription    │      │
│  │  Group: devspaces-users  │  │  Group: chatbot-users    │      │
│  │  Quota: 50k tokens/min   │  │  Quota: 50k tokens/min   │      │
│  │  Cost: engineering-tools  │  │  Cost: platform-services │      │
│  │                          │  │                          │      │
│  │  API Key A ──────────►   │  │  API Key B ──────────►   │      │
│  │  Independent tracking    │  │  Independent tracking    │      │
│  └─────────────────────────┘  └─────────────────────────┘      │
│                                                                  │
│  Both access the SAME model: qwen3-8b-fp8                        │
│  (models-as-a-service namespace; URL path must match ref name)   │
│  Token consumption tracked INDEPENDENTLY per subscription        │
└─────────────────────────────────────────────────────────────────┘
```

## Infrastructure Layer

| Resource | Type | Specs |
|---|---|---|
| GPU Worker Node | AWS g6.2xlarge | 1x NVIDIA L4 (24GB), 8 vCPU, 32GB RAM |
| Node Feature Discovery | Operator | Detects GPU hardware, labels nodes |
| NVIDIA GPU Operator | Operator | Installs drivers, device plugin, DCGM |
| ClusterPolicy | NVIDIA CR | Manages driver lifecycle on GPU nodes |
| Demo bootstrapper PVC | 10Gi RWO | `/work` clone + `setup.log` + status files |

Laptop-free install: apply [`manifests/bootstrapper/`](../manifests/bootstrapper/) (or Import YAML `kickoff.yaml`). The UBI9 image [`quay.io/aarrichi/rh-demo-bootstrapper:ubi9-1`](https://quay.io/repository/aarrichi/rh-demo-bootstrapper) clones this repo and runs `setup/full-setup.sh`, then `sleep infinity` so you can attach from the console. Kickoff, retry, and teardown: [bootstrapper.md](bootstrapper.md).

## Security Model

- **TLS everywhere**: Gateway terminates external TLS; internal services use mTLS via service mesh
- **Per-user API keys**: No shared credentials; keys are bound to subscriptions at creation
- **RBAC-based access**: MaaSAuthPolicy uses OpenShift groups for authorization
- **Rate limiting**: Prevents resource exhaustion by any single consumer
- **Network isolation**: Model namespace has gateway-access label for controlled ingress
- **SCC enforcement**: Open WebUI uses `anyuid` SCC via dedicated ServiceAccount (not cluster-wide)
- **Demo-only cluster-admin**: ServiceAccount `demo-runner` in `rh-demo-bootstrapper` is bound to `cluster-admin` so in-cluster setup can install operators and scale GPU MachineSets. `setup/uninstall-demo.sh` removes that binding and namespace; it leaves the Web Terminal Operator installed. See [bootstrapper.md](bootstrapper.md).

## Validated on OpenShift AI 3.5.0

The OpenShift AI Subscription uses channel **`stable-3.x`** with Automatic approval, so a cluster receives the latest 3.x CSV (**3.5.0** at validation time), not 3.4.x. Setup scripts discover versioned CRs at runtime.

1. **KServe preset** — NVIDIA `LLMInferenceServiceConfig` names are versioned. Phase 6 substitutes the live NVIDIA CUDA preset instead of hard-coding `v3-4-2-kserve-config-llm-template-nvidia-cuda`.
2. **MaaS vs ODH AuthPolicy** — The Gateway must be annotated `opendatahub.io/managed: "false"` so `odh-model-controller` does not install `{gateway}-authn` on the same Gateway (that would override MaaS `maas-gateway-auth`). The `LLMInferenceService` must set `security.opendatahub.io/enable-auth: "true"`. `enable-auth: "false"` makes the controller install anonymous `{llmis}-kserve-route-authn` on the HTTPRoute; Kuadrant then drops `auth.identity`, Limitador never increments, and **Observability → Usage** stays at 0. Phase 8 and `health-check.sh --fix` delete leftover route/gateway AuthPolicies. See [Govern LLM access with Models-as-a-Service (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/).
3. **MaaSModelRef name** — Must equal the first two URL path segments after the host: clients call `/models-as-a-service/qwen3-8b-fp8/`. A leftover `MaaSModelRef/qwen3-8b` makes subscription select return 403 and Usage stay empty.
4. **API keys in-cluster** — `maas-api` runs in `redhat-ai-gateway-infra` (fallback `redhat-ods-applications`). The bootstrapper ServiceAccount is not in `chatbot-users` / `devspaces-users`, so phase 8 mints keys by calling `maas-api` with `X-MaaS-Username` (`DEMO_ADMIN_USER`) and a JSON `X-MaaS-Group` header, then stores them in Secrets.
5. **Telemetry** — Patch `MaasTenantConfig/default-tenant` in `models-as-a-service` (3.5). The older `Tenant` CR is unused on this stack.
6. **Dashboard** — Do not add deprecated `spec.dashboardConfig.maasAuthPolicies`; the CRD CEL rule rejects adding that key when it was absent. Phase 4 turns on 3.5 flags (`genAiStudio`, `mcpCatalog`, `mcpRegistry`, `disableLMEval=false`, …) **without** `llmdTemplates` (this is a 1-GPU demo, not an llm-d booth).
7. **HardwareProfile** — 3.5 schema uses annotations for display name / enabled, and `spec.scheduling.type: Node` for node selectors.
8. **Model Registry** — Register models with `oc exec -c rest-container` against `http://127.0.0.1:8080`. Curling the ClusterIP from inside the same pod times out (CNI hairpin).
9. **Verify script** — Look for `maas-api` in `redhat-ai-gateway-infra` (fallback: `redhat-ods-applications`) and DSC condition `ModelsAsAServiceReady` (fallback: `ModelsAsServiceReady`).
10. **Overnight MaaS HTTP 503** — If the Connectivity Link (Kuadrant) operator and MaaS gateway pods restart together, Envoy can fail to fetch `plugin.wasm`. The WASM filter **fails closed**: every MaaS route returns empty HTTP 503 while the Gateway stays Programmed and vLLM still answers on the workload Service. Bounce the MaaS gateway pods (`setup/health-check.sh --fix`).
11. **Leftover Failed/Init vLLM pods** — After a GPU node drain, old `qwen3-8b-fp8-kserve-*` pods can stay Failed while a healthy replica serves traffic. Phase 6 and `--fix` force-delete leftovers; they never delete Running replicas.
12. **Open WebUI 0.10+ Native/Agentic tools** — Floating `open-webui:main` defaults to Native function calling and injects builtin tools such as `grep_knowledge_files`. Phase 10 sets `DEFAULT_MODEL_PARAMS={"function_calling":"legacy"}` and patches the PVC sqlite ConfigVars (env alone is ignored after first start). See [Open WebUI tools](https://docs.openwebui.com/features/extensibility/plugin/tools/).
13. **Dev Spaces Continue** — Phase 9 applies ConfigMaps `vscode-editor-configurations` and `vscode-default-extensions` into every **user** workspace namespace. Do **not** put Open VSX HTML URLs in CheCluster `defaultPlugins`. Restart the DevWorkspace after the ConfigMaps land. See [Configuring Visual Studio Code](https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/3.29/html/administration_guide/configuring-visual-studio-code).
14. **Usage dashboard** — Perses queries Limitador `authorized_hits_total` / `authorized_calls_total`. Those series exist only after TokenRateLimitPolicy sees `auth.identity`. Competing `*-kserve-route-authn` or a mismatched `MaaSModelRef` name zeros the counters. After a chat, scrape is ~30s. See [Limitador metrics](https://docs.kuadrant.io/latest/kuadrant-operator/doc/user-guides/observability/limitador-metrics/).
15. **Gen AI Playground (LlamaStack → OGX)** — OpenShift AI 3.5 replaced `LlamaStackDistribution` with `OGXServer`. The `rh` distribution requires dedicated PostgreSQL (`POSTGRES_*`). Remote vLLM must be HTTPS ClusterIP with `VLLM_TLS_VERIFY=false`. Do **not** set `spec.providers.inference.remote.vllm` on the CR (operator OCI 401 / `ConfigGenerationFailed`). Env + `overrideConfig` ConfigMap `ogx-playground-config` restores Granite embeddings + FAISS so Playground `POST /v1/vector_stores` returns HTTP 200. See [Working with OGX (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/) and [Playground (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/experimenting_with_models_in_the_gen_ai_playground/index).
16. **In-cluster bootstrapper** — `git config --global --add safe.directory /work/src` because the PVC clone is not owned by the container user. `oc logs` only follows PID 1; after a failure the entrypoint sleeps — resume with `DEMO_RETRY=true` and delete the pod (see [bootstrapper.md](bootstrapper.md)). After setup succeeds, leave `DEMO_RETRY=false` and clear `DEMO_SETUP_ARGS`. An overnight pod restart with those flags still set re-runs a phase and overwrites `/work/status` to `failed` even when serving is healthy. `health-check.sh --fix` clears leftover retry when the LLM is Ready.

## References

- [OpenShift AI 3.5](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/)
- [Customize the dashboard (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_resources/customizing-the-dashboard)
- [Govern LLM access with Models-as-a-Service (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/)
- [Working with OGX (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/)
- [Experimenting with models in the Gen AI Playground (3.5)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/experimenting_with_models_in_the_gen_ai_playground/index)
- [In-cluster demo bootstrapper](bootstrapper.md)
- [OpenShift Web terminal](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/web_console/web-terminal)
