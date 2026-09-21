# Praxis ExternalModel MVP

This flow tests the RHOAI 3.6 Praxis ExternalModel integration without changing
the existing OGXServer or its Helm releases.

For a cold run, use `cleanup-all.sh`, then reinstall with `./setup.sh` and
`./provision.sh` before running the commands below.

```bash
export LITEMAAS_API_KEY="$(ls-secrets LITEMAAS_API_KEY)"
./praxis-mvp/build-images.sh
./praxis-mvp/create-workload.sh
./praxis-mvp/test.sh
```

`build-images.sh` always uses unique Quay tags and refuses a tag that already
exists. It builds the AI Gateway controller, MaaS controller, OGX Kubernetes
operator, and Praxis images. It also checks out the AI Gateway operator for the
manifests applied by `create-workload.sh`. Override a source revision with
`CONTROLLER_REF`, `MAAS_REF`, `AI_GATEWAY_OPERATOR_REF`,
`OGX_K8S_OPERATOR_REF`, or `PRAXIS_REF`.

The workload opts the default MaaS tenant into Praxis and adds a LiteMaaS
ExternalProvider for `Qwen2.5-VL-7B-Instruct`. A second tenant is not used
because multi-tenant MaaS callback routing remains unqualified. The test
verifies authenticated LiteMaaS routing using `Qwen2.5-VL-7B-Instruct`,
unknown-model handling, the custom Praxis image, and preservation and
availability of the pre-existing OGXServer.

The client-facing model name currently matches the LiteMaaS provider model.
`MODEL_TRANSLATION_BUG.md` tracks the missing `targetModel` translation needed
to restore a stable MaaS alias.

The cleanup is intentionally destructive:

```bash
./praxis-mvp/cleanup-all.sh --confirm-delete-all
```

It removes OGX, AI Gateway, RHOAI, Kyverno, RHCL/cert-manager operands, test
resources, and related CRDs so the cluster can be reinstalled from scratch.
