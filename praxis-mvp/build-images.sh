#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

registry="${PRAXIS_MVP_REGISTRY:-quay.io/higginsd/imagehost}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="${PRAXIS_MVP_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
run_dir="$script_dir/artifacts/$run_id"
source_dir="$script_dir/src"
engine="${CONTAINER_ENGINE:-podman}"

controller_ref="${CONTROLLER_REF:-refs/pull/13/head}"
maas_ref="${MAAS_REF:-main}"
operator_ref="${AI_GATEWAY_OPERATOR_REF:-main}"
praxis_ref="${PRAXIS_REF:-main}"
extproc_ref="${PRAXIS_EXTPROC_REF:-main}"
rebase_sources=false

while (($#)); do
  case "$1" in
    --rebase) rebase_sources=true ;;
    -h|--help) printf 'Usage: %s [--rebase]\n' "$0"; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for command in git "$engine" skopeo oc jq; do
  command -v "$command" >/dev/null || { printf 'ERROR: %s is required\n' "$command" >&2; exit 1; }
done
oc whoami >/dev/null || { printf 'ERROR: log in to OpenShift first\n' >&2; exit 1; }
mkdir -p "$run_dir/src" "$source_dir"

checkout() {
  local repository="$1" ref="$2" directory="$3"
  git init -q "$directory"
  git -C "$directory" remote add origin "$repository"
  git -C "$directory" fetch --quiet origin "$ref"
  git -C "$directory" checkout --quiet --detach FETCH_HEAD
}

rebase_source() {
  local directory="$1" ref="$2"
  if [[ "$(git -C "$directory" rev-parse --is-shallow-repository)" == true ]]; then
    git -C "$directory" fetch --quiet --unshallow origin
  fi
  git -C "$directory" fetch --quiet origin "$ref"
  git -C "$directory" rebase --quiet FETCH_HEAD
}

source_revision() {
  local directory="$1" revision
  revision="$(git -C "$directory" rev-parse HEAD)"
  if [[ -n "$(git -C "$directory" status --porcelain)" ]]; then
    revision+="-dirty"
  fi
  printf '%s' "$revision"
}

prepare_source() {
  local name repository ref directory
  name="$1"
  repository="$2"
  ref="$3"
  directory="$source_dir/$name"
  if [[ ! -d "$directory/.git" ]]; then
    [[ ! -e "$directory" ]] || { printf 'ERROR: %s exists but is not a git checkout\n' "$directory" >&2; exit 1; }
    checkout "$repository" "$ref" "$directory"
  fi
  if [[ "$rebase_sources" == true ]]; then
    rebase_source "$directory" "$ref"
  fi
  source_revision "$directory"
}

build_push() {
  local name="$1" revision="$2" context="$3" containerfile="$4"
  local image="$registry:${name}-${revision:0:12}-${run_id}" digest
  if skopeo inspect "docker://$image" >/dev/null 2>&1; then
    printf 'ERROR: refusing pre-existing destination %s\n' "$image" >&2
    exit 1
  fi
  "$engine" build --pull=always --platform linux/amd64 --file "$containerfile" \
    --label "org.opencontainers.image.revision=$revision" --tag "$image" "$context" >&2
  "$engine" push "$image" >&2
  digest="$(skopeo inspect --format '{{.Digest}}' "docker://$image")"
  [[ "$digest" == sha256:* ]] || { printf 'ERROR: no digest for %s\n' "$image" >&2; exit 1; }
  printf '%s@%s' "${image%:*}" "$digest"
}

controller_sha="$(prepare_source controller https://github.com/opendatahub-io/ai-gateway-controller.git "$controller_ref")"
maas_sha="$(prepare_source maas https://github.com/opendatahub-io/models-as-a-service.git "$maas_ref")"
operator_sha="$(prepare_source operator https://github.com/opendatahub-io/ai-gateway-operator.git "$operator_ref")"
praxis_sha="$(prepare_source praxis https://github.com/praxis-proxy/ai.git "$praxis_ref")"
extproc_sha="$(prepare_source extproc https://github.com/opendatahub-io/praxis-extproc.git "$extproc_ref")"

if [[ "${PRAXIS_MVP_PREPARE_SOURCES_ONLY:-false}" == true ]]; then
  printf 'Persistent sources are ready in %s\n' "$source_dir"
  exit 0
fi

controller_image="$(build_push ai-gateway-controller "$controller_sha" "$source_dir/controller" "$source_dir/controller/Dockerfile")"
maas_image="$(build_push maas-controller "$maas_sha" "$source_dir/maas" "$source_dir/maas/maas-controller/Dockerfile")"
operator_image="$(build_push ai-gateway-operator "$operator_sha" "$source_dir/operator" "$source_dir/operator/Containerfile")"
praxis_image="$(build_push praxis-ai "$praxis_sha" "$source_dir/praxis" "$source_dir/praxis/Containerfile")"
extproc_image="$(build_push praxis-extproc "$extproc_sha" "$source_dir/extproc" "$source_dir/extproc/Containerfile")"

for name in controller maas operator praxis extproc; do
  cp -a "$source_dir/$name" "$run_dir/src/$name"
done

cat >"$run_dir/images.env" <<EOF
RUN_ID=$run_id
RUN_DIR=$run_dir
CONTROLLER_SHA=$controller_sha
CONTROLLER_IMAGE=$controller_image
MAAS_SHA=$maas_sha
MAAS_IMAGE=$maas_image
AI_GATEWAY_OPERATOR_SHA=$operator_sha
AI_GATEWAY_OPERATOR_IMAGE=$operator_image
PRAXIS_SHA=$praxis_sha
PRAXIS_IMAGE=$praxis_image
PRAXIS_EXTPROC_SHA=$extproc_sha
PRAXIS_EXTPROC_IMAGE=$extproc_image
EOF
cp "$run_dir/images.env" "$script_dir/artifacts/images.env"

if ! oc get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
  oc apply --server-side -f https://github.com/kyverno/kyverno/releases/download/v1.12.1/install.yaml
  oc wait --for=condition=available deployment/kyverno-admission-controller -n kyverno --timeout=5m
fi

oc apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: praxis-mvp-image-swap
spec:
  background: false
  failurePolicy: Fail
  rules:
  - name: ai-gateway-operator
    match: {any: [{resources: {kinds: [Pod], selector: {matchLabels: {app.kubernetes.io/name: ai-gateway-operator}}}}]}
    mutate:
      foreach:
      - list: request.object.spec.containers
        preconditions: {all: [{key: "{{ element.image }}", operator: AnyIn, value: ["*odh-ai-gateway-operator*"]}]}
        patchStrategicMerge: {spec: {containers: [{name: "{{ element.name }}", image: "$operator_image"}]}}
      - list: request.object.spec.initContainers
        preconditions: {all: [{key: "{{ element.image }}", operator: AnyIn, value: ["*odh-ai-gateway-operator*"]}]}
        patchStrategicMerge: {spec: {initContainers: [{name: "{{ element.name }}", image: "$operator_image"}]}}
  - name: maas-controller
    match: {any: [{resources: {kinds: [Pod]}}]}
    mutate:
      foreach:
      - list: request.object.spec.containers
        preconditions: {all: [{key: "{{ element.image }}", operator: AnyIn, value: ["*odh-maas-controller*"]}]}
        patchStrategicMerge: {spec: {containers: [{name: "{{ element.name }}", image: "$maas_image"}]}}
  - name: ai-gateway-controller
    match: {any: [{resources: {kinds: [Pod], selector: {matchLabels: {control-plane: ai-gateway-controller}}}}]}
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - name: manager
            image: "$controller_image"
            args:
            - --leader-elect
            - --health-probe-bind-address=:8081
            - --image=$extproc_image
            - --praxis-image=$praxis_image
            - --praxis-image-pull-policy=IfNotPresent
            - --known-cluster=provider-praxis-mvp-provider-a
            - --known-cluster=provider-praxis-mvp-provider-b
  - name: praxis
    match: {any: [{resources: {kinds: [Pod]}}]}
    mutate:
      foreach:
      - list: request.object.spec.containers
        preconditions: {all: [{key: "{{ element.image }}", operator: AnyIn, value: ["*praxis-ai*"]}]}
        patchStrategicMerge: {spec: {containers: [{name: "{{ element.name }}", image: "$praxis_image"}]}}
  - name: praxis-extproc
    match: {any: [{resources: {kinds: [Pod]}}]}
    mutate:
      foreach:
      - list: request.object.spec.containers
        preconditions: {all: [{key: "{{ element.image }}", operator: AnyIn, value: ["*praxis-extproc*"]}]}
        patchStrategicMerge: {spec: {containers: [{name: "{{ element.name }}", image: "$extproc_image"}]}}
EOF
oc wait --for=condition=Ready clusterpolicy/praxis-mvp-image-swap --timeout=2m
printf 'Images and Kyverno policy are ready. State: %s\n' "$run_dir/images.env"
