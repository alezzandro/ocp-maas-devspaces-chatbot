# Demo Guide: OpenShift AI Models-as-a-Service

## Executive Summary

This demo showcases Red Hat OpenShift AI 3.4 Models-as-a-Service (MaaS) as an enterprise AI governance platform. A single LLM (Qwen3-8B) is deployed from the Red Hat AI model catalog through the model registry, then exposed via MaaS with independent subscriptions for two consumers: developers using AI coding assistance in OpenShift Dev Spaces, and an operations team using a chatbot interface (Open WebUI). Each consumer has separate API keys with independent token tracking -- demonstrating enterprise-grade cost attribution and access governance.

## Architecture Overview

![Architecture Diagram](../images/Gemini_Generated_Architecture.png)

## Demo Infographic

Use this infographic as a leave-behind or pre-briefing asset for stakeholders:

![Demo Infographic](../images/Gemini_Generated_Infographics.png)

## Customer Pain Points Addressed

| Pain Point | How This Demo Addresses It |
|---|---|
| **Ungoverned AI access** | MaaS provides subscription-based access control with per-user API keys |
| **No cost visibility** | Independent token tracking per subscription enables showback/chargeback |
| **Developer friction** | Dev Spaces provides zero-setup cloud IDE with pre-configured AI assistant |
| **Shadow AI / security risk** | Centralized model serving eliminates need for external API calls with corporate data |
| **Model lifecycle governance** | Catalog -> Registry -> Deploy flow provides full traceability |
| **Multi-tenant resource sharing** | Rate limiting prevents any single consumer from monopolizing GPU resources |

## Product Features Showcased

| Demo Screen | RHOAI 3.4 Feature | Status | Customer Value |
|---|---|---|---|
| Model Catalog | AI hub with performance benchmarks | GA | Informed model selection without trial-and-error |
| Model Registry | Version control + governance metadata | GA | Audit trail, reproducibility, compliance |
| Model Serving | KServe + vLLM + HardwareProfile | GA | Production-grade serving with GPU optimization |
| MaaS Gateway | Subscription-based access control | GA | Cost attribution, rate limiting, multi-tenant |
| MaaS API Keys | Per-user key management | GA | No shared secrets, individual accountability |
| MaaS Observability | Token consumption dashboards (Perses) | GA | Showback reporting, capacity planning |
| Dev Spaces | Cloud IDE with AI extensions | GA | Consistent dev environments, zero local setup |
| Gen AI Studio | Playground for model testing | GA | Quick validation before integration |

## Pre-Demo Checklist

Before starting the live demo:

```bash
# Verify all components are healthy
./setup/health-check.sh

# Display URLs and credentials
./setup/show-credentials.sh
```

**Verify:**
- [ ] All health checks pass (GPU node, operators, MaaS, model, consumers)
- [ ] RHOAI dashboard is accessible (login works)
- [ ] Dev Spaces workspace loads within 2 minutes
- [ ] Open WebUI is accessible (first login creates admin account)
- [ ] Both API keys generate valid responses (test with `07-verify-maas.sh`)

## Demo Script

### Screen 1: Model Catalog (5 minutes)

**Navigate:** RHOAI Dashboard -> **AI hub** -> **Models** -> **Catalog**

**What to point out:**
- The curated library of Red Hat AI validated models
- Filter options: by hardware, by scenario, by tensor type
- Search for "Qwen" to find the model
- Click into **Qwen3-8B-FP8-dynamic** model card

**Show on the model card:**
- Model metadata: architecture, tensor type (FP8), parameters (8B)
- **Performance Insights** tab: latency and throughput benchmarks per hardware
- Hardware recommendations showing L4 GPU compatibility
- "Register model" action button

**Talking points:**

> "The model catalog gives your data science team a curated, benchmarked library of models. Instead of guessing which model fits their hardware, they can filter by GPU type and see real performance data -- latency, throughput, memory requirements. Every model here has been validated by Red Hat for production use with our inference server."

