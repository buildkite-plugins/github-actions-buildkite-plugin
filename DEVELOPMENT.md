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

The Buildkite pipeline's required released-default smoke test:

1. Pins the plugin to the build's full public commit SHA
2. Omits `version` and downloads and verifies the default public `buildkite-gha` release
3. Uploads `.github/workflows/plugin-smoke.yml`
4. Checks out the same commit in a generated hosted job and verifies the release defaults

This lane requires Linux x86-64 Hosted Agents, but no configured secrets, provider tokens, or cache service. Cache integration is tested separately in the `buildkite/buildkite-gha` demo pipeline.

Set `GITHUB_ACTIONS_SOURCE_REF` to `latest` or a full lowercase 40-character CLI commit on a manually created Buildkite build to run the optional source smoke instead. This lane uses the repository's `mise.toml` to install pinned mise 2026.5.12 and Go 1.26.5, pins the plugin to the build's exact commit, and exercises `buildkite-gha-source-ref` end to end. Ordinary builds continue to prove the released archive and installation path.

The smoke tests leave `private-checkout` unset so they remain service-free. Bats covers its argument wiring; the `buildkite/buildkite-gha` repository tests its runtime behavior with GHAC minting.

## Release

Plugin releases are Git tags and contain no generated assets. Before creating a `v0.x.y` tag, verify that:

- the default CLI version has a public `buildkite/buildkite-gha` release;
- the released-default smoke passes against that release;
- the cache integration demo passes against the same plugin commit; and
- the Buildkite build for `main` passes

For changes to the generated-job runtime contract, test the compatible `buildkite-gha` source with the optional source smoke before publishing the CLI release. Update the plugin's CLI default separately and pass the released-default smoke before tagging the plugin. This avoids making a release the first cross-repository test.

When changing the default CLI version, update `plugin.yml`, `hooks/command`, `.github/workflows/plugin-smoke.yml`, and the README compatibility link together.

Push the tag after all checks pass. The Buildkite pipeline also tests tag builds.
