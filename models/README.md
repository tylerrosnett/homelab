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
3. Put that digest-pinned reference in the manifest that mounts the model.

The artifact tag is the Hugging Face revision. Workloads always reference the digest.
