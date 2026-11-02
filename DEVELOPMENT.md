# Development

## Run local checks

Install [mise](https://mise.jdx.dev/), then run:

```bash
mise install
mise run check
```

Mise manages contributor tools only, not importer installation. The importer dependencies are listed in [`plugin.yml`](plugin.yml).

The offline Bats suite tests the plugin boundary: acquisition configuration, platform selection, HTTPS download policy, checksum verification, safe extraction, unchanged CLI configuration, exit status, and temporary-file cleanup. It uses real tar archives and hashes, with a fake download transport and a recording executable. Workflow behavior belongs in the CLI's tests, not simulated CLI implementations here. ShellCheck checks the hook; CI also runs the Buildkite plugin linter.

## CI smoke coverage

[`.buildkite/pipeline.yml`](.buildkite/pipeline.yml) owns the live runtime pins. Every importer uses the current build's full plugin commit, including native macOS importers. The released-runtime smoke graphs cover:

- Linux default and explicit images with the dedicated `runner` user.
- A Linux-to-macOS dependency and a macOS-only graph, imported from Linux.
- The same mixed and macOS-only fixtures imported from native macOS arm64.

These checks exercise real released CLI integration on Linux x86-64 and native macOS arm64 agents. They do not exercise Windows or Linux arm64 agents, custom binaries, secrets, or a cache service. Source builds are not part of plugin acquisition or CI. Do not add manual hosted builds or releases to local checks.

## Release the plugin

Plugin releases are immutable Git tags with asset-free GitHub Releases. The release tasks require `gh` authenticated with write access to `buildkite-plugins/github-actions-buildkite-plugin`:

```bash
mise exec -- gh auth login
mise exec -- gh auth setup-git
```

Before tagging:

1. Confirm the recommended CLI has a public release and the documented behavior is shipped. Do not advertise custom-binary support until its companion CLI support ships.
1. Review the current product compatibility and security documentation.
1. Update every `github-actions#vX.Y.Z` reference in `README.md` to the plugin version being released.
1. Wait for the Buildkite build for `main` to pass, including released-runtime smokes.

From a clean, up-to-date local `main`:

```bash
mise run release:tag vX.Y.Z
```

The task runs local checks and refuses dirty, outdated, existing, or malformed releases. The tag triggers another Buildkite build. After that build passes its static checks and live smokes, publish it:

```bash
mise run release:publish vX.Y.Z
```

The publish task creates or updates the GitHub Release and moves the lightweight `latest` tag with an explicit lease. It refuses backward or divergent promotion and is safe to rerun. CI holds no release-write credential.

Stable `vX.Y.Z` plugin tags stay immutable. `github-actions#latest` follows the manually promoted plugin alias; configuration `version: latest` independently resolves the latest stable CLI release through GitHub's releases API.
