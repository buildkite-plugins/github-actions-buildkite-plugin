# Development

Use this guide to test plugin changes, run CI smoke tests, and prepare a release.

## Prerequisites

Install the following tools before you run local checks:

- [Bats Core](https://bats-core.readthedocs.io/en/stable/installation.html)
- [ShellCheck](https://www.shellcheck.net/)

## Run local checks

From the repository root, run:

```bash
bats tests
shellcheck hooks/* lib/*
```

The Bats suite makes no live network requests. CI runs these checks plus the Buildkite plugin linter. Importer runtime dependencies are listed in `plugin.yml`.

### Isolate the test cache

Set `BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` to isolate the cache in tests. This is not a supported plugin setting and does not change the release source or verification policy.

## Run CI smoke tests

The Buildkite Pipelines build runs a required released-runtime smoke test that:

- Pins the plugin to the build's full public commit SHA.
- Omits `version`, then downloads and verifies the default public `buildkite-gha` release.
- Uploads `.github/workflows/plugin-smoke.yml`.
- Checks out the same commit in a generated job and verifies the release defaults.

This test uses Linux x86-64 Buildkite hosted agents but does not need configured secrets or a cache service. The `buildkite/buildkite-gha` demo pipeline tests cache integration separately.

To run the optional source smoke test, create a Buildkite Pipelines build and set `GITHUB_ACTIONS_SOURCE_REF` to `latest` or a full lowercase 40-character runtime commit SHA. This test uses the repository's `mise.toml` to install `mise` 2026.5.12 and Go 1.26.5. It pins the plugin to the build's exact commit and tests `buildkite-gha-source-ref` from start to finish. Ordinary builds continue to test the released archive and installation path.

## Release the plugin

Plugin releases are Git tags and contain no generated assets. Before you create a `v0.x.y` tag:

1. Verify that the default runtime version has a public `buildkite/buildkite-gha` release.
1. Confirm that the released-runtime smoke test passes against that release.
1. Confirm that the cache integration demo passes against the same plugin commit.
1. Wait for the Buildkite Pipelines build for `main` to pass.

For changes to the generated-job runtime contract, test the compatible `buildkite-gha` source with the optional source smoke test before publishing the runtime release. Update the plugin default separately, then pass the released-runtime smoke test before tagging the plugin. This process tests the repositories together before release.

When changing the default runtime version, update `plugin.yml`, `hooks/command`, `.github/workflows/plugin-smoke.yml`, and the default-version note in the README together. Make sure the README examples and versioned compatibility links describe the recommended runtime release.

Push the tag after all checks pass. The Buildkite pipeline also tests tag builds.
