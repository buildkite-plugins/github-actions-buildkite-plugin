# GitHub Actions Buildkite Plugin

Run a GitHub Actions workflow as native Buildkite steps:

```yaml
steps:
  - label: ":github: GitHub Actions"
    plugins:
      - github-actions#v0.1.0:
          workflow: .github/workflows/ci.yml
```

The plugin downloads and verifies the public `buildkite/buildkite-gha` CLI release, then asks it to upload the workflow as a Buildkite pipeline. The plugin tag (`github-actions#v0.1.0`) and CLI `version` are independent. CLI `0.1.0` is the default; pin another pre-1.0 release explicitly when needed:

```yaml
plugins:
  - github-actions#v0.1.0:
      workflow: .github/workflows/ci.yml
      version: 0.1.0
```

## Requirements and security boundary

Only Linux x86-64 (`x86_64`/`amd64`) importer agents are supported. The plugin installs mise 2026.5.12 when needed and verifies both its pinned release archive and exact cached executable tree by SHA-256. Mise uses the Buildkite hosted cache volume when one is attached, then the agent data path or standard user cache directories. CLI releases are fetched without a GitHub token from the hard-coded public `buildkite/buildkite-gha` repository, and their SHA-256 checksum and fixed CLI-only archive layout are verified before use and cached under the agent or user cache. The hosted runtime queue is selected by the plugin and cannot be configured.

JavaScript actions run with exact Node 20.20.2 or 24.18.0 versions selected through `mise --no-config`, so the workflow repository's mise configuration cannot change the compatibility runtime. The CLI transports the importer's verified mise executable to generated jobs, so the hosted queue does not need it preinstalled. Mise installs and caches the Node versions when needed. Its official Node binaries require glibc 2.28 or newer; shell-only workflows and the static `buildkite-gha` CLI do not.

The CLI translates and uploads the workflow; this plugin does not add a control plane or rewrite action inputs. GitHub Actions `on:` does not configure Buildkite triggers, and protected capabilities are not yet provided. Configure triggers on the Buildkite pipeline and specify the workflow file directly.

See [DEVELOPMENT.md](DEVELOPMENT.md) for local tests and the test-only cache override.

## License

MIT — see [LICENSE](LICENSE).
