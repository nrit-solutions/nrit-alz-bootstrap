# Custom GitHub runner image (github-runner-aca)

This folder is the build-from-source fallback only. The default path imports
the prebuilt signed image `ghcr.io/nrit-solutions/alz-runner` by digest (see
[The runner image](https://docs.nrit.cloud/setup/bootstrap/#the-runner-image)).

Vendored from `Azure/avm-container-images-cicd-agents-and-runners` at ref
`9b4c292` (the `github-runner-aca` folder), the same source and ref the
`avm-ptn-cicd-agents-and-runners` module builds by default. Everything above
the `# NRIT additions` marker in the `Dockerfile` is upstream and unchanged.
The four helper scripts (`install_actions.sh`, `token.sh`, `entrypoint.sh`,
`app_token.sh`) are copied verbatim.

This image runs jobs as root (`RUN_AS_ROOT` defaults to true in
`entrypoint.sh`) and gives the `runner` user passwordless `sudo`. A job can
therefore read the runners App key from the entrypoint's environment. The
prebuilt image (2.0.0 and later) runs jobs as a non-root user with no `sudo`.

## Why vendored

The self-hosted runner needs `python3`, `checkov` and `conftest` for the
tf-pr-ops policy and scan hook gates. `checkov` is Python-only (no static
binary), so it has to live in the image. We vendor the upstream image folder
and append one tools layer rather than fork the module.

## Wiring

`runners.tf` sets `use_default_container_image = false` and, when
`runner_image_commit` is set, points `custom_container_registry_images` at
this folder at that commit (the ACR build task clones it). To switch to this
path or roll out a new commit, see "Runner image mode switch" in the
repository README.

## Re-syncing upstream

To pick up a newer base runner image: re-copy the upstream files at a new ref,
re-apply the `# NRIT additions` layer, and bump `runner_image_commit`.
