# Development

## Use a custom executable

Build the CLI outside the plugin, then publish it at an HTTPS URL. Use `binary` to test that build instead of an official release. Don't combine `binary` with an explicit `version`, including `version: latest`.

> [!IMPORTANT]
> Use a CLI build that supports `binary` configuration. Older CLIs reject this property.

Use a raw executable URL, not an archive, local path, or URL template. Prefer an immutable URL with a `#sha256=` fragment containing its 64-digit hexadecimal SHA256. The fragment is removed before download, and the executable bytes are verified before execution. Plain HTTPS URLs remain available for development; other fragments are rejected.

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      binary: "https://example.com/buildkite-gha-linux-amd64#sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
```

Replace the example URL and checksum with your executable's values. A single URL covers the importer platform only. For workflows that need other platforms, supply a map with the importer and each required counterpart:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      binary:
        linux/amd64: https://example.com/buildkite-gha-linux-amd64
        linux/arm64: https://example.com/buildkite-gha-linux-arm64
        darwin/arm64: https://example.com/buildkite-gha-darwin-arm64
        windows/amd64: https://example.com/buildkite-gha-windows-amd64.exe
```

Each map URL also accepts a checksum fragment. The plugin downloads only its importer executable and forwards the configuration unchanged. The companion CLI downloads and verifies counterparts only when needed, with no release fallback for a missing platform. Use matching builds across the map. Windows amd64 is a counterpart platform only.

> [!WARNING]
> Custom URLs select code that runs with the importer's authority. HTTPS protects transport, not publisher trust; a checksum pins bytes but does not establish who built them. Use trusted publishers and do not put credentials in URLs. URLs remain in pipeline configuration and may appear in errors.

`source-ref` and `minimum-release-age` are retired and fail with an error. Use `binary` to test unreleased code and an exact `version` instead of delaying `latest`.

## Binary acquisition

For custom importers, use a Linux amd64/arm64 or native macOS arm64 agent with the dependencies in [`plugin.yml`](plugin.yml) and outbound HTTPS access to GitHub. Windows importers are not supported. The importer's `agents` configuration selects its queue; `runners` mappings select generated jobs, not the importer.

The plugin caches GitHub release metadata for one hour, separately for `latest` and each exact tag. Cache hits do not extend this window, so `latest` can lag a new release by up to one hour. Expired or malformed metadata requires a successful fresh lookup; a failed refresh does not fall back to stale data. Concurrent cache misses can each make a request.

The plugin validates the release tag, selected asset URL, and SHA256 digest on cache hits and fresh responses. It prefers the platform's raw executable and verifies its bytes against that digest. For historical releases without a raw asset, it verifies the release archive's API digest and extracts only `buildkite-gha`. Invalid raw metadata or bytes fail without falling back to an archive. It does not fetch `checksums.txt`, install mise, or build Go source.

`BUILDKITE_CLEAN_CHECKOUT` values `1`, `t`, `T`, `true`, `TRUE`, and `True` force a fresh metadata lookup for that import and refresh the cache entry. False, empty, and unrecognized values do not bypass the cache. `BUILDKITE_GIT_CLEAN_FLAGS` does not affect caching. This plugin policy supplements the agent's checkout removal; it does not delete shared binary caches.

The plugin passes the resolved release to the CLI in `BUILDKITE_GHA_PLUGIN_RELEASE`. CLIs with metadata-handoff support use it for counterpart selection without another API request. Historical CLIs retain their own counterpart acquisition. Custom binaries clear this internal environment variable.

Official binaries and checksum-pinned custom binaries use a local cache keyed by platform and digest. Each invocation copies cached bytes into a private temporary directory and verifies them before execution. Missing or corrupt entries are downloaded and verified before replacing the cache entry. Plain custom URLs are downloaded each time. Custom URLs never use the release metadata cache. A warm release import makes no network requests for metadata or binaries until its metadata expires. Refreshing metadata does not download the binary again when its digest is unchanged.

Historical releases cache the verified archive by platform and archive digest, then extract the executable into the private temporary directory on each invocation. Warm imports need no archive download. Historical release assets and exact version pins remain unchanged.

The cache root is the first available setting below. Explicit paths must be absolute. If the cache cannot be written, the plugin still downloads and verifies the executable for that invocation.

| Setting | Cache root |
| --- | --- |
| `BUILDKITE_GHA_CACHE_DIR` | The specified path |
| `MISE_DATA_DIR` | `$MISE_DATA_DIR/buildkite-gha` (existing agent compatibility) |
| Writable hosted-agent cache | `/cache/bkcache/buildkite-gha` |
| `BUILDKITE_AGENT_DATA_PATH` | `$BUILDKITE_AGENT_DATA_PATH/cache/buildkite-gha` |
| `XDG_CACHE_HOME` | `$XDG_CACHE_HOME/buildkite-gha` |
| `HOME` | `$HOME/.cache/buildkite-gha` |

Cache reuse requires persistent storage shared by the relevant invocations; separate ephemeral agents do not share it automatically. Keep the cache writable only by trusted importers, isolated from untrusted jobs: cached metadata supplies the expected binary digest. The private execution directory is removed on exit.

The plugin validates acquisition properties only. All other options, including `workflow`, `workflows`, `runners`, and `oidc`, pass unchanged to the selected CLI for strict validation.

## Run local checks

Install [mise](https://mise.jdx.dev/), then run:

```bash
mise install
mise run check
```

Mise manages contributor tools only, not importer installation. The importer dependencies are listed in [`plugin.yml`](plugin.yml).

The offline Bats suite tests the plugin boundary: acquisition configuration, platform selection, HTTPS download policy, API digest verification, cache reuse and repair, release metadata handoff, unchanged CLI configuration, exit status, and temporary-file cleanup. It uses real executable hashes, a fake download transport, and a recording executable. Workflow behavior belongs in the CLI's tests, not simulated CLI implementations here. ShellCheck checks the hook; CI also runs the Buildkite plugin linter.

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
