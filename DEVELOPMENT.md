# Development

Run `bats tests`, `shellcheck hooks/* lib/*`, and the Buildkite plugin linter before submitting changes. The Bats suite makes no live network requests. The importer requires the standard Linux utilities listed in `plugin.yml`. For generated jobs containing actions, compatible CLI releases reuse trusted mise 2026.5.12 or newer and otherwise install the verified, pinned 2026.5.12 fallback; shell-only jobs skip that setup.

The Buildkite pipeline also runs a live service-free smoke test. Its importer pins this plugin to the build's exact `BUILDKITE_COMMIT`, omits the optional CLI `version`, downloads and verifies the real public CLI `v0.4.2` release, and uploads `.github/workflows/plugin-smoke.yml`. The generated hosted job anonymously checks out the same public commit and verifies the release-candidate defaults. This lane requires a full 40-character public GitHub commit and Linux x86-64 Hosted Agents; it does not require secrets, provider tokens, GHAC minting, or a cache service. Cache-service proof remains a separate extension in the `buildkite/buildkite-gha` demo pipeline.

Set `GITHUB_ACTIONS_SOURCE_REF` to `latest` or a full lowercase 40-character CLI commit on a manually created Buildkite build to add the live source smoke. That lane uses the repository's `mise.toml` to install pinned mise 2026.5.12 and Go 1.26.5 on the importer, pins this plugin to the build's exact commit, and exercises `buildkite-gha-source-ref` end to end. It remains separate from the required released-default lane, which continues to prove release packaging and installation.

The smoke lane deliberately leaves `private-checkout` unset, so it stays service-free. The option's argument wiring is covered by Bats; its runtime behaviour depends on GHAC minting and is proven in the `buildkite/buildkite-gha` repository rather than here.

`BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` overrides the cache root for isolated tests only. It does not change the hard-coded release repository, asset names, or verification policy and is not a supported plugin setting.

## Release

Plugin releases are Git tags; they contain no generated assets. Before tagging,
verify that the public `buildkite/buildkite-gha` repository has a GitHub release
for the default version and that this branch's live plugin smoke passes against
that real archive. The companion cache-extension demo must also pass against the
same exact plugin commit. After the Buildkite build for `main` passes, create
and push the matching `v0.x.y` tag. The Buildkite pipeline is configured to test
tag builds as well.

For changes to the generated-job runtime contract, publish the compatible
`buildkite-gha` source through the optional source smoke before release. Publish
the compatible CLI release only after that candidate lane passes, then update
the plugin's CLI default in a separate change and pass the released-default
smoke before tagging the plugin. This keeps an unreleased CLI version out of the
plugin defaults without making a release the first cross-repository test.
