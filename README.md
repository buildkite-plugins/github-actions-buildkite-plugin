# GitHub Actions Buildkite Plugin

Run a GitHub Actions workflow as native Buildkite steps:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.4.3:
          workflow: .github/workflows/ci.yml
```

The command step must define a `key`, which the importer uses to make generated steps depend on the upload step. The plugin downloads and verifies the public `buildkite/buildkite-gha` CLI release, then asks it to upload the workflow as a Buildkite pipeline. The plugin release tag and CLI `version` are independent. CLI `0.4.2` is the default; pin an exact pre-1.0 release explicitly when needed:

```yaml
steps:
  - key: "github-actions"
    plugins:
      - github-actions#v0.4.3:
          workflow: .github/workflows/ci.yml
          version: 0.4.2
```

## Testing unreleased CLI source

For integration testing, `buildkite-gha-source-ref` builds the CLI from the canonical public repository instead of downloading a release:

```yaml
plugins:
  - github-actions#v0.4.4:
      workflow: .github/workflows/ci.yml
      buildkite-gha-source-ref: latest
```

`latest` resolves the `buildkite/buildkite-gha` `main` branch once to a full commit, logs that commit, and builds the immutable result. A retried importer can resolve a newer commit; use the logged full lowercase 40-character commit as the value when reproducible evidence matters. Other branch names, tags, module paths, and URLs are rejected. `buildkite-gha-source-ref` and `version` are mutually exclusive.

The importer must provide a `mise` executable. For example, a repository with Go 1.26.5 in its mise config can put the pinned mise plugin before this plugin:

```yaml
plugins:
  - mise#a5845c5082d3a4fe36dd77ae74973dfc86fc91a2:
      version: "2026.5.12"
  - github-actions#v0.4.4:
      workflow: .github/workflows/ci.yml
      buildkite-gha-source-ref: latest
```

The mise plugin requires `mise.toml`, `.mise.toml`, or `.tool-versions` in the repository; it does not bootstrap from plugin configuration alone. Source mode then uses `mise --no-config` with pinned Go 1.26.5, disables CGO and Go's automatic toolchain download, and installs into a job-private temporary directory. It is intended to test unreleased CLI behaviour; it does not exercise release archives, checksums, or the stable release cache. The normal released mode remains the production and release-certification path and does not require importer-side mise.

## Private repositories

By default the generated `actions/checkout` step performs a credential-free, shallow checkout, so the workflow repository must be public. Set `private-checkout` to opt verified checkout jobs into read-only authority for the pipeline's exact GitHub repository:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.4.3:
          workflow: .github/workflows/ci.yml
          private-checkout: true
```

This requires the organization to have Buildkite's job-bound GitHub scoped access-token service enabled, and fails closed when minting is unavailable or disabled. The CLI requests fixed `contents:read` authority from the current-job Agent endpoint; the service independently requires the event repository to be the pipeline's exact GitHub repository. The credential is redacted before use and supplied only to the Git fetch through a one-shot askpass pipe.

The option is confined to the checkout adapter. It does not populate `GITHUB_TOKEN` or `github.token`, grant write access, enable private actions, or permit alternate repositories or refs. Any value other than `true` or `false` is rejected rather than resolved to a default.

## Requirements and security boundary

Only Linux x86-64 (`x86_64`/`amd64`) importer agents are supported. The plugin does not install mise; compatible CLI releases do not require it during import, while the explicit source mode requires the importer to provide it. CLI releases are fetched without a GitHub token from the hard-coded public `buildkite/buildkite-gha` repository. The release archive is cached, but every job fetches its upstream checksum, verifies a private archive copy and fixed CLI-only layout, then executes a job-private extraction. On Buildkite hosted agents, the CLI release archive uses the attached cache volume when available, then the agent data path or standard user cache directories. The hosted runtime queue is selected by the plugin and cannot be configured.

For hosted agents, request the plugin's dedicated cache volume on the importer step:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/github-actions-buildkite-plugin"
    plugins:
      - github-actions#v0.4.3:
          workflow: .github/workflows/ci.yml
```

When `/cache/bkcache` is attached and writable, the plugin automatically uses `/cache/bkcache/github-actions-buildkite-plugin` for its verified CLI archive. The cache is best-effort: a missing or unavailable hosted cache falls back to the normal agent/user cache or a temporary directory, and a cache write failure does not prevent a downloaded CLI from running. Cache contents are never trusted as authority; cached CLI archives retain upstream checksum, archive layout, and extracted version checks on every use. A miss therefore changes performance, not correctness.

For generated jobs that contain GitHub Actions, the runtime accepts mise 2026.5.12 or newer from trusted `PATH` or an explicit absolute `BUILDKITE_GHA_MISE` (including current mise 2026.8.1). If `PATH` has no mise or reports an older or malformed version, the runtime downloads the pinned official mise 2026.5.12 archive into the hosted cache and verifies both the managed archive and executable with embedded SHA-256 digests. Managed cache bytes are hash-checked without execution, copied through an open file descriptor into a job-private directory, and reverified there; only the private copy is executed. An invalid explicit `BUILDKITE_GHA_MISE` fails instead of falling back. The managed fallback remains pinned rather than following mutable `latest`. The plugin does not install or transport mise to generated jobs, and runtime agents do not need to preinstall it. Shell-only generated jobs skip mise setup entirely.

JavaScript actions run with exact Node 20.20.2 or 24.18.0 versions installed through mise's pinned core backend with configuration disabled, so the workflow repository's mise configuration cannot change the compatibility runtime. Action-bearing jobs automatically attach a dedicated Buildkite cache volume for mise-managed Node installations; the runtime digest-verifies and directly invokes the exact Node executable, reinstalling a mismatched cache entry before use. Cache misses remain correct, and shell-only jobs do not attach this runtime cache. Official mise Node binaries require glibc 2.28 or newer; shell-only workflows and the static `buildkite-gha` CLI do not.

The CLI translates and uploads the workflow; this plugin does not add a control plane or rewrite action inputs. GitHub Actions `on:` does not configure Buildkite triggers, and protected capabilities are not yet provided. Configure triggers on the Buildkite pipeline and specify the workflow file directly.

See [DEVELOPMENT.md](DEVELOPMENT.md) for local tests and the test-only cache override.

## License

MIT — see [LICENSE](LICENSE).
