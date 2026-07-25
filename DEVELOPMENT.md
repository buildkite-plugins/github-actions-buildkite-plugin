# Development

Run `bats tests`, `shellcheck hooks/* lib/*`, and the Buildkite plugin linter before submitting changes. Tests make no live network requests. The installer also requires the standard Linux `find`, `sort`, and `mktemp` utilities at runtime.

`BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT` overrides the cache root for isolated tests only. It does not change the hard-coded release repository, asset names, or verification policy and is not a supported plugin setting.

## Release

Plugin releases are Git tags; they contain no generated assets. Before tagging,
verify that the default `buildkite-gha` version has a public GitHub release and
exercise this branch's installer against that real archive. After the Buildkite
build for `main` passes, create and push the matching `v0.x.y` tag. The
Buildkite pipeline is configured to test tag builds as well.
