# GitHub Actions Buildkite plugin

Run supported GitHub Actions workflows as native Buildkite Pipelines jobs using [`buildkite-gha`](https://github.com/buildkite/buildkite-gha).

> [!NOTE]
> This integration is in public preview. See [Run GitHub Actions workflows](https://buildkite.com/docs/pipelines/migration/run-github-actions-workflows) for setup, compatibility, configuration, and security guidance. [Report issues](https://github.com/buildkite/buildkite-gha/issues) in the CLI repository.

## Usage

[Create a Buildkite pipeline connected to your GitHub repository](https://buildkite.com/docs/pipelines/migration/run-github-actions-workflows#add-a-github-actions-workflow-to-a-pipeline-create-a-github-actions-pipeline) and your builds will automatically use this plugin to run supported workflows unchanged on Buildkite.

Your new pipeline will have steps like:

```yaml
steps:
  - label: ":github: GitHub Actions"
    plugin: github-actions
```

> You can add optional configuration if needed.

## Configuration

You can pin the plugin with an exact tag and the `buildkite-gha` runtime with `version`:

```yaml
steps:
  - label: ":github: GitHub Actions"
    plugin:
      github-actions#v0.15.0:
        version: v0.124.0
```

We recommend omitting both pins to follow the latest stable versions, especially during the preview. `version` also accepts `latest` or an exact release tag without the `v` prefix, including prereleases.

Additional plugin configuration is passed to [the `buildkite-gha` runtime](https://github.com/buildkite/buildkite-gha). See [the documentation](https://buildkite.com/docs/pipelines/migration/run-github-actions-workflows) for supported options. If you pin an older runtime, check that it supports the options you use.

> [!WARNING]
> Generated jobs can run untrusted workflow and action code. Use whole-job isolation, clean machines, and no ambient protected credentials. Review the product's security guidance before enabling private repository access, secrets, or temporary GitHub tokens.

## Development and license

For testing unreleased builds, see [Use a custom executable](DEVELOPMENT.md#use-a-custom-executable). [Development](DEVELOPMENT.md) also covers local checks, CI coverage, and release safety. This project uses the [MIT License](LICENSE).
