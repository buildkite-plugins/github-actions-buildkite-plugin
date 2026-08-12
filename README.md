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
      - github-actions#v0.8.0:
          workflow: ".github/workflows/ci.yml"
```

When this importer step runs, the plugin uploads a dynamic pipeline. Each supported workflow job and static matrix entry becomes a Buildkite Pipelines job that depends on the importer step. The importer step must have a `key`.

Configure runtime selection with the following properties:

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Yes | — | Path to the GitHub Actions workflow in the repository. |
| `version` | No | `latest` | Latest stable or an exact `buildkite-gha` release from `0.8.0` onward. |
| `source-ref` | No | — | Full `buildkite-gha` source commit to build for development testing; mutually exclusive with `version`. |
| `minimum-release-age` | No | `0s` | Minimum release age used by mise when resolving `latest`. |
| `runners` | No | — | Exact `runs-on` mappings to Buildkite queues and optional immutable Linux image overrides. |

> [!NOTE]
> Plugin and runtime versions are independent. Pin `version` to keep release-version selection stable, or use `latest` to follow stable runtime releases. Increase `minimum-release-age` (for example, to `24h`) to delay newly published releases. If you update the runtime version, use its matching compatibility guide.

To test unreleased runtime behavior, set `source-ref` to a full lowercase 40-character commit from the public `buildkite/buildkite-gha` repository and omit `version`. The plugin uses mise and Go 1.26.5 to build that source before running `buildkite-gha plugin`. Source commits are for development only and do not use release checksums, attestations, or `minimum-release-age`.

The plugin validates only the runtime-acquisition fields `version`, `source-ref`, and `minimum-release-age`. It passes all behavioral configuration through to the selected `buildkite-gha` runtime, which validates the complete configuration strictly. This allows runtime releases to extend the supported syntax without requiring a companion plugin release.

## Migrate incrementally

Imported workflow jobs and native Buildkite Pipelines steps can run in the same build. In this example, the native `Deploy` step waits for all imported test jobs to finish:

```yaml
steps:
  - label: ":github: Tests"
    key: "github-actions-tests"
    plugins:
      - github-actions#v0.8.0:
          workflow: ".github/workflows/ci.yml"

  - label: "Deploy"
    key: "deploy"
    depends_on: "github-actions-tests"
    command: ".buildkite/deploy.sh"
