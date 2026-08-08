# GitHub Actions Buildkite Plugin

Run a GitHub Actions workflow as native Buildkite jobs without creating a GitHub Actions run.

## Usage

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.5.0:
          workflow: .github/workflows/ci.yml
```

The importer step must have a `key`. Each workflow job and static matrix entry becomes a Buildkite job that depends on the importer.

### Configuration

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Yes | — | Path to the GitHub Actions workflow. |
| `version` | No | `0.5.0` | Exact pre-1.0 `buildkite-gha` CLI version. |
| `buildkite-gha-source-ref` | No | — | `latest` or a full lowercase commit for unreleased CLI testing. |
| `private-checkout` | No | `false` | Enable read-only checkout of the pipeline's private GitHub repository. |

The plugin release (`github-actions#v0.5.0`) and CLI `version` are independent. Set `version` only when you need a CLI release other than the default. `version` and `buildkite-gha-source-ref` are mutually exclusive.

## Compatibility

`buildkite-gha` intentionally supports a subset of GitHub Actions. For the default CLI, see the [`v0.5.0` compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.5.0/docs/compatibility.md) before migrating a workflow. Unsupported behavior fails explicitly rather than silently choosing a substitute.

Key constraints for this plugin are:

- importer and workflow jobs must use Linux x86-64;
- supported Ubuntu runner labels map to the fixed Buildkite `hosted` queue;
- private actions, arbitrary private-source access, Windows, macOS, OIDC, protected queues, and job or service containers are not supported; and
- cache, artifact, checkout, and credential support is limited to the specific integrations described in the compatibility guide.

Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on:` block does not create Buildkite triggers. Pull request builds receive a `pull_request` context; all other Buildkite builds receive `push`.

Released mode downloads the selected public `buildkite/buildkite-gha` release without a GitHub token and does not require importer-side mise. Downloads and cached copies are verified before execution. Generated jobs prepare mise only when their resolved action trees can execute JavaScript; shell-only, native-adapter-only, and Docker-only jobs skip that setup.

## Private repositories

By default, generated `actions/checkout` steps perform a credential-free, shallow checkout, so the workflow repository must be public. Set `private-checkout` to give verified checkout jobs read-only access to the pipeline's exact GitHub repository:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.5.0:
          workflow: .github/workflows/ci.yml
          private-checkout: true
```

This requires Buildkite's job-bound GitHub scoped access-token service. The CLI requests fixed `contents:read` authority, and the service independently requires the event repository to match the pipeline's GitHub repository. The credential is redacted before use and supplied only to Git through a one-shot askpass pipe.

This option does not populate `GITHUB_TOKEN` or `github.token`, grant write access, enable private actions, or permit alternate repositories or refs.

## Caching

On hosted agents, attach the plugin's cache volume to speed up the importer:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/github-actions-buildkite-plugin"
    plugins:
      - github-actions#v0.5.0:
          workflow: .github/workflows/ci.yml
```

Without this volume, the plugin falls back to an agent or user cache, then a temporary directory. Cached archives remain verified, and cache misses affect performance rather than correctness. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Testing unreleased CLI source

For integration testing, `buildkite-gha-source-ref` runs the CLI from the canonical public repository instead of downloading a release. The importer must provide mise; for example:

```yaml
plugins:
  - mise#a5845c5082d3a4fe36dd77ae74973dfc86fc91a2:
      version: "2026.5.12"
  - github-actions#v0.5.0:
      workflow: .github/workflows/ci.yml
      buildkite-gha-source-ref: latest
```

`latest` resolves `buildkite/buildkite-gha` `main` once, logs its full commit, and runs that immutable commit with `mise --no-config` and Go 1.26.5. Use the logged full commit instead of `latest` for reproducible retries. Other refs are rejected.

The mise plugin requires a repository mise config. Source mode does not test release archives, checksums, or caching; normal released mode remains unchanged.

See [DEVELOPMENT.md](DEVELOPMENT.md) for testing and release instructions.

## License

MIT — see [LICENSE](LICENSE).
