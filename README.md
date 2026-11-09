# GitHub Actions Buildkite plugin

Run supported GitHub Actions workflows as native Buildkite Pipelines jobs using [`buildkite-gha`](https://github.com/buildkite/buildkite-gha).

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

Leave `version` unset unless you need to pin a CLI release. By default, the plugin uses the latest stable CLI release.

The importer's `agents` configuration selects its queue. Configure a Linux amd64/arm64 or native macOS arm64 agent; Windows importers are not supported. `runners` mappings select generated jobs, not the importer.

The importer needs Bash, `curl`, `jq`, `tar`, `mktemp`, and `sha256sum` (Linux) or `shasum` (macOS), plus outbound HTTPS access to GitHub. See the product documentation for Buildkite Agent and generated-job requirements.

## Pin a release when needed

The ref after `github-actions#` selects the plugin: `github-actions#latest` follows the newest promoted stable plugin; an exact tag such as `github-actions#v0.14.0` pins the plugin. The separate `version` property pins the CLI:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      version: "0.107.1"
```

`version` accepts `latest` or an exact release tag, with or without `v`, including prereleases. Remove `version` to resume following stable CLI releases.

## Configure workflow behavior

See the [product documentation](https://buildkite.com/docs/pipelines/migration/run-github-actions-workflows) for workflow selection, runner mappings, OIDC, and supported options. If you pin an older CLI, check that it supports the options you use.

> [!WARNING]
> Generated jobs can run untrusted workflow and action code. Use whole-job isolation, clean machines, and no ambient protected credentials. Review the product's security guidance before enabling private repository access, secrets, or temporary GitHub tokens.

## Development and license

For testing unreleased builds, see [Use a custom executable](DEVELOPMENT.md#use-a-custom-executable). [Development](DEVELOPMENT.md) also covers local checks, CI coverage, and release safety. This project uses the [MIT License](LICENSE).
