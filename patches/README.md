# OPEA customization patches

These patches preserve local changes made for the private RAG deployment.
They do not include the full upstream source repositories.

## GenAIComps ARM64 compatibility

- Upstream repository: OPEA GenAIComps
- Base commit: 8130a3fb9cd8f2fcef8eff6657844e11ddf63d71
- Patch: `opea-genaicomps-arm64.patch`
- Scope: DataPrep and Retriever compatibility changes.

## ChatQnA GPU Compose customization

- Upstream repository: OPEA GenAIExamples
- Base commit: f56422671c8bdf46f59dd758c8c9e38ca41d6555
- Patch: `opea-chatqna-gpu-compose.patch`
- Scope: Local change to the NVIDIA GPU ChatQnA Compose configuration.

## Applying a patch

Review a patch before applying it. Apply it only to a clean checkout
of its corresponding upstream repository and base revision.

Check applicability first:

```bash
git apply --check /path/to/opea-genaicomps-arm64.patch
git apply --check /path/to/opea-chatqna-gpu-compose.patch
```

The two patches target different repositories. Apply each patch only to
its matching repository. Do not apply them to the private platform repo.
