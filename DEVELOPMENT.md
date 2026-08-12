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
shellcheck .buildkite/scripts/* hooks/* lib/*
```

The Bats suite makes no live network requests. CI runs these checks plus the Buildkite plugin linter. Importer runtime dependencies are listed in `plugin.yml`.

## Run continuous integration smoke tests

The Buildkite Pipelines build runs required released-runtime smoke tests that:

- Pins the plugin to the build's full public commit SHA.
- Pins `buildkite-gha` v0.10.1 through mise.
- Runs Linux-only default-image and explicit-image jobs, a mixed Linux-to-macOS graph, and a macOS-only graph.

These tests use Linux x86-64 and native macOS arm64 Buildkite hosted agents without configured secrets or a cache service.

The same build also runs source smokes with a pinned full `buildkite-gha` commit. They verify that `source-ref` installs the required Go toolchain, builds paired Linux amd64 and Darwin arm64 executables from the selected source, and runs Linux, mixed, and macOS-only graphs without replacing the released-runtime smoke.

## Release the plugin

Plugin releases are Git tags and contain no generated assets. Before you create a `v0.x.y` tag:

1. Verify that the default runtime version has a public `buildkite/buildkite-gha` release.
1. Review the compatibility and security documentation at that runtime tag rather than using the potentially unreleased behavior on `main`.
1. Confirm that the released-runtime smoke test selects and verifies that release through mise.
1. Update every `github-actions#vX.Y.Z` reference in `README.md` to the plugin version being released; the plugin linter accepts this prospective version on `main` and requires it on the tag build.
1. Wait for the Buildkite Pipelines build for `main` to pass.

When changing runtime integration, update `plugin.yml`, `hooks/command`, `.github/workflows/plugin-smoke.yml`, `tests/command.bats`, and the README together. Make sure the examples and versioned compatibility and security links describe the recommended runtime release.

Push the tag after all checks pass. The Buildkite pipeline also tests tag builds.

After every strict stable `vX.Y.Z` tag build passes the static checks and all live release and source smoke tests, a final step moves the lightweight `latest` tag to that release commit. Stable `vX.Y.Z` plugin tags remain immutable; `latest` is an intentionally mutable plugin alias, so `github-actions#latest` selects the newest validated stable plugin release. This is separate from the plugin configuration `version: latest`, which selects the latest stable `buildkite-gha` runtime through mise.

The final step installs a pinned GitHub CLI through the same verified mise bootstrap used by the plugin. It assumes `GITHUB_ACTIONS_PLUGIN_RELEASE_TOKEN` is available through `buildkite-agent secret get` only to trusted tag builds. Use a repository-scoped credential with Contents write access, and configure GitHub tag rules to allow that credential to update only the intended mutable tag without weakening protections for release tags. Rerunning a successful release build is a no-op when `latest` already points directly to its commit. A delayed older or divergent release build refuses to replace a newer `latest`; concurrent updates are retried with a bounded force-with-lease.
