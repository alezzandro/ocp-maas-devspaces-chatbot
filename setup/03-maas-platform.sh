#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 3: MaaS Platform"
echo "========================================="

echo "1. Generating PostgreSQL credentials..."
PG_PASSWORD=$(openssl rand -hex 16)

oc create secret generic maas-postgres-credentials \
  -n redhat-ods-applications \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

echo "2. Deploying PostgreSQL for MaaS..."
oc apply -f "${MANIFESTS_DIR}/maas-platform/postgres/postgres.yaml"

echo "   Waiting for PostgreSQL to be ready..."
oc wait statefulset/postgres -n redhat-ods-applications \
  --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s 2>/dev/null || \
  sleep 30

echo "3. Creating maas-db-config secret..."
DB_URL="postgresql://maasuser:${PG_PASSWORD}@postgres.redhat-ods-applications.svc.cluster.local:5432/maasdb?sslmode=disable"

oc create secret generic maas-db-config \
  -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL="${DB_URL}" \
  --dry-run=client -o yaml | oc apply -f -

echo "4. Configuring Authorino TLS..."
# The MaaS gateway EnvoyFilter talks TLS to Authorino:50051 and trusts the
# OpenShift service CA. Kuadrant creates the Authorino CR with TLS disabled.
# A one-shot patch races that create, so retry until the service and CR exist.
# Do not point SSL_CERT_FILE at the service-ca bundle: that file is not mounted
# in the Authorino pod, and a missing path fails closed on outbound HTTPS.
TLS_WAIT=180
TLS_ELAPSED=0
while true; do
  if oc get authorino authorino -n kuadrant-system &>/dev/null \
     && oc get svc authorino-authorino-authorization -n kuadrant-system &>/dev/null; then
    oc annotate service authorino-authorino-authorization \
      -n kuadrant-system \
      service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
      --overwrite
    for _ in $(seq 1 30); do
      oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && break
      sleep 2
    done
    oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
      "spec": {
        "listener": {
          "tls": {
            "enabled": true,
            "certSecretRef": {
              "name": "authorino-server-cert"
            }
          }
        }
      }
    }'
    TLS_ON=$(oc get authorino authorino -n kuadrant-system \
      -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo "false")
    if [[ "$TLS_ON" == "true" ]] && oc get secret authorino-server-cert -n kuadrant-system &>/dev/null; then
      echo "   Authorino listener TLS enabled."
      break
    fi
  fi
  if [[ "$TLS_ELAPSED" -ge "$TLS_WAIT" ]]; then
    echo "   WARNING: Authorino TLS not configured after ${TLS_WAIT}s. Gateway auth will return HTTP 500."
    break
  fi
  echo "   Authorino not ready for TLS yet (${TLS_ELAPSED}s / ${TLS_WAIT}s)"
  sleep 10
  TLS_ELAPSED=$((TLS_ELAPSED + 10))
done

echo ""
echo "Phase 3 complete: MaaS platform infrastructure ready."
echo "========================================="
