# Development

Run `bats tests`, `shellcheck hooks/* lib/*`, and the Buildkite plugin linter before submitting changes. Tests make no live network requests.

`BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` overrides the cache root for isolated tests only. It does not change the hard-coded release repository, asset names, or verification policy and is not a supported plugin setting.
