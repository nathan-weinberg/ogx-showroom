#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != --confirm-delete-all ]]; then
  printf 'Usage: %s --confirm-delete-all\n' "$0" >&2
  printf 'Deletes OGX, AI Gateway, RHOAI, Kyverno, RHCL, cert-manager, and test resources.\n' >&2
  exit 2
fi
for command in oc helm jq; do command -v "$command" >/dev/null || { printf 'ERROR: %s is required\n' "$command" >&2; exit 1; }; done
oc whoami >/dev/null || { printf 'ERROR: log in to OpenShift first\n' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
workload_file="$script_dir/artifacts/workload.env"
BACKEND_NAMESPACE=praxis-mvp-backends
GATEWAY_NAME=maas-default-gateway
GATEWAY_NAMESPACE=openshift-ingress
if [[ -f "$workload_file" ]]; then
  # shellcheck disable=SC1090
  source "$workload_file"
fi

mapfile -t tenant_namespaces < <(oc get aitenant -A -o json 2>/dev/null | jq -r '.items[].status.tenantNamespace // empty' | sort -u)

for release in ogx-rhoai ogx-infra; do
  helm uninstall "$release" -n redhat-ods-applications --timeout 5m 2>/dev/null || true
done

oc delete aitenant --all -n ai-tenants --ignore-not-found --timeout=10m 2>/dev/null || true
oc delete datasciencecluster --all --ignore-not-found --timeout=10m 2>/dev/null || true
oc delete dscinitialization --all --ignore-not-found --timeout=10m 2>/dev/null || true
oc delete aigateway --all --ignore-not-found --wait=false 2>/dev/null || true
oc delete config.maas.opendatahub.io --all --ignore-not-found --wait=false 2>/dev/null || true

oc delete clusterpolicy praxis-mvp-image-swap replace-rhoai-ogx-images sync-secrets add-imagepullsecrets replace-image-registry --ignore-not-found
oc delete clusterrolebinding praxis-mvp-ai-gateway-bootstrap praxis-mvp-ai-gateway-controller --ignore-not-found
oc delete clusterrole praxis-mvp-ai-gateway-bootstrap praxis-mvp-ai-gateway-controller --ignore-not-found
oc delete gateway "$GATEWAY_NAME" praxis-mvp-gateway -n "$GATEWAY_NAMESPACE" --ignore-not-found
oc delete gateway maas-default-gateway data-science-gateway -n openshift-ingress --ignore-not-found
oc delete gatewayclass data-science-gateway-class --ignore-not-found
helm uninstall openshift-gateway-istiod -n openshift-ingress --timeout 5m 2>/dev/null || true

# Keep RHCL running until it removes the Authorino and Kuadrant finalizers.
oc delete kuadrant --all -n kuadrant-system --ignore-not-found --timeout=10m

rhods_csv="$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
oc delete subscription rhods-operator -n redhat-ods-operator --ignore-not-found
if [[ -n "$rhods_csv" ]]; then oc delete csv "$rhods_csv" -n redhat-ods-operator --ignore-not-found; fi
for namespace in openshift-operators cert-manager-operator; do
  mapfile -t subscriptions < <(oc get subscription -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.spec.name == "rhcl-operator" or .spec.name == "authorino-operator" or .spec.name == "limitador-operator" or .spec.name == "dns-operator" or .spec.name == "openshift-cert-manager-operator") | .metadata.name')
  if ((${#subscriptions[@]})); then oc delete subscription -n "$namespace" "${subscriptions[@]}" --ignore-not-found; fi
done
for namespace in openshift-operators cert-manager-operator; do
  mapfile -t csvs < <(oc get csv -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("^(rhcl|authorino|limitador|dns|cert-manager)-operator\\.")) | .metadata.name')
  if ((${#csvs[@]})); then oc delete csv -n "$namespace" "${csvs[@]}" --ignore-not-found; fi
done
oc delete catalogsource rhoai-catalog -n openshift-marketplace --ignore-not-found

for namespace in "${tenant_namespaces[@]}" "$BACKEND_NAMESPACE" praxis-mvp praxis-mvp-backends praxis-mvp-test ai-tenants models-as-a-service \
  redhat-ai-gateway-infra redhat-ods-applications redhat-ods-monitoring \
  redhat-ods-operator kuadrant-system cert-manager cert-manager-operator kyverno; do
  oc delete namespace "$namespace" --ignore-not-found --wait=false
done

oc delete validatingwebhookconfiguration -l olm.owner.namespace=redhat-ods-operator --ignore-not-found 2>/dev/null || true
oc delete mutatingwebhookconfiguration -l olm.owner.namespace=redhat-ods-operator --ignore-not-found 2>/dev/null || true
oc delete validatingwebhookconfiguration \
  maas-validating-webhook-configuration authorino-validating-webhook-configuration \
  cert-manager-webhook --ignore-not-found 2>/dev/null || true
oc delete mutatingwebhookconfiguration authorino-mutating-webhook-configuration cert-manager-webhook --ignore-not-found 2>/dev/null || true
oc delete -f https://github.com/kyverno/kyverno/releases/download/v1.12.1/install.yaml --ignore-not-found 2>/dev/null || true

crds="$(oc get crd -o name | grep -E '(opendatahub\.io|ogx\.io|kuadrant\.io|cert-manager\.io)' || true)"
if [[ -n "$crds" ]]; then
  # shellcheck disable=SC2086
  oc delete $crds --ignore-not-found --wait=false
fi
oc delete secret pull-secret-brew -n openshift-config --ignore-not-found
rm -f "$script_dir/artifacts/images.env" "$script_dir/artifacts/workload.env"
printf 'Full cleanup requested. Namespace and CRD deletion may continue asynchronously.\n'
printf 'Run %s/setup.sh after all terminating namespaces are gone.\n' "$root_dir"