> "Notice this is an FP8 quantized model -- 8 billion parameters compressed to fit efficiently on a single L4 GPU while maintaining quality. Red Hat validates the quantization doesn't degrade output quality."

**Transition:** "Once the team selects a model, they register it in the model registry for governance and version control..."

---

### Screen 2: Model Registry (3 minutes)

**Navigate:** **AI hub** -> **Models** -> **Registry**

**What to point out:**
- Qwen3-8B registered with version "v1.5"
- OCI artifact URI: `oci://registry.redhat.io/rhelai1/modelcar-qwen3-8b-fp8-dynamic:1.5`
- Custom metadata: provider (RedHatAI), tensor type (FP8), validated collection
- Deployment history showing the active deployment in the `models-as-a-service` namespace
- Version management capabilities

**Talking points:**

> "The model registry is your single source of truth for what models are approved and deployed in your organization. It provides version control, audit trail, and traceability -- from when a model was selected in the catalog to when it was deployed to production."

> "For compliance-sensitive industries -- banking, healthcare, government -- this audit trail is critical. You can answer 'Which model version is serving requests right now?' and 'Who approved this deployment?' at any time."

**Transition:** "Let's look at the actual running deployment..."

---

### Screen 3: Model Serving (3-5 minutes)

**Navigate:** **AI hub** -> **Deployments** (or **Data Science Projects** -> **models-as-a-service** project)

**What to point out:**
- LLMInferenceService "qwen3-8b-fp8" with green **Ready** status
- Hardware Profile: "NVIDIA L4 GPU"
- Serving Runtime: vLLM CUDA
- Resource allocation visible: 1 GPU, 2 CPU, 8Gi memory
- Replica count: 1 (min/max configurable for autoscaling)

**Optional live interaction:** Navigate to **Gen AI Studio** -> **Playground**
- Select the Qwen3-8B model
- Type: "Write a short Ansible task to install and start nginx on RHEL 9"
- Show the streaming response
- Point out response quality and speed

**Talking points:**

> "The model is served using the Red Hat AI Inference Server -- a production-grade, enterprise-supported vLLM distribution. The hardware profile ensures workloads land on the correct GPU node automatically."

> "This single L4 GPU is efficiently serving both our consumers thanks to FP8 quantization and vLLM's continuous batching -- multiple concurrent requests are handled without deploying separate instances."

**Transition:** "Now here's what makes this enterprise-ready -- let's see how we govern access..."

---

### Screen 4: MaaS Governance (5 minutes)

**Navigate:** **Settings** -> **Models-as-a-Service** (requires admin view)

**What to point out:**
- Two subscriptions visible: **devspaces-subscription** and **chatbot-subscription**
- Each bound to a different OpenShift group
- Rate limits: 50,000 tokens/min per subscription
- Different cost center metadata (engineering-tools vs. platform-services)

**Navigate:** Show the authorization policies
- **devspaces-access** policy granting model access to `devspaces-users` group
- **chatbot-access** policy granting model access to `chatbot-users` group

**Navigate:** User view -> **MaaS** -> **API Keys**
- Show API keys are bound to specific subscriptions at creation time
- Each key tracks consumption against its subscription quota

**Talking points:**

> "This is the governance layer that enterprises need. Each team gets their own subscription with independent token quotas. The engineering team uses tokens for code assistance, the operations team uses tokens for their chatbot -- same model, completely separate accounting."

> "API keys are per-user, bound to a subscription at creation time. If someone leaves the team, you revoke their key without affecting anyone else. No shared credentials, no leaked secrets that compromise everyone."

> "Rate limiting at 50,000 tokens per minute means no single team can monopolize GPU resources during peak hours. You can set different limits per team based on business priority."

**Transition:** "Let me show you what the developer experience actually looks like..."

---

### Screen 5: Dev Spaces - AI Coding Assistant (5-7 minutes)

**Open:** Dev Spaces workspace URL (from `show-credentials.sh`)

**Wait:** Workspace may take 30-60 seconds to start if cold

