# GitHub Actions Buildkite plugin

> [!NOTE]
> Running GitHub Actions workflows in Buildkite is currently in research preview. To provide feedback or report issues, contact the Buildkite Support team at [support@buildkite.com](mailto:support@buildkite.com).

The GitHub Actions Buildkite plugin gives you a quick way to get a supported GitHub Actions workflow running in Buildkite with minimal changes, without first rewriting it as a native Buildkite pipeline. Once the workflow is up and running, you can [convert it into native Buildkite Pipelines steps](https://buildkite.com/docs/pipelines/migration/from-githubactions) to take full advantage of Buildkite Pipelines features.

During the preview, the quickest way to get started is with a Linux x86-64 workflow in a public `github.com` repository that doesn't need secrets. Private repository checkout and temporary GitHub tokens are available in limited cases, but require extra setup. Review the [supported functionality and limitations](https://github.com/buildkite/buildkite-gha/blob/v0.7.2/docs/compatibility.md) before you begin.

## Add a workflow to a pipeline

Add the plugin to a keyed command step in your pipeline configuration. Set `workflow` to the path of the workflow file in your repository:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.7.1:
          workflow: ".github/workflows/ci.yml"
          version: "0.7.2"
```

When this step runs, the plugin turns the workflow jobs into a dynamic pipeline. Each generated job depends on the plugin step, so Buildkite Pipelines waits for the plugin to finish before running them.

For a released runtime, use the following configuration:

| Option | Required | Description |
| --- | --- | --- |
| `workflow` | Yes | Path to the GitHub Actions workflow in the repository. |
| `version` | No | Exact `buildkite-gha` runtime version to run. When omitted, the plugin uses its default runtime version. |

> [!NOTE]
> Plugin v0.7.1 uses runtime 0.7.1 by default. The examples in this README set `version` to `0.7.2` to use the newer runtime release.

## How the plugin works

The plugin and the `buildkite-gha` runtime work together to run the workflow:

- The plugin reads the configuration, downloads and verifies the selected `buildkite-gha` release, and starts the pipeline upload.
- `buildkite-gha` checks that the workflow is supported, turns its jobs into Buildkite Pipelines command jobs, and uploads them.

You don't need to install `buildkite-gha`. The plugin downloads the Linux x86-64 runtime binary, then verifies its checksum and archive contents before running it.

Generated jobs that use JavaScript actions prepare a verified, managed `mise` installation for the supported Node.js versions. Shell-only jobs and jobs that use only native adapters or Docker don't install `mise`. The importer step doesn't need `mise` when it uses a released runtime.

## Requirements

The importer step needs:

- A Linux x86-64 agent.
- Buildkite agent v3.34.1 or later in the v3 release series. Agent v4 isn't supported because the runtime uses the `--reject-secrets` option, which Agent v4 doesn't provide.
- The command-line tools listed in [`plugin.yml`](plugin.yml).
- Git when `BUILDKITE_COMMIT` isn't already a full commit SHA.
- Outbound HTTPS access to the public GitHub release.

Generated jobs need Buildkite agent v3.130.0 or later. The runtime tells the agent to skip its usual repository checkout so that it can prepare the workflow workspace instead.

Jobs that use public GitHub Actions need outbound HTTPS access to `codeload.github.com`. Jobs that use JavaScript actions also need access to the managed Node.js and `mise` downloads. See the compatibility guide for the complete network requirements.

Generated jobs use the pipeline or organization default agents unless you choose a queue. To send every generated job to a specific queue, set `BUILDKITE_GHA_TARGET_QUEUE` on the importer step:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    env:
      BUILDKITE_GHA_TARGET_QUEUE: "gha-preview"
    plugins:
      - github-actions#v0.7.1:
          workflow: ".github/workflows/ci.yml"
          version: "0.7.2"
```

Use agents that isolate each job and don't provide ambient credentials because the queue can run untrusted workflow code.

## Triggers and GitHub context

Buildkite Pipelines controls when builds run. Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on` key doesn't create Buildkite Pipelines triggers.

Pull request builds receive `pull_request` context. Branch, tag, scheduled, and manual builds receive `push` context. Scheduled and manual builds work only with workflows that can run with `push` event data because the runtime doesn't provide `schedule`, `workflow_dispatch`, or dispatch inputs.

## Checkout and credentials

Supported `actions/checkout` steps can check out the exact event repository and commit from `github.com`. Checkout runs anonymously when repository-provider credentials aren't enabled. Private checkout uses Buildkite repository-provider Git credentials when they are enabled and authorized for the job.

Checkout credentials don't populate `GITHUB_TOKEN` or `github.token`, enable private actions, or allow alternate repositories or refs. A workflow can receive a temporary GitHub token only when it makes a supported static token reference and the Buildkite organization has enabled the job-bound token service. When the workflow omits `permissions`, the runtime requests the narrow `contents: read` default. The [compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.7.2/docs/compatibility.md) describes the full credential boundary.

## Cache the runtime download

On Buildkite hosted agents, attach the plugin cache volume to speed up the importer:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/github-actions-buildkite-plugin"
    plugins:
      - github-actions#v0.7.1:
          workflow: ".github/workflows/ci.yml"
          version: "0.7.2"
```

Without this volume, the plugin uses an agent or user cache when one is available, then falls back to a temporary directory. The plugin verifies cached archives before using them. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Test unreleased runtime source

The `buildkite-gha-source-ref` option is for integration testing. It runs the runtime from the public source repository instead of downloading a release. The importer must provide `mise`:

```yaml
plugins:
  - mise#a5845c5082d3a4fe36dd77ae74973dfc86fc91a2:
      version: "2026.5.12"
  - github-actions#v0.7.1:
      workflow: ".github/workflows/ci.yml"
      buildkite-gha-source-ref: latest
```

`latest` resolves the `buildkite/buildkite-gha` `main` branch once, logs the full commit, and runs that immutable commit with `mise --no-config` and Go 1.26.5. Use the logged commit instead of `latest` for reproducible retries. You can also set `buildkite-gha-source-ref` to a full lowercase 40-character commit. The `version` and `buildkite-gha-source-ref` options are mutually exclusive.

Source mode doesn't test release archives, checksums, or caching. Released mode remains unchanged.

The mise plugin requires a mise configuration in the repository.

See [DEVELOPMENT.md](DEVELOPMENT.md) for testing and release instructions.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
