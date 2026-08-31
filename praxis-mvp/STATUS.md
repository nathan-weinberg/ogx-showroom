# Praxis MVP Status

Updated: 2026-09-17

## Goal

Test the RHOAI 3.6 MaaS ExternalModel integration through tenant Praxis while
leaving the existing OGX deployment unchanged.

## Result

The former local-provider test passes. The scripts now target LiteMaaS and
remain blocked on the `targetModel` Chat Completions rewrite documented in
`MODEL_TRANSLATION_BUG.md`.

Validation controller image:
`quay.io/higginsd/imagehost@sha256:37f02d30a0ef121faa45f7afbd0668eb56f8bca53dc172e06378d472e6a8db6c`

## LiteMaaS Validation

- Restored the original controller image:
  `quay.io/higginsd/imagehost@sha256:d280bc418a9e749ab06ae906a09398d1fdf7a10f38a07a7556b70b7dbc2a24d2`.
- Provider A targets `litemaas.rhoai.rh-aiservices-bu.com` with model
  `Qwen2.5-VL-7B-Instruct`.
- Direct `POST /v1/chat/completions` using `LITEMAAS_API_KEY` succeeds and
  returns `RedHatAI/Qwen2.5-VL-7B-Instruct-FP8-Dynamic`.
- A gateway request using `model: praxis-mvp-demo` reaches LiteMaaS but returns
  HTTP 401 because Praxis forwards that client model name unchanged.

## Working Components

- RHCL, Kuadrant, Authorino, and Limitador are ready.
- Authorino runs plaintext for this POC because RHOAI 3.6 EA did not generate
  TLS configuration for Kuadrant's `kuadrant-auth-service` Envoy cluster.
- Authorino mounts the injected OpenShift service CA for its internal HTTPS
  calls to MaaS API.
- MaaS API key creation succeeds with HTTP 201.
- Provider A uses LiteMaaS with a public TLS certificate.
- The gateway forwards the model request to Praxis.

## Changes Made

- `cleanup-all.sh` now deletes `Kuadrant` before RHCL operator components, so
  its finalizers can be removed cleanly.
- `create-workload.sh` waits for the RHCL CSV object before waiting for its
  `Succeeded` phase.
- `create-workload.sh` configures Authorino plaintext for this POC and includes
  a reminder to restore TLS before production use.
- The controller renders `runtime.upstream_ca_file` as
  `/etc/praxis/service-ca/service-ca.crt` and mounts the injected
  `openshift-service-ca.crt` ConfigMap into Praxis.
- Focused controller tenant tests pass.

## Next Step

Build the controller/Praxis model-translation fix from
`MODEL_TRANSLATION_BUG.md`, set `CONTROLLER_REF` to that revision, and run the
LiteMaaS workflow documented in `README.md`. The scripts expect the
client-facing `praxis-mvp-demo` model name to be rewritten to
`Qwen2.5-VL-7B-Instruct`.
