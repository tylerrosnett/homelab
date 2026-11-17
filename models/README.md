# Models

Each `*.yaml` file here describes one model. The `model-artifact` workflow
(`.github/workflows/model-artifact.yaml`) turns a file into a
[ModelPack](https://modelpack.org/) artifact and pushes it to the private GHCR package
`ghcr.io/tylerrosnett/models/<name>`.

## Spec fields

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Artifact name and vLLM `--served-model-name` |
| `repo` | yes | Hugging Face repo, `org/name` |
| `revision` | yes | Full 40-character commit SHA. Never a branch name |
| `include` | yes | Glob patterns to download. List only what the server needs (weights, configs, tokenizer, docs) |
| `family`, `paramSize`, `precision`, `quantization` | no | Written into the ModelPack config |

## Adding or changing a model

1. Add or edit the spec file and merge it. A push to `main` that touches `models/*.yaml`
   builds the changed files. You can also run the workflow by hand from the Actions tab.
2. The job summary prints `ghcr.io/tylerrosnett/models/<name>@sha256:…`.
3. Reference the model as `ghcr.io/tylerrosnett/models/<name>:<revision>` in the manifest
   that mounts it.

The artifact tag is the Hugging Face revision, and the workflow refuses to overwrite a tag
that already exists, so a tag always means the same bytes.

**FIXME (modctl-digest-pull):** workloads should pin by digest. They can't yet: the model
CSI driver pulls through modctl, which fetches `ref.Tag()` and ignores the digest, so a
digest-only reference fails with `invalid reference` and `tag@digest` silently uses the tag
(modctl `pkg/backend/pull.go`, still the same on `main` as of 2026-11-16). Once fixed
upstream, switch references to `@sha256:…` and drop the workflow's tag guard.
