# Optional act: non-human identity for a platform agent

Run this after the Models-as-a-Service lab (phases 0–10). `setup/full-setup.sh` does not call it. The act follows [Constraining AI agents with Red Hat AI](https://developers.redhat.com/articles/2026/09/16/constraining-ai-agents-with-red-hat-ai-containment-identity-and-governance) for containment, SPIFFE identity, and tool governance. It does not install Kata, OpenShell, or NeMo Guardrails.

The customer asked how an enterprise governs non-human identities, and how intent-based access control applies to AI agents. This act is that story. It is not a demonstration of stolen-user impersonation.

## What you open

```bash
bash setup/11-agent-identity.sh
```

Then open the presenter page:

**https://agent-console.\<cluster-apps-domain\>**

`bash setup/show-credentials.sh` prints the live URL when the route exists. The install script prints it too.

The page is the demo. You do not paste a token, and you do not start from the OpenShift MCP gateway URL. The page asks the selected workload to act. That workload uses its own short-lived SPIFFE JWT.

## What you say, then what you click

About five minutes.

1. **The ask.** "You already govern users and API keys. These two processes are not users. Each one gets an identity from the Zero Trust Workload Identity Manager, and that identity is what the tool gateway trusts."
2. **Platform agent → Show identity.** Read the SPIFFE ID: `spiffe://<apps-domain>/ns/agent-governance/sa/platform-agent`. "There is no API key in the pod. SPIRE rotates this token."
3. **List pods.** The pill says Allowed, and the page shows a pod table. "This identity's intent is cluster health: list pods, get a pod, list events, list namespaces."
4. **Read pod logs.** The pill says Denied. "Logs are outside that intent. The same denial applies to reading configuration. The gateway checks the identity and the tool name. The proxy also reads the JSON-RPC body, so a caller cannot relabel a log read as a pod list."
5. **Untrusted agent → List pods.** Denied, and the subject is now `.../sa/untrusted-agent`. "Same cluster, same tools, different identity. This one has no intent that includes those tools."
6. **Platform agent → Ask Qwen.** Optional. The model answers without a Models-as-a-Service API key, on the same direct vLLM path the Gen AI Playground uses. "The model call is not the control. The control is which identity may call which tool."

If they ask whether the untrusted agent can still talk to the model, click **Ask Qwen** while that identity is selected. It can. Both pods are allowed to reach vLLM on the cluster network. Only the platform identity is allowed to call the health tools.

## What each control proves

| Click | Platform agent | Untrusted agent |
|---|---|---|
| Show identity | `sa/platform-agent` | `sa/untrusted-agent` |
| List pods | Allowed | Denied |
| Read pod logs | Denied | Denied |
| Ask Qwen | Answers, no MaaS API key | Answers, no MaaS API key |

Allowed health tools that are not buttons on the page: `pods_get`, `events_list`, `namespaces_list`. Denied with logs: `resources_get`, `configuration_view`.

## If they want the platform objects

Stay in the OpenShift console. The page is enough for the decision. These objects are the proof underneath it.

| What they ask | Where it is |
|---|---|
| Where do the identities come from? | Installed Operators, project `zero-trust-workload-identity-manager`, **Zero Trust Workload Identity Manager**. Open the ClusterSPIFFEID `agent-governance-workloads`. Its status shows the pods it registered. The operator default `zero-trust-workload-identity-manager-spire-default` registers the rest of the cluster; leave that object alone. |
| What IDs are registered for this act? | From a terminal: `oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- /spire-server entry show`. The lab IDs contain `/ns/agent-governance/sa/`. The two to read out are `platform-agent` and `untrusted-agent`. |
| What is locked down around the agents? | Project `agent-governance`: ResourceQuota `agent-quota`, NetworkPolicy `default-deny`. |
| Where is the tool decision enforced? | Route `agent-mcp` in project `agent-governance`, and AuthPolicy `agent-mcp-auth` in `openshift-ingress`. That policy targets `agent-mcp-gateway` only. `maas-gateway-auth` still targets `maas-default-gateway`. |
| Can this admission webhook take down model serving? | Gatekeeper constraint `agent-governance-run-as-non-root` matches only `agent-governance`. The webhook failure policy is `Ignore`. |

The playground ConfigMap keeps the OpenShift MCP ClusterIP. This act does not send the playground through the agent gateway.

## Install and remove

```bash
bash setup/11-agent-identity.sh
bash setup/11-verify-agent-identity.sh
bash setup/11-uninstall-agent-identity.sh
```

## What stays unchanged

- `setup/00` through `setup/10` and `setup/full-setup.sh`
- `AuthPolicy/maas-gateway-auth` on `maas-default-gateway`
- The OpenShift MCP server, the `mcp-viewer` binding, and the playground MCP URL
- The DataScienceCluster and the Qwen serving stack

Do not merge this branch to `main` until `setup/health-check.sh` and `setup/07-verify-maas.sh` still pass after `11-agent-identity.sh`.

## Not in this lab

Kata Containers can reboot or add nodes. The GPU worker is the inference node, so the lab does not set `runtimeClassName: kata`. OpenShell is out of scope. NeMo Guardrails would sit on the shared inference path or require a DataScienceCluster change, so it is not installed here.