**What to point out:**
- VS Code running entirely in the browser -- zero local setup required
- Continue extension active in the left sidebar (Continue icon)
- The workspace has sample Ansible playbooks pre-loaded
- Connected to Qwen3-8B via the MaaS endpoint (show Continue settings)

**Live demo steps:**
1. Open `devspaces-workspace/sample-playbooks/webserver.yaml`
2. Position cursor at the end of the tasks section
3. Open Continue chat panel (Ctrl+L or click the Continue icon)
4. Type: **"Add a task to deploy a custom vhost configuration with the server_name variable"**
5. Show the AI-generated Ansible task with correct module usage
6. Accept the suggestion and show it integrates cleanly
7. Start typing a new task manually -- show **tab autocomplete** suggesting YAML

**Talking points:**

> "The developer opens their cloud IDE and immediately has AI assistance -- no local setup, no API key management from their perspective. Everything is pre-configured by the platform team."

> "Notice the model generates proper Ansible module syntax -- `ansible.builtin.template`, correct indentation, proper use of variables. This is because Qwen3-8B was trained on high-quality code including Ansible."

> "Every token consumed here is tracked under the devspaces-subscription. You know exactly how much AI assistance your development team is using -- showback data for capacity planning."

**Transition:** "Now a completely different team uses the same model, but through a different interface..."

---

### Screen 6: Open WebUI - Chatbot Interface (3-5 minutes)

**Open:** Chatbot URL (from `show-credentials.sh`)

**Note:** First-time access requires creating an admin account (email + password). Do this before the demo.

**What to point out:**
- Clean, familiar chat interface (similar to ChatGPT)
- Model selector showing Qwen3-8B (the MaaS-served model)
- Conversation history and organization features
- No data leaves the cluster -- all processing is internal

**Live demo steps:**
1. Start a new chat
2. Type: **"Write an Ansible playbook to configure chrony NTP on RHEL 9 servers with a custom NTP server pool"**
3. Show the streaming response
4. Follow up: **"Add error handling and a verification step that checks NTP synchronization status"**
5. Show the model maintains context and improves the playbook

**Talking points:**

> "This is a separate consumer -- an operations team using a chatbot for automation questions and runbook generation. Same underlying model, completely independent subscription."

> "Their token consumption is tracked separately under chatbot-subscription. When finance asks 'how much are we spending on AI?' you can answer per team, per month, per use case."

> "All data stays inside your OpenShift cluster. No prompts are sent to external APIs. This is critical for organizations handling sensitive infrastructure knowledge."

**Transition:** "Let's look at how we track all this consumption..."

---

### Screen 7: Observability & Wrap-up (2-3 minutes)

**Navigate:** RHOAI Dashboard -> **Observe & monitor** -> **Dashboard**

**What to point out:**
- Three Perses dashboards available: Cluster Admin, Model, MaaS Usage Admin
- Select **MaaS Usage Admin** dashboard -- shows token consumption per subscription
- Request counts and token consumption per consumer
- Rate limit utilization and remaining quota
- Switch to **Model** dashboard -- shows inference latency and throughput metrics

**Talking points:**

> "Full observability into AI consumption. The devspaces-subscription has consumed tokens for code assistance, while chatbot-subscription consumed tokens for operational queries. This is your showback data."

> "If either team hits their 50,000 tokens/min limit, they get rate-limited -- but not the other team. The governance ensures fair resource sharing without manual intervention."

**Closing statement:**

> "To summarize: we've shown a complete enterprise AI governance platform -- from model selection through a curated catalog, to version-controlled registry, to production serving with hardware optimization, to subscription-based governance with independent tracking per team. All running on your OpenShift infrastructure, with your data staying in your control."

---

## Competitive Differentiators

| Alternative | OpenShift AI MaaS Advantage |
|---|---|
| **Raw K8s + vLLM** | No governance, no cost tracking, no multi-tenant isolation. MaaS adds the enterprise control plane without custom engineering. |
| **Cloud LLM APIs (OpenAI, Azure)** | Data leaves your infrastructure. No control over model versions or data residency. Vendor lock-in. Unpredictable costs. |
| **Unmanaged open-source UIs** | No subscription model, no per-user tracking, no rate limiting. Shadow AI risk with no visibility. |
| **Custom-built API gateway** | Months of engineering for a one-off solution. MaaS is built into the platform with day-2 operations support. |
| **Other MLOps platforms** | Often separate from the serving platform. RHOAI provides catalog -> registry -> serve -> govern in one integrated experience. |