```

As you replace jobs with native Buildkite Pipelines steps, the remaining supported workflow jobs can keep running through the plugin.

## How the plugin works

The plugin and the `buildkite-gha` runtime work together to run the workflow:

- The plugin uses an existing compatible `mise`, or installs a pinned verified copy, then asks mise to select and run the configured `buildkite-gha` release or source commit.
- The hidden `buildkite-gha plugin` command reads the plugin configuration, checks that the workflow is supported, converts its jobs into Buildkite Pipelines command jobs, uploads them, and runs each generated job.

You do not need to install `mise` or `buildkite-gha`. Mise verifies the selected Linux x86-64 importer release when installing it, then caches the installation before running it. When a compiled workflow requires macOS, that exact importer release verifies and stages its paired Darwin arm64 runtime; Linux-only workflows do not acquire it.

Generated jobs that use JavaScript actions also prepare a verified, managed `mise` installation for the supported Node.js versions. Shell-only generated jobs and jobs that use only native adapters or Docker do not install `mise`.

The importer passes the runtime and compiled execution plans to generated jobs using Buildkite Pipelines artifacts. Each job verifies these files before using them. Buildkite Pipelines handles scheduling, logs, retries, cancellation, and build status.

## Requirements

The importer step needs:

- A Linux x86-64 agent.
- Buildkite agent v3.34.1 or later in the v3 release series. Agent v4 is not supported because the runtime uses the `--reject-secrets` option, which Agent v4 does not provide.
- Bash, `curl`, `tar`, `sha256sum`, `mktemp`, and `cp`, as listed in [`plugin.yml`](plugin.yml). The download tools are used only when a compatible `mise` is not already on `PATH`.
- Git when `BUILDKITE_COMMIT` is not already a full commit SHA.
- Outbound HTTPS access to public GitHub release and action sources.

Generated jobs need Buildkite agent v3.130.0 or later and an execution environment matching their runner mapping. Linux x86-64 jobs can run on [Buildkite hosted agents](https://buildkite.com/docs/agent/buildkite-hosted), the [Agent Stack for Kubernetes](https://buildkite.com/docs/agent/self-hosted/agent-stack-k8s), or other self-hosted agents that provide the workflow's tools. Supported macOS labels require a native Darwin arm64 queue. The runtime tells the agent to skip its usual repository checkout so that it can prepare the workflow workspace instead.

Depending on the workflow, generated-job hosts also need:

- `git` available on `PATH` for `actions/checkout`.
- Docker and Docker Buildx available on `PATH` for Dockerfile actions. The default Buildx builder must use the local `docker` driver.

## Map runner labels to queues and images

Use `runners` to map an exact GitHub `runs-on` label to a Buildkite queue. Configured `ubuntu-latest` and `ubuntu-24.04` profiles use the Noble hosted-toolchains image by default; `ubuntu-22.04` uses Jammy. A Linux mapping may override that default with another digest-pinned image:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.8.0:
          workflow: ".github/workflows/ci.yml"
          runners:
            - runs-on: ubuntu-latest
              queue: hosted
              image: buildkite.namespace-images.com/agent-base@sha256:04a6656f92b90269b3259fffaba67e08a3d03d8dc79b40d45c9ac3d9000e9e03
            - runs-on: macos-14
              queue: macos-sonoma-arm64
```

`runs-on` is matched after static expressions and matrices are resolved. An explicit `image` applies only to the matching Linux label, must be an immutable `@sha256:` reference, and replaces the label's hosted-toolchains default. macOS mappings select a native queue and cannot specify an image. Duplicate labels, unsupported labels, malformed queues or images, and conflicting multi-label targets fail admission. Unmapped supported Linux labels retain default Buildkite agent targeting without an image; unmapped macOS labels fail rather than falling back to a Linux queue.

> [!WARNING]
> Generated jobs may execute untrusted workflow or action code. The selected queue must provide whole-job isolation, no ambient protected credentials, and a clean machine for each untrusted job. Persistent self-hosted agents can expose host resources and state left by earlier jobs.

## Configure generated-job runtimes

Generated jobs need network access for anything they download at runtime:

- Jobs that use public GitHub Actions need outbound HTTPS access to `codeload.github.com`, where the runtime downloads each action's source archive.
- Jobs that use JavaScript actions need outbound HTTPS access to the managed Node.js and `mise` downloads. Actions that declare `node16` run on managed Node 16.20.2 and produce a deprecation warning. Actions that declare `node20` or `node24` run on managed Node 24.18.0. Managed Node binaries require glibc 2.28 or newer. Shell-only workflows do not have this glibc requirement.

When resolving a mutable tag or branch for a public action, the importer uses an available job-scoped GitHub token only for the GitHub API request. If it cannot obtain or register the token, it reports a warning and retries anonymously. A lowercase, full 40-character commit SHA does not require an API request. The importer and generated jobs download the resolved action archive anonymously from `codeload.github.com`.

Configured Linux profiles select an immutable hosted-toolchains image and enable its `/opt/hostedtoolcache`. An explicit `runners[].image` override must provide the same tool-cache path and is supported only when the matching jobs run on Buildkite hosted agents or Agent Stack for Kubernetes controller v0.30.0 or later. Do not configure Linux profiles for other self-hosted environments that cannot provision the generated job image. macOS profiles never select an image.

## Configure triggers and GitHub context

