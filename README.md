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

Only Linux x86-64 (`x86_64`/`amd64`) agents are supported. Releases are fetched without a GitHub token from the hard-coded public `buildkite/buildkite-gha` repository, and their SHA-256 checksum and fixed archive layout are verified before use. The hosted security queue is selected by the plugin and cannot be configured.

The CLI translates and uploads the workflow; this plugin does not add control-plane or cache behavior and does not rewrite action inputs. Workflow discovery, GitHub trigger filtering, and protected capabilities are not yet provided. Specify the workflow file directly.

See [DEVELOPMENT.md](DEVELOPMENT.md) for local tests and the test-only cache override.

## License

MIT — see [LICENSE](LICENSE).
