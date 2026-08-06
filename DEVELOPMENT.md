# Development

Run `bats tests`, `shellcheck hooks/* lib/*`, and the Buildkite plugin linter before submitting changes. The Bats suite makes no live network requests. The plugin installs its pinned mise release and otherwise requires the standard Linux utilities listed in `plugin.yml`.

The Buildkite pipeline also runs a live service-free smoke test. Its importer pins this plugin to the build's exact `BUILDKITE_COMMIT`, omits the optional CLI `version`, downloads and verifies the real public CLI `v0.3.0` release, and uploads `.github/workflows/plugin-smoke.yml`. The generated hosted job anonymously checks out the same public commit and verifies the release-candidate defaults. This lane requires a full 40-character public GitHub commit and Linux x86-64 Hosted Agents; it does not require secrets, provider tokens, GHAC minting, or a cache service. Cache-service proof remains a separate extension in the `buildkite/buildkite-gha` demo pipeline.

`BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` overrides the cache root for isolated tests only. It does not change the hard-coded release repository, asset names, or verification policy and is not a supported plugin setting.

## Release

Plugin releases are Git tags; they contain no generated assets. Before tagging,
verify that the public `buildkite/buildkite-gha` repository has a GitHub release
for the default version and that this branch's live plugin smoke passes against
that real archive. The companion cache-extension demo must also pass against the
same exact plugin commit. After the Buildkite build for `main` passes, create
and push the matching `v0.x.y` tag. The Buildkite pipeline is configured to test
tag builds as well.