Buildkite Pipelines controls when builds run. Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on` key does not create Buildkite Pipelines triggers.

For manual and scheduled builds, the plugin finds the exact commit from the checked-out repository when `BUILDKITE_COMMIT` does not already contain a full commit SHA.

Pull request builds receive `pull_request` context. Branch, tag, scheduled, and manual builds receive `push` context. Scheduled and manual builds work only with workflows that can run with `push` event data because the runtime does not provide `schedule`, `workflow_dispatch`, or dispatch inputs.

## Configure checkout and credentials

Supported, audited `actions/checkout` revisions can check out the exact event repository and commit from `github.com`. Checkout runs anonymously when repository-provider credentials are not enabled. Private checkout uses Buildkite repository-provider Git credentials when they are enabled and authorized for the job.

Checkout credentials do not populate `GITHUB_TOKEN` or `github.token`, enable private actions, or allow alternate repositories or refs. A workflow can receive a temporary GitHub token only when it makes a supported static token reference and the Buildkite organization has enabled the job-bound token service. When the workflow omits `permissions`, the runtime requests the narrow `contents: read` default. The compatibility guide describes the [complete credential boundary](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/compatibility.md#repositories-credentials-and-github-services).

> [!WARNING]
> The job-bound token service does not determine whether a fork or actor is trusted. If a pull request can change an imported workflow, that workflow can request any repository permission enabled by the service. Do not allow untrusted workflow changes to receive write permissions.

## Cache mise installations

On Buildkite hosted agents, attach a mise data cache to avoid reinstalling mise and `buildkite-gha`:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/mise"
    plugins:
      - github-actions#v0.8.0:
          workflow: ".github/workflows/ci.yml"
```

Without this volume, mise uses the agent or user data directory. Treat the mise data directory as executable state: do not share it with untrusted jobs or principals that can modify it. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Supported functionality and limitations

The public preview supports an evolving subset of GitHub Actions. Common supported features include:

- Linux x86-64 jobs using `ubuntu-latest`, `ubuntu-24.04`, or `ubuntu-22.04`. These labels identify a compatible runner but do not provide the same tools or image layout as a GitHub-hosted runner.
- Native macOS Apple Silicon jobs using `macos-latest`, `macos-15`, or `macos-14` when each used label has an explicit Darwin arm64 queue mapping.
- Bash and `sh` run steps.
- Static job dependencies and matrices, including `include` and `exclude`, up to 256 expanded instances per job.
- Supported job and step conditions, outputs, timeouts, and step-level `continue-on-error` behavior.
- Public JavaScript, composite, local, and compiler-verified Dockerfile actions.
- Local reusable workflows with statically resolvable inputs.
- Supported, audited revisions of `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`, and `actions/cache`.

Important limitations include:

- General workflow secrets, ambient `GITHUB_TOKEN`, private actions, private reusable workflows, alternate-repository or alternate-ref checkout, and GitHub-compatible OIDC are not available.
- Windows and Linux arm64 jobs are not supported.
- macOS does not provide GitHub-hosted image or Xcode inventory parity. Docker actions, job containers, and service containers are not supported on macOS.
- Job and service containers are not available through the production plugin path.
- Dynamic matrices and remote reusable workflows are not supported.
- The runtime accepts `strategy.fail-fast` but does not enforce it, so a failed matrix job does not cancel the other matrix jobs.
- The complete `github.event` payload and GitHub-specific event behavior are not available at runtime.
- Unaudited revisions of actions with native support are rejected.

If a feature is not listed in the [`buildkite-gha` v0.8.0 compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/compatibility.md), treat it as unsupported.

> [!WARNING]
> All steps in an imported job share a workspace, environment changes, processes, and action lifecycle. Docker actions provide packaging, not a security boundary. Review the [`buildkite-gha` v0.8.0 security model](https://github.com/buildkite/buildkite-gha/blob/v0.8.0/docs/security.md) before running untrusted workflow code.

## Develop the plugin

See the [development guide](DEVELOPMENT.md) for local tests, CI smoke tests, and release instructions.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
