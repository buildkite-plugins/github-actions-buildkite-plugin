# Development

Use this guide to test plugin changes, verify the live smoke test, and publish a release.

## Test changes

Before you submit changes, run the Bats test suite, ShellCheck, and the Buildkite plugin linter:

```bash
bats tests
shellcheck hooks/* lib/*
docker run --rm -v "$PWD:/plugin:ro" buildkite/plugin-linter --id github-actions
```

The Bats suite makes no live network requests. The plugin installs its pinned mise release and otherwise requires the standard Linux utilities listed in `plugin.yml`.

## Live smoke test

The Buildkite Pipelines build also runs a live smoke test without a cache service. The smoke test:

- Pins this plugin to the build's exact `BUILDKITE_COMMIT`
- Omits the optional CLI `version`
- Downloads and verifies version `0.2.0` of the public `buildkite-gha` CLI
- Uploads `.github/workflows/plugin-smoke.yml`

The generated job checks out the same public commit without authentication and verifies the release-candidate defaults. This test requires a full 40-character public GitHub commit and Buildkite hosted agents running Linux x86-64. It does not require secrets, cloud provider tokens, or GitHub Actions cache token minting.

The demo pipeline in the public [`buildkite/buildkite-gha` repository](https://github.com/buildkite/buildkite-gha) tests the cache service separately.

## Test cache override

`BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` overrides the cache root for isolated tests only. It does not change the hard-coded release repository, asset names, or verification policy and is not a supported plugin setting.

## Release

Plugin releases are Git tags and contain no generated assets. To release the plugin:

1. Verify that the public `buildkite/buildkite-gha` repository has a GitHub release for the default CLI version.
1. Confirm that the branch's live plugin smoke test passes against the release archive.
1. Confirm that the companion cache-extension demo passes against the same plugin commit.
1. Wait for the `main` branch build to pass in Buildkite Pipelines.
1. Create and push the matching `v0.x.y` tag.

The pipeline also tests tag builds.
