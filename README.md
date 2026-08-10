# GitHub Actions Buildkite plugin

> [!NOTE]
> Running GitHub Actions workflows in Buildkite is currently in research preview. To provide feedback or report issues, contact the [Buildkite Support team](mailto:support@buildkite.com).

The GitHub Actions Buildkite plugin converts a supported [GitHub Actions workflow](https://docs.github.com/en/actions/using-workflows/about-workflows) into native [Buildkite Pipelines](https://buildkite.com/docs/pipelines) jobs without creating a GitHub Actions workflow run. This lets you start migrating a workflow before [converting it into native Buildkite Pipelines steps](https://buildkite.com/docs/pipelines/migration/from-githubactions).

During the preview, start with a workflow in a public `github.com` repository that targets Linux x86-64 and does not need secrets. Private repository checkout and temporary GitHub tokens are available in limited cases but require extra setup. Review the [`buildkite-gha` v0.7.2 compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.7.2/docs/compatibility.md) before you begin.

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

When this importer step runs, the plugin uploads a dynamic pipeline. Each supported workflow job and static matrix entry becomes a Buildkite Pipelines job that depends on the importer step. The importer step must have a `key`.

For a released runtime, use the following configuration:

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Yes | — | Path to the GitHub Actions workflow in the repository. |
| `version` | No | `0.7.1` | Exact `buildkite-gha` runtime version to run. |

> [!NOTE]
> Plugin v0.7.1 uses runtime v0.7.1 by default. The examples in this README set `version` to `0.7.2` to use the newer runtime release. Plugin and runtime versions are independent.

## How the plugin works

The plugin and the `buildkite-gha` runtime work together to run the workflow:

- The plugin reads its configuration, downloads and verifies the selected `buildkite-gha` release, and starts the pipeline upload.
- `buildkite-gha` checks that the workflow is supported, converts its jobs into Buildkite Pipelines command jobs, and uploads them.

You do not need to install `buildkite-gha`. The plugin downloads the Linux x86-64 runtime binary, then verifies its checksum and archive contents before running it.

Generated jobs that use JavaScript actions prepare a verified, managed `mise` installation for the supported Node.js versions. Shell-only jobs and jobs that use only native adapters or Docker do not install `mise`. The importer step does not need `mise` when it uses a released runtime.

## Requirements

The importer step needs:

- A Linux x86-64 agent.
- Buildkite agent v3.34.1 or later in the v3 release series. Agent v4 is not supported because the runtime uses the `--reject-secrets` option, which Agent v4 does not provide.
- The command-line tools listed in [`plugin.yml`](plugin.yml).
- Git when `BUILDKITE_COMMIT` is not already a full commit SHA.
- Outbound HTTPS access to the public GitHub release.

Generated jobs need Buildkite agent v3.130.0 or later and an environment that meets the [runtime compatibility requirements](https://github.com/buildkite/buildkite-gha/blob/v0.7.2/docs/compatibility.md#repositories-credentials-and-platforms). The runtime tells the agent to skip its usual repository checkout so that it can prepare the workflow workspace instead.

Jobs that use JavaScript actions require glibc 2.28 or later. Jobs that use public GitHub Actions need outbound HTTPS access to `codeload.github.com`. Jobs that use JavaScript actions also need access to the managed Node.js and `mise` downloads. See the compatibility guide for the complete network requirements.

## Select a queue

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

> [!WARNING]
> Generated jobs may execute untrusted workflow or action code. Use agents that isolate each job and do not provide ambient credentials.

## Configure triggers and GitHub context

Buildkite Pipelines controls when builds run. Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on` key does not create Buildkite Pipelines triggers.

Pull request builds receive `pull_request` context. Branch, tag, scheduled, and manual builds receive `push` context. Scheduled and manual builds work only with workflows that can run with `push` event data because the runtime does not provide `schedule`, `workflow_dispatch`, or dispatch inputs.

## Configure checkout and credentials

Supported `actions/checkout` steps can check out the exact event repository and commit from `github.com`. Checkout runs anonymously when repository-provider credentials are not enabled. Private checkout uses Buildkite repository-provider Git credentials when they are enabled and authorized for the job.

Checkout credentials do not populate `GITHUB_TOKEN` or `github.token`, enable private actions, or allow alternate repositories or refs. A workflow can receive a temporary GitHub token only when it makes a supported static token reference and the Buildkite organization has enabled the job-bound token service. When the workflow omits `permissions`, the runtime requests the narrow `contents: read` default. The compatibility guide describes the [complete credential boundary](https://github.com/buildkite/buildkite-gha/blob/v0.7.2/docs/compatibility.md#repositories-credentials-and-platforms).

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

Without this volume, the plugin uses an agent or user cache when one is available, then falls back to a temporary directory. The plugin verifies cached archives before using them. Cache misses affect performance, not correctness. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Test unreleased runtime source

> [!WARNING]
> Use `buildkite-gha-source-ref` only for integration testing. It runs code from the public runtime source repository instead of a verified release archive.

The importer must provide `mise` when it runs runtime source:

```yaml
plugins:
  - mise#a5845c5082d3a4fe36dd77ae74973dfc86fc91a2:
      version: "2026.5.12"
  - github-actions#v0.7.1:
      workflow: ".github/workflows/ci.yml"
      buildkite-gha-source-ref: "latest"
```

`latest` resolves the `buildkite/buildkite-gha` `main` branch once, logs the full commit SHA, and runs that immutable commit with `mise --no-config` and Go 1.26.5. Use the logged commit instead of `latest` for reproducible retries. You can also set `buildkite-gha-source-ref` to a full lowercase 40-character commit SHA. The `version` and `buildkite-gha-source-ref` options are mutually exclusive.

The mise plugin requires a mise configuration in the repository. Source mode does not test release archives, checksums, or caching. Released mode remains unchanged.

## Develop the plugin

See the [development guide](DEVELOPMENT.md) for local tests, CI smoke tests, and release instructions.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
