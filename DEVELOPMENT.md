# Development

Use this guide to test plugin changes, run CI smoke tests, and prepare a release.

## Prerequisites

Install [mise](https://mise.jdx.dev/), then install the pinned local tools:

```bash
mise install
```

The release tasks also require `gh` authenticated with write access to `buildkite-plugins/github-actions-buildkite-plugin`. The CLI is installed by mise; run `mise exec -- gh auth login` and `mise exec -- gh auth setup-git` once to configure its HTTPS Git credential.

## Run local checks

From the repository root, run:

```bash
mise run check
```

The Bats suite makes no live network requests. CI runs these checks plus the Buildkite plugin linter. Importer runtime dependencies are listed in `plugin.yml`.

## Run continuous integration smoke tests

The Buildkite Pipelines build runs required released-runtime smoke tests that:

- Pins the plugin to the build's full public commit SHA.
- Pins `buildkite-gha` v0.17.0 through mise.
- Runs Linux-only default-image and explicit-image jobs with the experimental `runner` user, a mixed Linux-to-macOS graph, and a macOS-only graph.

These tests use Linux x86-64 and native macOS arm64 Buildkite hosted agents without configured secrets or a cache service.

The same build also runs source smokes with a pinned full `buildkite-gha` commit. They verify that `source-ref` installs the required Go toolchain, builds paired Linux amd64 and Darwin arm64 executables from the selected source, and runs Linux (including the experimental `runner` user), mixed, and macOS-only graphs without replacing the released-runtime smoke.

## Release the plugin

Plugin releases are immutable Git tags with asset-free GitHub Releases. Before you create a `v0.x.y` tag:

1. Verify that the default runtime version has a public `buildkite/buildkite-gha` release.
1. Review the compatibility and security documentation at that runtime tag rather than using the potentially unreleased behavior on `main`.
1. Confirm that the released-runtime smoke test selects and verifies that release through mise.
1. Update every `github-actions#vX.Y.Z` reference in `README.md` to the plugin version being released; the plugin linter accepts this prospective version on `main` and requires it on the tag build.
1. Wait for the Buildkite Pipelines build for `main` to pass.

The Buildkite app contract changes required for server workflow selection without an explicit selector (#33143 and #33235) are deployed. Before releasing this plugin or promoting it to `latest`, publish a compatible `buildkite-gha` release. Do not publish or promote the wrapper first; older runtimes reject selector-free configurations, and the server contract supplies the trusted trigger context that makes them valid.

When changing runtime integration, update `plugin.yml`, `hooks/command`, `.github/workflows/plugin-smoke.yml`, `tests/command.bats`, and the README together. Make sure the examples and versioned compatibility and security links describe the recommended runtime release.

From a clean, up-to-date local `main`, create the immutable lightweight tag:

```bash
mise run release:tag vX.Y.Z
```

The task runs the local checks and refuses a dirty, outdated, existing, or malformed release. The tag triggers another Buildkite build. Once that tag build passes every static check and live release/source smoke test, publish the validated release:

```bash
mise run release:publish vX.Y.Z
```

The publish task creates or updates the GitHub Release and moves the lightweight `latest` tag with an explicit lease. It refuses to move `latest` backwards or across divergent history and is safe to rerun. CI holds no release-write credential.

Stable `vX.Y.Z` plugin tags remain immutable; `latest` is an intentionally mutable plugin alias, so `github-actions#latest` selects the newest manually promoted stable plugin release. This is separate from the plugin configuration `version: latest`, which selects the latest stable `buildkite-gha` runtime through mise.
