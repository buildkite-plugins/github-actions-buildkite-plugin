# GitHub Actions Buildkite plugin

> [!NOTE]
> Running GitHub Actions workflows in Buildkite is currently in public preview. To report issues with the preview, [open an issue in the `buildkite-gha` repository](https://github.com/buildkite/buildkite-gha/issues). For help migrating to native Buildkite Pipelines steps, contact the [Buildkite Support team](mailto:support@buildkite.com).
>
> The plugin and runtime are under active development. Review the [`buildkite-gha` v0.97.2 compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md) before adding a workflow.

The GitHub Actions Buildkite plugin converts a supported [GitHub Actions workflow](https://docs.github.com/en/actions/using-workflows/about-workflows) into native [Buildkite Pipelines](https://buildkite.com/docs/pipelines) jobs without creating a GitHub Actions workflow run. This lets you start migrating a workflow before [converting it into native Buildkite Pipelines steps](https://buildkite.com/docs/pipelines/migration/from-githubactions).

During the preview, start with a simple workflow in a public `github.com` repository that targets Linux x86-64. Private event-repository checkout, private reusable workflows, statically named Buildkite secrets, GitHub deployment environments and variables, temporary GitHub tokens, and OIDC are available with additional setup. Check the [supported functionality and limitations](#supported-functionality-and-limitations) before you begin.

## Add workflows to a pipeline

For most users, add the plugin to a keyed command step in your pipeline configuration. Select the workflow you want to import explicitly:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    agents:
      queue: importer-linux
    plugins:
      - github-actions#latest:
          workflow: .github/workflows/ci.yml
```

An explicit selector must be a path to a `.yml` or `.yaml` workflow file. When present, the file must be regular, tracked, and inside the repository. When this importer step runs, the plugin uploads one dynamic pipeline containing a Buildkite group for each directly runnable workflow. Each workflow job and matrix entry becomes a Buildkite Pipelines job that depends on the importer step. A matrix or runner label taken from another job's output expands in a deferred step after that job runs. An explicitly configured importer step must have a `key` and must be scheduled explicitly on either a Linux amd64 or native macOS arm64 agent. The plugin's `runners` mappings schedule generated workflow jobs only; they do not select or change the importer agent.

The Git ref after `github-actions#` selects the plugin code. Use a specific release such as `github-actions#v0.13.0` for an immutable pin, or use `github-actions#latest` to follow the newest stable plugin release that has passed the required validation. This is separate from the `version` property below, which selects the `buildkite-gha` runtime.

Configure runtime selection with the following properties:

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Explicit selection only: one of `workflow` or `workflows` | — | One explicit `.yml` or `.yaml` workflow path. Missing or untracked paths are skipped. |
| `workflows` | Explicit selection only: one of `workflow` or `workflows` | — | Non-empty array of explicit `.yml` or `.yaml` workflow paths. Missing or untracked paths are skipped. |
| `version` | No | `latest` | Latest stable or an exact `buildkite-gha` release from `0.9.0` onward. |
| `source-ref` | No | — | `buildkite-gha` commit, branch, or tag to build for development testing; mutually exclusive with `version`. |
| `minimum-release-age` | No | `0s` | Minimum release age used by mise when resolving `latest`. |
| `experimental-runner-user` | No | `true` | Run generated Linux jobs as a dedicated `runner` user. Set to `false` only as a temporary compatibility opt-out. |
| `private-reusable-workflows` | No | `false` | Allow reusable workflows from private repositories that the importer's existing Git credentials can read. Requires `buildkite-gha` v0.65.0 or later. |
| `oidc` | No | — | Buildkite OIDC token options for jobs that request GitHub-compatible OIDC. Requires a `buildkite-gha` release with OIDC support. |
| `runners` | No | — | Authoritative `runs-on` mappings to Buildkite queues, optional immutable Linux image overrides, and optional Buildkite Hosted cache volumes. Unmapped selectors use Agent API runner resolution. |

> [!NOTE]
> Plugin and runtime versions are independent. Pin `version` to keep release-version selection stable, or use `latest` to follow stable runtime releases. Increase `minimum-release-age` (for example, to `24h`) to delay newly published releases. If you update the runtime version, use its matching compatibility guide.

To test unreleased runtime behavior, set `source-ref` to a full lowercase 40-character commit, branch, or tag from the public `buildkite/buildkite-gha` repository and omit `version`. Branches and tags are resolved once at importer startup and the resolved commit is logged. All runtimes use that same commit, even if the branch moves during compilation. Names shared by a branch and tag are rejected; use a full commit to disambiguate. Use a full commit when you need repeatable builds across runs.

The plugin uses mise and Go 1.26.5 to build Linux amd64, Darwin arm64, and Windows amd64 executables from that exact source, runs the executable native to the importer agent, and supplies the other runtimes to generated jobs. Testing experimental Windows jobs requires a source commit that supports Windows and a compatible Windows queue; the importer still runs on Linux amd64 or Darwin arm64. Source builds do not include a Linux arm64 runtime, so workflows with jobs mapped to Linux arm64 queues fail unless you use a released `version`. Source builds are for development only and do not use release checksums, attestations, or `minimum-release-age`.

The plugin schema validates explicit selector paths when present, the runtime-acquisition fields `version`, `source-ref`, and `minimum-release-age`, the boolean `experimental-runner-user` field, and the admission-level shape of `oidc`. It passes behavioral configuration, such as `runners` and `private-reusable-workflows`, through to the selected `buildkite-gha` runtime, which validates the complete configuration strictly. This allows runtime releases to extend the supported syntax without requiring a companion plugin release.

### Select workflows

Use `workflow` as the simple form for one explicit path:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
```

Use the non-empty `workflows` array when importing multiple explicit paths:

```yaml
plugins:
  - github-actions#latest:
      workflows:
        - .github/workflows/ci.yml
        - .github/workflows/release.yml
```

For explicit selection, configure exactly one selector form. Each present value must identify one regular, tracked `.yml` or `.yaml` file inside the repository. Empty values and arrays, directories, globs, symlinks, files outside the repository, and wildcard selectors are not accepted. Selected paths are canonicalized, sorted, and deduplicated before upload.

Missing or untracked configured paths produce a warning and are skipped. If all configured paths are missing or untracked, the importer succeeds without uploading a pipeline. Remaining workflows are compiled and uploaded in one pipeline transaction. Workflow groups use the workflow's `name`, falling back to its repository path; a supported non-empty `run-name` is appended to the group label. Reusable workflows whose only trigger is `workflow_call` do not create groups, but remain available to matched callers. Selecting only reusable workflows is an error. A parse, compilation, or trigger-translation error in one of several selected workflows instead becomes a failing top-level step, allowing other selected workflows to remain in the uploaded pipeline.

### Run Linux jobs as a runner user

Generated Linux job processes run as a dedicated `runner` user by default. To temporarily run as the agent's original user without this bootstrap, set `experimental-runner-user: false`:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    agents:
      queue: hosted
    plugins:
      - github-actions#latest:
          workflow: .github/workflows/ci.yml
          version: "0.97.2"
          experimental-runner-user: false
          runners:
            - runs-on: ubuntu-latest
              queue: hosted
```

Generated Linux jobs must start as root, or as an existing `runner` user with home `/home/runner` and passwordless `sudo`, so the runtime can provision the `runner` account. That user retains passwordless `sudo`, so this is not a security boundary. The option does not affect macOS or Windows jobs.

### Configure OIDC tokens

Use the `oidc` block to configure pipeline-owner options for GitHub-compatible OIDC tokens:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/deploy.yml
      oidc:
        claims: [organization_id]
        aws-session-tags: [organization_slug, pipeline_id]
        subject-claim: pipeline_id
```

This configuration requires a `buildkite-gha` release with OIDC support. Releases without that support reject the `oidc` block during strict behavioral configuration validation, so do not enable it until a supporting runtime release is selected.

The block only affects jobs that already declare `permissions: id-token: write`; it does not grant OIDC access to other jobs or change the workflow itself. Host JavaScript actions, including those called by composite actions, can request these tokens; shell steps, Docker actions, and actions running in job containers cannot. Identity providers must trust Buildkite's issuer and claims rather than GitHub's. `claims` adds optional claims to tokens, `aws-session-tags` duplicates claims into AWS session-tag format, and `subject-claim` selects one immutable claim as the token subject. The accepted values match [`buildkite-agent oidc request-token`](https://buildkite.com/docs/agent/cli/reference/oidc) and are validated by `buildkite-gha`.

The supported top-level triggers select and filter workflow groups as follows:

| GitHub Actions trigger | Buildkite behavior |
| --- | --- |
| `push` | GitHub `push` webhook, including supported branch, tag, and bounded path filters; also Buildkite UI or API build |
| `pull_request` | GitHub `pull_request` webhook, including supported base-branch, activity-type, and bounded path filters |
| `merge_group` | Native Buildkite merge queue build with a verified linked `checks_requested` webhook |
| `release` | Native Buildkite release build with a verified linked `published`, `created`, or `released` webhook |
| `issues` | Native Buildkite issue build with verified linked webhook data |
| `workflow_dispatch` | Build with an authoritative `workflow_dispatch` value in `GITHUB_EVENT_NAME` or `BUILDKITE_GITHUB_EVENT` |
| `schedule` | Buildkite scheduled build |

[GitHub Actions Pipeline Triggers](#run-from-a-github-actions-pipeline-trigger) support additional events. The [compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#names-and-triggers) lists every supported event and filter. `pull_request_target` is intentionally unsupported.

The effective event selects which workflow groups apply. Applicable workflows use only the matching event's condition; triggers for other events are not ORed into that group. Unsupported events alongside supported events are ignored with a warning. Bounded `paths` and `paths-ignore` filters are supported for verified linked GitHub branch pushes and pull requests when the local checkout provides complete matching diff evidence; a verified nonmatch becomes a skipped step. Other unsupported or inexact filters fail the affected workflow rather than broadening when it runs. A `workflow_call` trigger defines a reusable workflow and does not create a top-level group by itself.

These conditions select groups in a Buildkite build; they do not configure which GitHub webhooks create builds. Configure the corresponding webhook events in the Buildkite pipeline settings. Buildkite also retains ownership of cron schedules: every workflow with `on.schedule` is eligible during any Buildkite scheduled build.

## Migrate incrementally

Imported workflow jobs and native Buildkite Pipelines steps can run in the same build. In this example, the native `Deploy` step waits for all imported test jobs to finish:

```yaml
steps:
  - label: ":github: Tests"
    key: "github-actions-tests"
    plugins:
      - github-actions#latest:
          workflow: .github/workflows/ci.yml

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

You do not need to install `mise` or `buildkite-gha`. Mise selects, verifies, and caches the release asset matching the importer host: Linux amd64 or Darwin arm64. The importer then verifies and stages each other same-release runtime (Linux x86-64, Linux arm64, macOS arm64, or Windows x86-64) only when a generated job needs it.

Generated jobs that use JavaScript actions also prepare a verified, managed `mise` installation for the supported Node.js versions. Shell-only generated jobs and jobs that use only native adapters or Docker do not install `mise`.

The importer passes the runtime and compiled execution plans to generated jobs using Buildkite Pipelines artifacts. Each job verifies these files before using them. Buildkite Pipelines handles scheduling, logs, retries, cancellation, and build status.

## Requirements

The importer step needs:

- A Linux amd64 or Darwin arm64 agent, selected by the importer's own `agents` configuration. Generated-job `runners` mappings do not schedule this step.
- Buildkite Agent v4 with `buildkite-gha` v0.46.2 or later to preserve default secret rejection during pipeline upload. Older runtimes pass `--reject-secrets`, which Agent v4 removed; use Agent v3.129 or later in the v3 series with those runtimes. Do not enable `BUILDKITE_AGENT_PIPELINE_UPLOAD_ALLOW_SECRETS` on Agent v4.
- Bash, `curl`, `tar`, `mktemp`, `cp`, and either `sha256sum` on Linux or `shasum` on macOS, as listed in [`plugin.yml`](plugin.yml). The download tools are used only when a compatible `mise` is not already on `PATH`.
- Git when `BUILDKITE_COMMIT` is not already a full commit SHA.
- Outbound HTTPS access to public GitHub release and action sources.

Generated jobs need Buildkite agent v3.129 or later and an execution environment matching their runner mapping. Linux x86-64 jobs can run on [Buildkite hosted agents](https://buildkite.com/docs/agent/buildkite-hosted), the [Agent Stack for Kubernetes](https://buildkite.com/docs/agent/self-hosted/agent-stack-k8s), or other self-hosted agents that provide the workflow's tools. Linux arm64 jobs require an explicitly mapped Linux arm64 queue and `buildkite-gha` v0.97.0 or later. Supported macOS labels require a native Darwin arm64 queue. [Experimental Windows jobs](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#experimental-windows-jobs) require a Windows Server 2022 x86-64 queue with PowerShell 7 (`pwsh`) and Git on `PATH`. The runtime tells the agent to skip its usual repository checkout so that it can prepare the workflow workspace instead.

Depending on the workflow, generated-job hosts also need:

- `git` available on `PATH` for `actions/checkout`.
- Docker available on `PATH` for Linux job containers, service containers, and Docker actions. Dockerfile actions also require Docker Buildx, whose default builder must use the local `docker` driver.

## Map runner labels to queues and images

Use `runners` to map an exact GitHub `runs-on` label to a Buildkite queue. An explicit mapping is authoritative and bypasses Agent API resolution. Unmapped selectors are resolved by the job-scoped Buildkite Agent API. If the Agent API cannot be reached, the importer warns and falls back to local presets for `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04`, and `macos-latest`. Configured `ubuntu-latest` and `ubuntu-24.04` profiles use the Noble hosted-toolchains image by default; `ubuntu-22.04` uses Jammy. A Linux x86-64 mapping may override that default with another digest-pinned image:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    agents:
      queue: importer-macos-arm64
    plugins:
      - github-actions#latest:
          workflow: .github/workflows/ci.yml
          runners:
            - runs-on: ubuntu-latest
              queue: hosted
              image: buildkite.namespace-images.com/agent-base@sha256:62a45683afffaae9edfd669c16d2fee23b5a571679f31715e1063dada667ea24
            - runs-on: macos-14
              queue: macos-sonoma-arm64
```

The top-level `agents.queue` above schedules the importer on macOS arm64; it is independent of the queues under `runners`. Labels are matched case-insensitively after expressions and matrices are resolved. An explicit `image` applies only to the matching Linux x86-64 label, must be an immutable `@sha256:` reference, and replaces the label's hosted-toolchains default. macOS mappings select a native queue and cannot specify an image. Duplicate labels, unsupported labels, malformed queues or images, and conflicting multi-label targets fail admission.

An explicit mapping declares that its label runs on Linux x86-64, except for known Linux arm64 labels (`ubuntu-24.04-arm`, `ubuntu-22.04-arm`, and labels ending in `-arm64` or `-aarch64`), known macOS labels, and experimental Windows labels (`windows-latest` and `windows-2022`). Linux arm64 labels have no default mapping. Windows labels are rejected unless explicitly mapped or enabled through Agent API resolution. Map them to your own queues:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      runners:
        - runs-on: ubuntu-24.04-arm
          queue: my-linux-arm64-queue
        - runs-on: windows-2022
          queue: my-windows-queue
```

Linux arm64 and Windows mappings cannot specify an image. They do not create queues, enable Buildkite hosted Linux arm64 or Windows agents, or fall back to x86-64 emulation.

For other selectors, the Agent API returns the complete queue, platform, and host environment, either an immutable Linux image or a native Linux host selected through agent tags, and may return a fallback warning. If the Agent API rejects a selector, for example because the job's cluster has no compatible hosted queue, the importer reports the reason at the job's `runs-on` before uploading the pipeline.

> [!WARNING]
> Generated jobs may execute untrusted workflow or action code. The selected queue must provide whole-job isolation, no ambient protected credentials, and a clean machine for each untrusted job. Persistent self-hosted agents can expose host resources and state left by earlier jobs.

### Configure generated-job cache volumes

An explicit Linux runner mapping can attach one [Buildkite Hosted cache volume](https://buildkite.com/docs/agent/buildkite-hosted/cache-volumes) to every generated job using that mapping:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      runners:
        - runs-on: ubuntu-latest
          queue: hosted
          cache:
            paths:
              - /home/runner/.gradle/caches
              - /home/runner/.gradle/wrapper
            name: gradle-${BUILDKITE_BRANCH}
            size: 40g
```

`cache.paths` is a required, non-empty list of unique absolute paths. `name` and `size` are optional; names are at most 100 characters and use Buildkite's letters, numbers, hyphens, and `${BUILDKITE_*}` variables, while sizes use `Ng` and must be at least `20g`. The runtime merges its managed mise cache into the same volume when needed. Cache volumes are unsupported for workflow jobs that set `container` and for Windows jobs.

Cache volumes are best-effort, pipeline-and-cluster-scoped accelerators that commit only after successful jobs. Treat their contents as untrusted executable state, and do not use them as durable storage. This configuration is separate from the workflow's `actions/cache` behavior.

## Configure generated-job runtimes

Generated jobs need network access for anything they download at runtime:

- Jobs that use public GitHub Actions need outbound HTTPS access to `codeload.github.com`, where the runtime downloads each action's source archive.
- Jobs that use JavaScript actions need outbound HTTPS access to the managed Node.js and `mise` downloads. Actions that declare `node16` run on managed Node 16.20.2 and produce a deprecation warning. Actions that declare `node20` or `node24` run on managed Node 24.18.0. Managed Node binaries require glibc 2.28 or newer. Shell-only workflows do not have this glibc requirement.

When resolving a mutable tag or branch for a public action, the importer uses a dedicated action-source token only for public GitHub metadata requests and reuses it across the selected workflows and nested composite actions. If it cannot obtain the token, it reports a warning and retries anonymously. A lowercase, full 40-character commit SHA does not require an API request. Credential-repository metadata requests and all action archive downloads from `codeload.github.com` remain anonymous.

Configured Linux profiles select an immutable hosted-toolchains image and enable its `/opt/hostedtoolcache`. An explicit `runners[].image` override must provide the same tool-cache path and is supported only when the matching jobs run on Buildkite hosted agents or Agent Stack for Kubernetes controller v0.30.0 or later. Do not configure Linux profiles for other self-hosted environments that cannot provision the generated job image. Native Linux hosts selected by the Agent API use a job-private tool cache. macOS and Windows profiles never select an image.

## Configure triggers and GitHub context

Buildkite Pipelines controls when builds run. Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflows' `on` keys select groups after a build exists; they do not create Buildkite Pipelines triggers.

For manual and scheduled builds, the plugin finds the exact commit from the checked-out repository when `BUILDKITE_COMMIT` does not already contain a full commit SHA.

Pull request builds receive `pull_request` context. Branch and tag builds, and manual UI or API builds, receive `push` context. Verified linked merge queue, release, and issue webhooks supply `merge_group`, `release`, and `issues` context. Buildkite scheduled builds select workflows with a `schedule` trigger. `workflow_dispatch` is selected only when the build supplies it as an authoritative `GITHUB_EVENT_NAME` or `BUILDKITE_GITHUB_EVENT` value; dispatch inputs are not available.

When the build has linked webhook data, `GITHUB_EVENT_PATH` points to a job-scoped file containing the complete event payload. The importer stores the payload as a build artifact, so anyone who can download the build's artifacts can read it. Builds without linked webhook data, such as manual and scheduled builds, do not create this file.

### Run from a GitHub Actions Pipeline Trigger

> [!NOTE]
> GitHub Actions Pipeline Triggers are in private preview and feature flagged off for most organizations.

When this trigger type is enabled, the Buildkite app and `buildkite-gha` select the workflow associated with the trigger. The minimal pipeline configuration is:

```yaml
steps:
  - plugin: github-actions
```

Server-selected imports require `buildkite-gha` v0.48.0 or later. The importer step does not need a `key`, and generated jobs are uploaded without a workflow group. Unlike an explicitly configured path, a missing or untracked server-selected workflow fails the importer. An explicit `workflow` or `workflows` value takes precedence over server selection.

Pipeline Triggers support more events than native Buildkite builds, including all seven `release` activities, tokenless `merge_group` workflows, `deployment`, `deployment_status`, `issue_comment`, same-repository `pull_request_review` and `pull_request_review_comment`, and repository lifecycle events such as `create`, `delete`, `label`, and `discussion`. See the [server-selected event contract](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/cli.md#private-preview-pipeline-trigger-selection) and the [compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#names-and-triggers) for each event's requirements.

Supported runtime and behavioral options may still be configured using the standard `plugins` form while omitting both `workflow` and `workflows`; the plugin forwards them without inferring trigger context.

For example, test a runtime branch while keeping server-side workflow selection and automatic runner mapping:

```yaml
steps:
  - key: github-actions
    agents:
      queue: importer-linux
    plugins:
      - github-actions#latest:
          source-ref: main
```

Replace `main` with the runtime branch to test and `importer-linux` with your Linux amd64 or macOS arm64 importer queue. The server supplies the workflow context for the build, and the Agent API maps its `runs-on` labels to available queues. No `workflow`, `workflows`, or `runners` override is needed. This requires a build with server-selected workflow context; ordinary builds without that context still need an explicit workflow selector. Automatic mapping does not enable unavailable platforms or provision missing queues.

## Configure checkout and credentials

Supported `actions/checkout` revisions can check out the event repository at its event commit or a static branch. Commits outside the audited snapshot use the latest stable checkout contract and produce a warning. Checkout runs anonymously when repository-provider credentials are not enabled. Private checkout uses Buildkite repository-provider Git credentials when they are enabled and authorized for the job. Direct and recursive GitHub submodules are supported within the compatibility guide's transport and credential boundaries.

Checkout credentials do not populate `GITHUB_TOKEN` or `github.token`, enable private actions, or allow alternate repositories, tags, or arbitrary dynamic commits. A workflow can receive a temporary GitHub token only when it makes a supported static token reference and both the Buildkite organization feature and the pipeline's default-off token setting are enabled. When the workflow omits `permissions`, the runtime requests exactly `contents: read` without inheriting GitHub repository or organization defaults. Write access requires an explicit top-level permissions map; an empty map or scopes set to `none` mint no token.

> [!WARNING]
> Temporary token issuance verifies the workflow and build provenance. Job-level repository permission maps are accepted but do not alter `GITHUB_TOKEN`; job-level `id-token` permissions retain their documented behavior. Jobs expanded from reusable workflows use the top-level requesting workflow's repository permissions because called-workflow permission maps do not narrow `GITHUB_TOKEN`. Pull request ancestry is capped at `contents: read`, and merge queue ancestry is denied. Review the workflow-token restrictions before enabling the service.

Direct jobs can resolve statically named `${{ secrets.NAME }}` references through the destination job's Buildkite secret authority. Local reusable-workflow calls can use `secrets: inherit` or explicitly map declared aliases from direct `${{ secrets.NAME }}` references; inheritance is one hop and must be repeated at each nested call. These are Buildkite secrets, not GitHub repository, environment, event, or fork-scoped secrets; [environment secret names](#deployment-environments-and-variables) map to Buildkite secret names. Dynamic secret names and secret forwarding to remote reusable workflows are unsupported. The compatibility guide describes the [complete credential boundary](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#repositories-credentials-and-github-services).

GitHub's API cannot export secret values. To copy GitHub Actions repository secrets into Buildkite secrets, use [`buildkite-gha migrate-secrets`](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/cli.md#migrate-github-actions-secrets), which generates a reviewable, one-use GitHub Actions workflow.

### Deployment environments and variables

Top-level jobs can declare a literal GitHub [deployment environment](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#deployment-environments). The Buildkite backend reads its protection rules, secret names, and variables from GitHub; no GitHub token or secret value reaches the importer. Required reviewers become a Buildkite block step that any user who can unblock the pipeline can approve. An environment secret `NAME` resolves to the Buildkite secret `<ENVIRONMENT>_<NAME>`, for example `PRODUCTION_DEPLOY_KEY`. Wait timers, deployment branch policies, and custom protection rules fail compilation, and builds do not create GitHub deployment records.

`${{ vars.NAME }}` resolves [repository, organization, and environment variables](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#repository-and-organization-variables) with GitHub's per-position scoping. Variable values are configuration, not secrets: they are stored in the job plan artifacts and are visible to anyone who can read the build's artifacts.

### Private reusable workflows

Set `private-reusable-workflows: true` to call reusable workflows from the pipeline repository or other private GitHub repositories:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      private-reusable-workflows: true
```

The importer resolves these workflows with its existing Git credentials, such as the Buildkite Agent repository-provider credential helper, which requests approval for each repository. Missing and denied repositories, refs, and paths produce the same error. Private actions remain unsupported.

> [!WARNING]
> Access is repository-wide: once enabled, workflow source can select any workflow in any GitHub repository the importer's credentials can read. Restrict the importer's Git credentials or use Buildkite's repository-provider access policy to approve only the required repositories. See the [`buildkite-gha` security model](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/security.md).

## Cache mise installations

On Buildkite hosted agents, attach a mise data cache to avoid reinstalling mise and `buildkite-gha`:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/mise"
    plugins:
      - github-actions#latest:
          workflow: .github/workflows/ci.yml
```

Without this volume, mise uses the agent or user data directory. Treat the mise data directory as executable state: do not share it with untrusted jobs or principals that can modify it. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Supported functionality and limitations

The public preview supports an evolving subset of GitHub Actions. Common supported features include:

- Linux x86-64 jobs using `ubuntu-latest`, `ubuntu-24.04`, or `ubuntu-22.04`. These labels identify a compatible runner but do not provide the same tools or image layout as a GitHub-hosted runner.
- Linux arm64 jobs mapped explicitly to a Linux arm64 queue, such as `ubuntu-24.04-arm`.
- Native macOS Apple Silicon jobs using `macos-latest`, `macos-15`, or `macos-14` when the Agent API, local preset, or a configured fallback resolves the label to a Darwin arm64 queue.
- [Experimental Windows Server 2022 x86-64 jobs](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#experimental-windows-jobs) using `windows-latest` or `windows-2022` with an explicit mapping or Agent API routing.
- Bash, `sh`, `pwsh`, `powershell`, `python`, and custom shell-template run steps on Linux and macOS when the selected interpreter is available on `PATH`. Windows jobs default to `pwsh` and support Windows PowerShell and MSYS2 custom shells.
- Static job dependencies and matrices, including compile-time expression-valued dimensions, `include`, and `exclude`, up to 256 expanded instances per job.
- [Matrices](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#matrices-from-job-outputs) and [runner labels](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md#runners-from-job-outputs) taken from a job output, such as `fromJSON(needs.plan.outputs.matrix)`, which expand in a deferred step after the producing job runs.
- Supported field-specific expressions in job and step conditions, names, runner selection, `env` maps, defaults, outputs, matrices, concurrency, and reusable-workflow calls. Job timeouts remain literal-only.
- Supported outputs, timeouts, and expression-capable job- and step-level `continue-on-error`. Runtime `runner.temp` is available in supported workflow step fields, step conditions, and job outputs, but not job conditions or compile-time positions.
- Workspace-confined `hashFiles()` in supported step conditions and step runtime fields, with bounded patterns, matches, and input size.
- Public JavaScript, composite, local, self-repository (`$/`), compiler-verified Dockerfile, and public prebuilt-image Docker actions. Direct workflow `uses: docker://...` steps and private action images remain unsupported.
- Local, literal public, and opt-in private reusable workflows. Local calls can inherit or explicitly map declared Buildkite secret authority. String inputs can embed direct dependencies' `needs` outputs, and boolean or number inputs can derive from them through a single expression.
- Linux job and service containers, including broadly compatible service health checks, credentials, ports, volumes, and the `job.services` context.
- Statically named Buildkite secrets in direct jobs and opt-in temporary `GITHUB_TOKEN` and OIDC support within the documented authority boundaries.
- Literal deployment environments on top-level jobs with required-reviewer approval gates and environment secret names, plus repository, organization, and environment `vars`.
- The complete event payload through `GITHUB_EVENT_PATH` for builds with linked webhook data.
- Supported revisions of `actions/checkout` (including nested paths, LFS, sparse checkout, and partial-clone filters), `actions/upload-artifact`, `actions/download-artifact`, and `actions/cache`. See the compatibility guide for exact admitted commits and version-specific behavior.

Important limitations include:

- GitHub-stored secret values, ambient `GITHUB_TOKEN`, private actions, alternate-repository checkout, tags, and arbitrary dynamic checkout commits are not available.
- Windows arm64, Windows Server 2025, and macOS x86-64 jobs are not supported. Linux arm64 and Windows jobs need your own queues.
- macOS does not provide GitHub-hosted image or Xcode inventory parity. Docker actions, job containers, and service containers are not supported on macOS or Windows.
- Dynamically selected reusable workflows are not supported. A job that takes its runner label from a job output cannot also declare a matrix.
- Environment wait timers, deployment branch policies, custom protection rules, and GitHub deployment records are not supported. GitHub reviewer lists are not enforced; anyone who can unblock the pipeline can approve.
- The runtime accepts `strategy.fail-fast` but does not enforce it, so a failed matrix job does not cancel the other matrix jobs.
- `github.event_path` expressions are not supported, and builds without linked webhook data do not provide `GITHUB_EVENT_PATH`.
- Unaudited `actions/checkout`, `actions/upload-artifact`, and `actions/download-artifact` commits use the latest stable contract with a warning; unaudited `actions/cache` commits run a substituted audited release.

If a feature is not listed in the [`buildkite-gha` v0.97.2 compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/compatibility.md), treat it as unsupported.

> [!WARNING]
> All steps in an imported job share a workspace, environment changes, processes, and action lifecycle. Docker actions provide packaging, not a security boundary. Review the [`buildkite-gha` v0.97.2 security model](https://github.com/buildkite/buildkite-gha/blob/v0.97.2/docs/security.md) before running untrusted workflow code.

## Develop the plugin

See the [development guide](DEVELOPMENT.md) for local tests, CI smoke tests, and release instructions.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
