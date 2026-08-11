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

## Run continuous integration smoke tests

The Buildkite Pipelines build runs a required released-runtime smoke test that:

- Pins the plugin to the build's full public commit SHA.
- Omits `version`, then downloads and verifies the default public `buildkite-gha` release.
- Uploads `.github/workflows/plugin-smoke.yml`.
- Checks out the same commit in a generated job and verifies the release defaults.

This test uses Linux x86-64 Buildkite hosted agents but does not need configured secrets or a cache service. The `buildkite/buildkite-gha` demo pipeline tests cache integration separately.

To run the optional source-runtime smoke test, create a Buildkite Pipelines build and set `GITHUB_ACTIONS_SOURCE_REF` to `latest` or a full lowercase 40-character runtime commit SHA. This test uses the repository's `mise.toml` to install `mise` 2026.5.12 and Go 1.26.5. It pins the plugin to the build's exact commit and tests `buildkite-gha-source-ref` from start to finish. Use an exact runtime commit when validating a release candidate; use `latest` only for exploratory testing. Ordinary builds continue to test the released archive and installation path.

## Release the plugin

Plugin releases are Git tags and contain no generated assets. Before you create a `v0.x.y` tag:

1. Verify that the default runtime version has a public `buildkite/buildkite-gha` release.
1. Review the compatibility and security documentation at that runtime tag rather than using the potentially unreleased behavior on `main`.
1. Confirm that the released-runtime smoke test downloads and verifies that release's public archive.
1. Confirm that the cache integration demo passes against the same plugin commit.
1. Wait for the Buildkite Pipelines build for `main` to pass.

For changes to the generated-job runtime contract, test the exact candidate `buildkite-gha` commit with the optional source-runtime smoke test before publishing the runtime release. Publish the runtime, update the plugin default separately, then pass the released-runtime smoke test before tagging the plugin. This process tests the repositories together before release without treating unreleased `buildkite-gha` `main` behavior as part of the published runtime.

When changing the default runtime version or runtime integration, update `plugin.yml`, `hooks/command`, `.github/workflows/plugin-smoke.yml`, `tests/command.bats`, and the default-version note in the README together. Make sure the README examples and versioned compatibility and security links describe the recommended runtime release. If the runtime provides a dedicated plugin entrypoint, update the hook and integration tests together rather than documenting it before the plugin uses it.

Push the tag after all checks pass. The Buildkite pipeline also tests tag builds.
