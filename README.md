# GitHub Actions Buildkite Plugin

Run a GitHub Actions workflow as native Buildkite steps:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.4.1:
          workflow: .github/workflows/ci.yml
```

The command step must define a `key`, which the importer uses to make generated steps depend on the upload step. The plugin downloads and verifies the public `buildkite/buildkite-gha` CLI release, then asks it to upload the workflow as a Buildkite pipeline. The plugin release tag and CLI `version` are independent. CLI `0.4.1` is the default; pin an exact pre-1.0 release explicitly when needed:

```yaml
steps:
  - key: "github-actions"
    plugins:
      - github-actions#v0.4.1:
          workflow: .github/workflows/ci.yml
          version: 0.4.1
```

## Requirements and security boundary

Only Linux x86-64 (`x86_64`/`amd64`) importer agents are supported. The importer does not require mise. CLI releases are fetched without a GitHub token from the hard-coded public `buildkite/buildkite-gha` repository. The release archive is cached, but every job fetches its upstream checksum, verifies a private archive copy and fixed CLI-only layout, then executes a job-private extraction. On Buildkite hosted agents, the CLI release archive uses the attached cache volume when available, then the agent data path or standard user cache directories. The hosted runtime queue is selected by the plugin and cannot be configured.

For hosted agents, request the plugin's dedicated cache volume on the importer step:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/github-actions-buildkite-plugin"
    plugins:
      - github-actions#v0.4.1:
          workflow: .github/workflows/ci.yml
```

When `/cache/bkcache` is attached and writable, the plugin automatically uses `/cache/bkcache/github-actions-buildkite-plugin` for its verified CLI archive. The cache is best-effort: a missing or unavailable hosted cache falls back to the normal agent/user cache or a temporary directory, and a cache write failure does not prevent a downloaded CLI from running. Cache contents are never trusted as authority; cached CLI archives retain upstream checksum, archive layout, and extracted version checks on every use. A miss therefore changes performance, not correctness.

Generated jobs that contain GitHub Actions require exact mise 2026.5.12 in the selected runtime queue or image. It must be available on `PATH`, or `BUILDKITE_GHA_MISE` must name its absolute executable path. The plugin does not install or transport mise to generated jobs. Shell-only generated jobs do not require mise.

JavaScript actions run with exact Node 20.20.2 or 24.18.0 versions installed through mise's pinned core backend with configuration disabled, so the workflow repository's mise configuration cannot change the compatibility runtime. Action-bearing jobs automatically attach a dedicated Buildkite cache volume for mise-managed Node installations; the runtime digest-verifies and directly invokes the exact Node executable, reinstalling a mismatched cache entry before use. Cache misses remain correct, and shell-only jobs do not attach this runtime cache. Official mise Node binaries require glibc 2.28 or newer; shell-only workflows and the static `buildkite-gha` CLI do not.

The CLI translates and uploads the workflow; this plugin does not add a control plane or rewrite action inputs. GitHub Actions `on:` does not configure Buildkite triggers, and protected capabilities are not yet provided. Configure triggers on the Buildkite pipeline and specify the workflow file directly.

See [DEVELOPMENT.md](DEVELOPMENT.md) for local tests and the test-only cache override.

## License

MIT — see [LICENSE](LICENSE).
