#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 2: Platform Configuration"
echo "========================================="

echo "1. Enabling User Workload Monitoring..."
oc apply -f "${MANIFESTS_DIR}/platform-config/monitoring/user-workload-monitoring.yaml"

echo "2. Creating Kuadrant namespace and CR..."
oc apply -f "${MANIFESTS_DIR}/platform-config/kuadrant/namespace.yaml"
sleep 5
oc apply -f "${MANIFESTS_DIR}/platform-config/kuadrant/kuadrant.yaml"

echo "   Waiting for Kuadrant to be ready..."
# The operator often starts before Authorino/Limitador CSVs exist and stays
# on MissingDependency until the controller pod is restarted.
REASON=$(oc get kuadrant kuadrant -n kuadrant-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
if [[ "$REASON" == "MissingDependency" ]]; then
  echo "   Restarting Kuadrant operator (MissingDependency on Authorino/Limitador)..."
  oc rollout restart deployment/kuadrant-operator-controller-manager -n openshift-operators
  oc rollout status deployment/kuadrant-operator-controller-manager -n openshift-operators --timeout=120s \
    2>/dev/null || true
fi
oc wait kuadrant kuadrant -n kuadrant-system \
  --for=condition=Ready --timeout=300s 2>/dev/null || \
  echo "   Kuadrant may need more time to reconcile."

echo "3. Creating MaaS Gateway..."
echo "   (Uses existing data-science-gateway-class and wildcard TLS cert)"
GATEWAY_YAML="${MANIFESTS_DIR}/platform-config/gateway/gateway.yaml"
sed "s/CLUSTER_DOMAIN_PLACEHOLDER/${CLUSTER_DOMAIN}/g" "$GATEWAY_YAML" | oc apply -f -

echo "4. Waiting for MaaS Gateway to reach Programmed=True..."
echo "   (GatewayClass is created by OpenShift AI MaaS in phase 4; Pending here is expected.)"
TIMEOUT=60
INTERVAL=15
ELAPSED=0
while true; do
  STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$STATUS" == "True" ]]; then
    echo "   Gateway is Programmed!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   Gateway not Programmed yet (${STATUS}). Phase 4 waits again after DSC."
    break
  fi
  echo "   Gateway status: ${STATUS} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "5. Creating NetworkPolicy for payload-processing pod..."
oc apply -f "${MANIFESTS_DIR}/platform-config/gateway/payload-processing-netpol.yaml"
echo "   payload-processing pod allowed to reach K8s API."

echo "6. Setting up Observability stack for RHOAI dashboards..."
echo "   Configuring DSCI monitoring with metrics storage..."
oc patch dsci default-dsci --type merge -p '{
  "spec": {
    "monitoring": {
      "managementState": "Managed",
      "namespace": "redhat-ods-monitoring",
      "metrics": {
        "replicas": 1,
        "storage": {
          "size": "5Gi",
          "retention": "15d"
        }
      }
    }
  }
}'

echo "   Waiting for monitoring stack pods to start (up to 120s)..."
TIMEOUT=120
INTERVAL=15
ELAPSED=0
while true; do
  READY=$(oc get monitoring default-monitoring -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$READY" == "True" ]]; then
    echo "   Monitoring stack available!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: Monitoring stack not yet available after ${TIMEOUT}s. Continuing..."
    break
  fi
  echo "   Waiting for monitoring stack... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "   Fixing prometheus-web-tls-ca (secret from ConfigMap data)..."
sleep 10
if oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
  if ! oc get secret prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
    CA_DATA=$(oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring -o jsonpath='{.data.service-ca\.crt}')
    oc create secret generic prometheus-web-tls-ca -n redhat-ods-monitoring --from-literal=service-ca.crt="$CA_DATA"
    echo "   Created prometheus-web-tls-ca secret."
    oc delete pod -n redhat-ods-monitoring -l app.kubernetes.io/name=prometheus --ignore-not-found 2>/dev/null || true
  fi
fi

echo "   Applying NetworkPolicies for Perses access..."
oc apply -f "${MANIFESTS_DIR}/platform-config/perses/network-policies.yaml"

echo "   Creating cluster-prometheus-datasource (workaround for namespace field)..."
oc apply -f "${MANIFESTS_DIR}/platform-config/perses/cluster-prometheus-datasource.yaml" 2>/dev/null || true

echo "   Waiting for Perses pod to become ready..."
oc wait pod -n redhat-ods-monitoring -l app.kubernetes.io/managed-by=perses-operator \
  --for=condition=Ready --timeout=120s 2>/dev/null || \
  echo "   Perses may need more time to start."

echo "   Creating 'perses' service alias for MaaS datasource compatibility..."
cat <<'SVCEOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: perses
  namespace: redhat-ods-monitoring
  labels:
    app: perses-alias
spec:
  type: ExternalName
  externalName: data-science-perses.redhat-ods-monitoring.svc.cluster.local
SVCEOF

echo "7. Fixing ServiceMonitor / PodMonitor compatibility with user-workload monitoring..."
oc label servicemonitor nfd-controller-manager-metrics-monitor -n openshift-nfd \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
oc label servicemonitor odh-model-controller-metrics-monitor -n redhat-ods-applications \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
oc label servicemonitor controller-manager-metrics-monitor -n redhat-ods-applications \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
oc label servicemonitor tempo-operator-controller-manager-metrics-monitor -n openshift-operators \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
oc label servicemonitor opentelemetry-operator-metrics-monitor -n openshift-operators \
  openshift.io/user-monitoring=false --overwrite 2>/dev/null || true

# Istio health port 15021 does not serve /stats/prometheus (HTTP 404) and
# fires TargetDown for 1/3 of istio-pod-monitor targets.
if oc get podmonitor istio-pod-monitor -n openshift-ingress &>/dev/null; then
  if oc get podmonitor istio-pod-monitor -n openshift-ingress -o yaml | grep -q 'regex: "15021"'; then
    echo "   istio-pod-monitor already drops port 15021."
  else
    oc patch podmonitor istio-pod-monitor -n openshift-ingress --type json -p '[
      {"op":"add","path":"/spec/podMetricsEndpoints/0/relabelings/-","value":{
        "action":"drop",
        "regex":"15021",
        "sourceLabels":["__meta_kubernetes_pod_container_port_number"]
      }},
      {"op":"add","path":"/spec/podMetricsEndpoints/0/relabelings/-","value":{
        "action":"drop",
        "regex":".*:15021$",
        "sourceLabels":["__address__"]
      }}
    ]' 2>/dev/null || true
    echo "   Dropped Istio health port 15021 from istio-pod-monitor."
  fi
fi

echo ""
echo "Phase 2 complete: Platform configured."
echo "========================================="