## Objection Handling

### "Can we just use OpenAI/Azure OpenAI?"

> "You can -- and MaaS supports routing to external providers through the same governance gateway. But for sensitive data (infrastructure configs, proprietary code, customer data), running models on your own infrastructure gives you control over data residency, model versions, and costs. Many organizations use a hybrid approach: external APIs for non-sensitive work, self-hosted models for proprietary data."

### "Will an 8B model be good enough for production?"

> "For this demo we're using Qwen3-8B which excels at code generation and instruction following. In production, you can:
> - Run larger models (70B+) on bigger GPU nodes (A100, H100)
> - Deploy multiple models through the same MaaS gateway
> - Route different use cases to different models based on complexity
> - The governance layer works the same regardless of model size."

### "How does this scale to hundreds of users?"

> "KServe handles autoscaling -- you can set min/max replicas based on demand. vLLM's continuous batching efficiently handles concurrent requests. MaaS subscriptions can have different rate limits per team. For large-scale deployments, you'd add more GPU nodes and let the autoscaler handle distribution."

### "What about fine-tuning our own models?"

> "OpenShift AI supports fine-tuning workflows through InstructLab and the training operator. Fine-tuned models go through the same catalog -> registry -> serve -> govern pipeline with full traceability. You can version your fine-tuned models alongside base models."

### "What's the cost of running this?"

> "The main cost is the GPU instance -- one g6.2xlarge (L4 GPU) for this demo. In production, you'd right-size based on concurrent users and latency requirements. The MaaS platform itself runs on existing control-plane infrastructure. Compare this to cloud API pricing: at scale, self-hosted models are typically 3-10x cheaper per token."

### "Is this supported in production?"

> "Models-as-a-Service is GA (Generally Available) in OpenShift AI 3.4. The model catalog, registry, and KServe serving are all GA. Token consumption observability is Technology Preview. Full Red Hat support SLA applies."

## Timing Guide

| Section | Duration | Running Total |
|---|---|---|
| Introduction / context setting | 2-3 min | 3 min |
| Model Catalog | 4-5 min | 8 min |
| Model Registry | 2-3 min | 11 min |
| Model Serving + Playground | 3-4 min | 15 min |
| MaaS Governance | 4-5 min | 20 min |
| Dev Spaces live coding | 5-7 min | 26 min |
| Chatbot interaction | 3-4 min | 30 min |
| Observability + wrap-up | 2-3 min | 33 min |
| **Total** | **~25-33 min** | |

**Tips:**
- If short on time, combine screens 1-3 into a quick walkthrough (3 min total)
- The live coding demo (screen 5) is the most impactful -- don't rush it
- Have a fallback prompt ready if the model takes too long to respond

## Appendix: Feature Reference

| Feature | Official Documentation |
|---|---|
| Models-as-a-Service | [RHOAI 3.4 MaaS Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index) |
| Model Catalog | [Working with the Model Catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/working_with_the_model_catalog/index) |
| Model Registry | [Managing Model Registries](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/managing_model_registries/index) |
| Model Serving | [Deploying Models](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/deploying_models/index) |
| Red Hat AI Validated Models | [Validated Models Reference](https://docs.redhat.com/en/documentation/red_hat_ai/3/html-single/validated_models/index) |
| Dev Spaces | [Dev Spaces 3.28 Installation](https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/3.28/html-single/installation_guide/index) |
| AI Code Assistants | [AI Code Assistants with Dev Spaces](https://developers.redhat.com/articles/2026/01/28/guide-ai-code-assistants-red-hat-openshift-dev-spaces) |
| Gen AI Studio | [Experimenting with Models](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/experimenting_with_models_in_the_gen_ai_playground/index) |
