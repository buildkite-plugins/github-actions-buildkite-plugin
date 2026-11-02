# GitHub Actions Buildkite plugin

Run supported GitHub Actions workflows as native Buildkite Pipelines jobs. The plugin downloads and launches [`buildkite-gha`](https://github.com/buildkite/buildkite-gha); the CLI selects workflows, validates behavioral configuration, and uploads the generated pipeline.

> [!NOTE]
> This integration is in public preview. See [Run GitHub Actions workflows](https://buildkite.com/docs/pipelines/migration/run-github-actions-workflows) for setup, compatibility, configuration, and security guidance. [Report issues](https://github.com/buildkite/buildkite-gha/issues) in the CLI repository.

## Add the plugin

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: github-actions
    agents:
      queue: importer-linux
    plugins:
      - github-actions#latest:
          workflow: .github/workflows/ci.yml
```

The importer's `agents` configuration selects its queue. Configure a Linux amd64/arm64 or native macOS arm64 agent; Windows importers are not supported. `runners` mappings select generated jobs, not the importer.

The importer needs Bash, `curl`, `jq`, `tar`, `mktemp`, and `sha256sum` (Linux) or `shasum` (macOS), plus outbound HTTPS access to GitHub. See the product documentation for Buildkite Agent and generated-job requirements.

The ref after `github-actions#` selects the plugin: use `github-actions#v0.14.0` for an immutable pin or `github-actions#latest` for the newest promoted stable plugin. The separate `version` property selects the CLI.

## Select the executable

| Property | Default | Description |
| --- | --- | --- |
| `version` | `latest` | Latest stable CLI release or an exact release tag, with or without `v`, including prereleases. |
| `binary` | — | HTTPS URL of a raw importer executable, or a map of platform names to executable URLs. Mutually exclusive with an explicit `version`. Requires companion CLI support; see below. |

`latest` resolves once through GitHub's releases API. The plugin downloads the selected platform's official archive and `checksums.txt` from that exact release, verifies SHA256, and extracts only the executable. It uses a private temporary directory, removes it on exit, and keeps no installer cache. It does not install mise or build Go source.

To pin a CLI release:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      version: "0.107.1"
```

`source-ref` and `minimum-release-age` are retired and fail with an error. Publish a built executable and use `binary` to test unreleased code; use an exact `version` instead of delaying `latest`.

### Use a custom executable

> [!IMPORTANT]
> `binary` requires the companion `buildkite-gha` CLI support and is not supported by existing released CLIs. Use a build containing that support; older CLIs reject this property.

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

## Configure workflow behavior

The plugin validates acquisition properties only. All other options, including `workflow`, `workflows`, `runners`, and `oidc`, pass unchanged to the selected CLI for strict validation. See the [product documentation](https://buildkite.com/docs/pipelines/migration/run-github-actions-workflows) for supported options and examples rather than assuming a newer option works with an older CLI.

> [!WARNING]
> Generated jobs can run untrusted workflow and action code. Use whole-job isolation, clean machines, and no ambient protected credentials. Review the product's security guidance before enabling private repository access, secrets, or temporary GitHub tokens.

## Development and license

See [Development](DEVELOPMENT.md) for local checks, CI coverage, and release safety. This project uses the [MIT License](LICENSE).
