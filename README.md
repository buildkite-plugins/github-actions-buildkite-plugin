# GitHub Actions Buildkite plugin

> [!NOTE]
> Running GitHub Actions workflows in Buildkite is currently in public preview. To report issues with the preview, [open an issue in the `buildkite-gha` repository](https://github.com/buildkite/buildkite-gha/issues). For help migrating to native Buildkite Pipelines steps, contact the [Buildkite Support team](mailto:support@buildkite.com).
>
> The plugin and runtime are under active development. Review the [`buildkite-gha` v0.8.0 compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/compatibility.md) before adding a workflow.

The GitHub Actions Buildkite plugin converts a supported [GitHub Actions workflow](https://docs.github.com/en/actions/using-workflows/about-workflows) into native [Buildkite Pipelines](https://buildkite.com/docs/pipelines) jobs without creating a GitHub Actions workflow run. This lets you start migrating a workflow before [converting it into native Buildkite Pipelines steps](https://buildkite.com/docs/pipelines/migration/from-githubactions).

During the preview, start with a workflow in a public `github.com` repository that targets Linux x86-64 and does not need secrets. Private repository checkout and temporary GitHub tokens are available in limited cases but require extra setup. Check the [supported functionality and limitations](#supported-functionality-and-limitations) before you begin.

## Add a workflow to a pipeline

Add the plugin to a keyed command step in your pipeline configuration. Set `workflow` to the path of the workflow file in your repository:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.7.1:
          workflow: ".github/workflows/ci.yml"
          version: "0.8.0"
```

When this importer step runs, the plugin uploads a dynamic pipeline. Each supported workflow job and static matrix entry becomes a Buildkite Pipelines job that depends on the importer step. The importer step must have a `key`.

For a released runtime, use the following configuration:

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Yes | — | Path to the GitHub Actions workflow in the repository. |
| `version` | No | `0.7.1` | Exact `buildkite-gha` runtime version to run. |

> [!NOTE]
> Plugin v0.7.1 uses runtime v0.7.1 by default. The examples in this README set `version` to `0.8.0` to use the newer runtime release. Plugin and runtime versions are independent. If you update the runtime version, use its matching compatibility guide.

## Migrate incrementally

Imported workflow jobs and native Buildkite Pipelines steps can run in the same build. In this example, the native `Deploy` step waits for all imported test jobs to finish:

```yaml
steps:
  - label: ":github: Tests"
    key: "github-actions-tests"
    plugins:
      - github-actions#v0.7.1:
          workflow: ".github/workflows/ci.yml"
          version: "0.8.0"

  - label: "Deploy"
    key: "deploy"
    depends_on: "github-actions-tests"
    command: ".buildkite/deploy.sh"
```

As you replace jobs with native Buildkite Pipelines steps, the remaining supported workflow jobs can keep running through the plugin.

## How the plugin works

The plugin and the `buildkite-gha` runtime work together to run the workflow:

- The plugin reads its configuration, downloads and verifies the selected `buildkite-gha` release, and starts the pipeline upload.
- `buildkite-gha` checks that the workflow is supported, converts its jobs into Buildkite Pipelines command jobs, uploads them, and runs each generated job.

You do not need to install `buildkite-gha`. The plugin downloads the Linux x86-64 runtime binary, then verifies its checksum and archive contents before running it.

Generated jobs that use JavaScript actions prepare a verified, managed `mise` installation for the supported Node.js versions. Shell-only jobs and jobs that use only native adapters or Docker do not install `mise`. The importer step does not need `mise` when it uses a released runtime.

The importer passes the runtime and compiled execution plans to generated jobs using Buildkite Pipelines artifacts. Each job verifies these files before using them. Buildkite Pipelines handles scheduling, logs, retries, cancellation, and build status.

## Requirements

The importer step needs:

- A Linux x86-64 agent.
- Buildkite agent v3.34.1 or later in the v3 release series. Agent v4 is not supported because the runtime uses the `--reject-secrets` option, which Agent v4 does not provide.
- Bash, `curl`, `tar`, `sha256sum`, `awk`, `grep`, `find`, `sed`, `sort`, `mktemp`, and `cp`, as listed in [`plugin.yml`](plugin.yml).
- Git when `BUILDKITE_COMMIT` is not already a full commit SHA.
- Outbound HTTPS access to public GitHub release and action sources.

Generated jobs need a Linux x86-64 execution environment and Buildkite agent v3.130.0 or later. They can run on [Buildkite hosted agents](https://buildkite.com/docs/agent/buildkite-hosted), the [Agent Stack for Kubernetes](https://buildkite.com/docs/agent/self-hosted/agent-stack-k8s), or other self-hosted agents that provide the tools used by the workflow. The runtime tells the agent to skip its usual repository checkout so that it can prepare the workflow workspace instead.

Depending on the workflow, generated-job hosts also need:

- `git` available on `PATH` for `actions/checkout`.
- Docker and Docker Buildx available on `PATH` for Dockerfile actions. The default Buildx builder must use the local `docker` driver.

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
          version: "0.8.0"
```

> [!WARNING]
> Generated jobs may execute untrusted workflow or action code. The selected queue must provide whole-job isolation, no ambient protected credentials, and a clean machine for each untrusted job. Persistent self-hosted agents can expose host resources and state left by earlier jobs.

## Configure generated-job runtimes

Generated jobs need network access for anything they download at runtime:

- Jobs that use public GitHub Actions need outbound HTTPS access to `codeload.github.com`, where the runtime downloads each action's source archive.
- Jobs that use JavaScript actions need outbound HTTPS access to the managed Node.js and `mise` downloads. Actions that declare `node16` run on managed Node 16.20.2 and produce a deprecation warning. Actions that declare `node20` or `node24` run on managed Node 24.18.0. Managed Node binaries require glibc 2.28 or newer. Shell-only workflows do not have this glibc requirement.

When resolving a mutable tag or branch for a public action, the importer uses an available job-scoped GitHub token only for the GitHub API request. If it cannot obtain or register the token, it reports a warning and retries anonymously. A lowercase, full 40-character commit SHA does not require an API request. The importer and generated jobs download the resolved action archive anonymously from `codeload.github.com`.

`BUILDKITE_GHA_RUNTIME_IMAGE` is supported only when generated jobs run on Buildkite hosted agents or Agent Stack for Kubernetes controller v0.30.0 or later. Set the variable on the importer step to the immutable digest of a toolchain-enabled image that provides `/opt/hostedtoolcache`. The runtime rejects tags and other mutable image references. Do not set this variable for other self-hosted agent environments because they cannot provision the generated job image.

## Configure triggers and GitHub context

Buildkite Pipelines controls when builds run. Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on` key does not create Buildkite Pipelines triggers.

For manual and scheduled builds, the plugin finds the exact commit from the checked-out repository when `BUILDKITE_COMMIT` does not already contain a full commit SHA.

Pull request builds receive `pull_request` context. Branch, tag, scheduled, and manual builds receive `push` context. Scheduled and manual builds work only with workflows that can run with `push` event data because the runtime does not provide `schedule`, `workflow_dispatch`, or dispatch inputs.

## Configure checkout and credentials

Supported, audited `actions/checkout` revisions can check out the exact event repository and commit from `github.com`. Checkout runs anonymously when repository-provider credentials are not enabled. Private checkout uses Buildkite repository-provider Git credentials when they are enabled and authorized for the job.

Checkout credentials do not populate `GITHUB_TOKEN` or `github.token`, enable private actions, or allow alternate repositories or refs. A workflow can receive a temporary GitHub token only when it makes a supported static token reference and the Buildkite organization has enabled the job-bound token service. When the workflow omits `permissions`, the runtime requests the narrow `contents: read` default. The compatibility guide describes the [complete credential boundary](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/compatibility.md#repositories-credentials-and-github-services).

> [!WARNING]
> The job-bound token service does not determine whether a fork or actor is trusted. If a pull request can change an imported workflow, that workflow can request any repository permission enabled by the service. Do not allow untrusted workflow changes to receive write permissions.

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
          version: "0.8.0"
```

Without this volume, the plugin uses an agent or user cache when one is available, then falls back to a temporary directory. The plugin verifies cached archives before using them. Cache misses affect performance, not correctness. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Supported functionality and limitations

The public preview supports an evolving subset of GitHub Actions. Common supported features include:

- Linux x86-64 jobs using `ubuntu-latest`, `ubuntu-24.04`, or `ubuntu-22.04`. These labels identify a compatible runner but do not provide the same tools or image layout as a GitHub-hosted runner.
- Bash and `sh` run steps.
- Static job dependencies and matrices, including `include` and `exclude`, up to 256 expanded instances per job.
- Supported job and step conditions, outputs, timeouts, and step-level `continue-on-error` behavior.
- Public JavaScript, composite, local, and compiler-verified Dockerfile actions.
- Local reusable workflows with statically resolvable inputs.
- Supported, audited revisions of `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`, and `actions/cache`.

Important limitations include:

- General workflow secrets, ambient `GITHUB_TOKEN`, private actions, private reusable workflows, alternate-repository or alternate-ref checkout, and GitHub-compatible OIDC are not available.
- Windows, macOS, and Linux arm64 jobs are not supported.
- Job and service containers are not available through the production plugin path.
- Dynamic matrices and remote reusable workflows are not supported.
- The runtime accepts `strategy.fail-fast` but does not enforce it, so a failed matrix job does not cancel the other matrix jobs.
- The complete `github.event` payload and GitHub-specific event behavior are not available at runtime.
- Unaudited revisions of actions with native support are rejected.

If a feature is not listed in the [`buildkite-gha` v0.8.0 compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/compatibility.md), treat it as unsupported.

> [!WARNING]
> All steps in an imported job share a workspace, environment changes, processes, and action lifecycle. Docker actions provide packaging, not a security boundary. Review the [`buildkite-gha` v0.8.0 security model](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/security.md) before running untrusted workflow code.

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

The mise plugin requires a mise configuration in the repository. Source mode does not test release archives, checksums, or caching. Released mode remains unchanged. The `main` branch can contain behavior that is not part of runtime v0.8.0, so do not use the v0.8.0 compatibility guide to describe an unreleased source commit.

## Develop the plugin

See the [development guide](DEVELOPMENT.md) for local tests, CI smoke tests, and release instructions.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
