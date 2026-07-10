# Architecture

## Overview

This demo deploys a governed AI model serving platform on OpenShift using Red Hat OpenShift AI 3.4 Models-as-a-Service (MaaS).

```
┌──────────────────────────────────────────────────────────────────────┐
│                      OpenShift 4.22 on AWS                           │
│                                                                      │
│  ┌────────────────────────┐    ┌──────────────────────────────────┐ │
│  │  Model Lifecycle        │    │  MaaS Platform                    │ │
│  │                        │    │                                  │ │
│  │  Model Catalog ────►   │    │  Istio Gateway + Kuadrant        │ │
│  │  Model Registry ───►   │    │  Authorino (AuthN/AuthZ)         │ │
│  │  InferenceService      │◄───│  PostgreSQL (API key DB)         │ │
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
└──────────────────────────────────────────────────────────────────────┘
```

## Component Map

| Component | Purpose | Namespace |
|---|---|---|
| RHOAI Operator | Platform orchestration, reconciles DSC | `redhat-ods-operator` |
| DataScienceCluster | Enables KServe, MaaS, ModelRegistry | cluster-scoped |
| PostgreSQL | MaaS API key lifecycle and token tracking | `redhat-ods-applications` |
| MySQL | Model Registry metadata store (MLMD) | `rhoai-model-registries` |
| Istio Gateway | MaaS traffic routing + TLS termination | `openshift-ingress` |
| Kuadrant + Authorino | Authentication, authorization, rate limiting | `kuadrant-system` |
| vLLM ServingRuntime | Model inference engine (CUDA) | `llm` |
| InferenceService | Model deployment (Qwen3-8B-FP8-dynamic) | `llm` |
| MaaSModelRef | Registers model with MaaS control plane | `llm` |
| MaaSSubscription (x2) | Independent token quotas per consumer group | `models-as-a-service` |
| MaaSAuthPolicy (x2) | Grants model access to specific groups | `models-as-a-service` |
| CheCluster | Dev Spaces platform for cloud IDEs | `openshift-devspaces` |
| Open WebUI | Self-hosted chatbot interface | `open-webui` |

## Request Flow

```
User (Dev Spaces / Open WebUI)
  │
  │ POST /llm/qwen3-8b/v1/chat/completions
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
│  vLLM InferenceService       │  8. Process inference on L4 GPU
│  (qwen3-8b-fp8)             │  9. Return completion response
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│  MaaS Controller             │  10. Record token consumption
│  (post-response)             │      against subscription quota
└─────────────────────────────┘
```

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
                    │  InferenceService │
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
│  Both access the SAME model: qwen3-8b-fp8 (llm namespace)      │
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

## Security Model

- **TLS everywhere**: Gateway terminates external TLS; internal services use mTLS via service mesh
- **Per-user API keys**: No shared credentials; keys are bound to subscriptions at creation
- **RBAC-based access**: MaaSAuthPolicy uses OpenShift groups for authorization
- **Rate limiting**: Prevents resource exhaustion by any single consumer
- **Network isolation**: Model namespace has gateway-access label for controlled ingress
- **SCC enforcement**: Open WebUI uses `anyuid` SCC via dedicated ServiceAccount (not cluster-wide)
