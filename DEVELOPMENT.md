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

## Run continuous integration smoke tests

The Buildkite Pipelines build runs a required released-runtime smoke test that:

- Pins the plugin to the build's full public commit SHA.
- Omits `version`, then uses mise to select and verify the latest public `buildkite-gha` release.
- Uploads `.github/workflows/plugin-smoke.yml`.
- Checks out the same commit in a generated job and verifies the release defaults.

This test uses Linux x86-64 Buildkite hosted agents but does not need configured secrets or a cache service.

The same build also runs a source smoke with a pinned full `buildkite-gha` commit. It verifies that `source-ref` installs the required Go toolchain, builds the selected source, and runs the generated job without replacing the released-runtime smoke.

## Release the plugin

Plugin releases are Git tags and contain no generated assets. Before you create a `v0.x.y` tag:

1. Verify that the default runtime version has a public `buildkite/buildkite-gha` release.
1. Review the compatibility and security documentation at that runtime tag rather than using the potentially unreleased behavior on `main`.
1. Confirm that the released-runtime smoke test selects and verifies that release through mise.
1. Wait for the Buildkite Pipelines build for `main` to pass.

When changing runtime integration, update `plugin.yml`, `hooks/command`, `.github/workflows/plugin-smoke.yml`, `tests/command.bats`, and the README together. Make sure the examples and versioned compatibility and security links describe the recommended runtime release.

Push the tag after all checks pass. The Buildkite pipeline also tests tag builds.
