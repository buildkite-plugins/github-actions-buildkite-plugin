# Development

## Local checks

```sh
bats tests
shellcheck hooks/* lib/*
```

The Bats suite makes no live network requests. CI runs these checks plus the Buildkite plugin linter. Importer runtime dependencies are listed in `plugin.yml`.

### Test-only cache override

Set `BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` to isolate the cache in tests. This is not a supported plugin setting and does not change the release source or verification policy.

## CI smoke tests

The Buildkite pipeline's live smoke test:

1. Pins the plugin to the build's full public commit SHA
2. Omits `version`, resolves `latest`, and verifies both public `buildkite-gha` release archives
3. Passes the plugin configuration and private paired runtime paths to the hidden `plugin` command
4. Uploads `.github/workflows/plugin-smoke.yml`
5. Runs a shell-only generated Linux job on the configured `hosted` queue

The importer lane requires Linux x86-64 Hosted Agents but no configured secrets or cache service. A compatible paired CLI release must exist before the live smoke can pass; `v0.8.0` contains the hidden command but not the Darwin archive or mixed configuration contract. Generated jobs may use configured runner queues and immutable Linux runtime images, including macOS Apple Silicon queues when the paired release supports their labels. This does not imply GitHub image, Xcode, Docker, or container parity. Cache integration is tested separately in `buildkite/buildkite-gha`.

The hook passes `BUILDKITE_PLUGIN_CONFIGURATION` through unchanged, exports the staged paths as `BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_LINUX_AMD64` and `BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_DARWIN_ARM64`, then invokes the Linux executable with the single argument `plugin`. Keep behavioral parsing and platform admission in `buildkite-gha`; the hook owns only release acquisition and private staging.

## Release

Plugin releases are Git tags and contain no generated assets. Before creating a `v0.x.y` tag, verify that:

- the latest stable CLI has a public `buildkite/buildkite-gha` release implementing the plugin configuration contract;
- that CLI release contains both `buildkite-gha_Linux_x86_64.tar.gz` and `buildkite-gha_Darwin_arm64.tar.gz` in the same `checksums.txt`;
- the live smoke passes against that release;
- the cache integration demo passes against the same plugin commit; and
- the Buildkite build for `main` passes

Workflow configuration syntax and generated-job behavior are owned, validated, and released by `buildkite-gha`. The plugin schema deliberately allows behavioral fields through unchanged; only the `version` acquisition selector is interpreted by the hook.

Push the tag after all checks pass. The Buildkite pipeline also tests tag builds.
