# GitHub Actions Buildkite Plugin

Run a GitHub Actions workflow as native Buildkite jobs without creating a GitHub Actions run.

## Usage

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.7.1:
          workflow: .github/workflows/ci.yml
```

The importer step must have a `key`. Each workflow job and static matrix entry becomes a Buildkite job that depends on the importer.

### Configuration

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Yes | — | Path to the GitHub Actions workflow. |
| `version` | No | `0.7.1` | Exact pre-1.0 `buildkite-gha` CLI version. |
| `runners` | No | — | Exact `runs-on` mappings to Buildkite queues and optional immutable runtime images. |
| `buildkite-gha-source-ref` | No | — | `latest` or a full lowercase commit for unreleased CLI testing. |

The plugin release (`github-actions#v0.7.1`) and CLI `version` are independent. Set `version` only when you need a CLI release other than the default. `version` and `buildkite-gha-source-ref` are mutually exclusive.

Runner mappings combine scheduling and runtime-image selection without changing workflow files:

```yaml
plugins:
  - github-actions#v0.7.1:
      workflow: .github/workflows/ci.yml
      runners:
        - runs-on: ubuntu-latest
          queue: hosted
          image: buildkite.namespace-images.com/agent-base@sha256:04a6656f92b90269b3259fffaba67e08a3d03d8dc79b40d45c9ac3d9000e9e03
        - runs-on: macos-14
          queue: macos-sonoma-arm64
```

`runs-on` is matched after static workflow expressions and matrices are resolved. `image` is optional and must be an immutable `@sha256:` reference; omit it for macOS runners. Duplicate, unsupported, or unmapped required runner labels fail admission in `buildkite-gha`. Unmapped supported Linux labels retain the paired CLI release's existing Linux defaults.

Repository checkout behavior is owned by `buildkite-gha` and Buildkite's repository-provider backend. Workflow permissions remain separate: checkout credentials do not populate `GITHUB_TOKEN` or `github.token`, enable private actions, or permit alternate repositories or refs.

## Compatibility

`buildkite-gha` intentionally supports a subset of GitHub Actions. For the default CLI, see the [`v0.7.1` compatibility guide](https://github.com/buildkite/buildkite-gha/blob/v0.7.1/docs/compatibility.md) before migrating a workflow. Unsupported behavior fails explicitly rather than silently choosing a substitute.

Key constraints for this plugin are:

- the importer must run on Linux x86-64;
- supported Ubuntu runner labels retain the existing Linux defaults unless a `runners` entry targets another queue or immutable image;
- supported macOS labels may target configured Apple Silicon queues when the paired `buildkite-gha` release supports them;
- macOS execution does not provide GitHub-hosted image or Xcode parity and does not add macOS Docker, job-container, or service-container support;
- private actions, arbitrary private-source access, Windows, OIDC, protected queues, and job or service containers are not supported; and
- cache, artifact, checkout, and credential support is limited to the specific integrations described in the compatibility guide.

Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on:` block does not create Buildkite triggers. Pull request builds receive a `pull_request` context; all other Buildkite builds receive `push`.

Released mode downloads the Linux x86-64 importer and Darwin arm64 runtime from the same selected public `buildkite/buildkite-gha` release without a GitHub token and does not require importer-side mise. Both archives and cached copies are verified; only the native Linux importer is executed for version verification. Generated jobs prepare mise only when their resolved action trees can execute JavaScript; shell-only, native-adapter-only, and Docker-only jobs skip that setup.

## Caching

On hosted agents, attach the plugin's cache volume to speed up the importer:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/github-actions-buildkite-plugin"
    plugins:
      - github-actions#v0.7.1:
          workflow: .github/workflows/ci.yml
```

Without this volume, the plugin falls back to an agent or user cache, then a temporary directory. Cached archives remain verified, and cache misses affect performance rather than correctness. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

## Testing unreleased CLI source

For integration testing, `buildkite-gha-source-ref` runs the CLI from the canonical public repository instead of downloading a release. The importer must provide mise; for example:

```yaml
plugins:
  - mise#a5845c5082d3a4fe36dd77ae74973dfc86fc91a2:
      version: "2026.5.12"
  - github-actions#v0.7.1:
      workflow: .github/workflows/ci.yml
      buildkite-gha-source-ref: latest
```

`latest` resolves `buildkite/buildkite-gha` `main` once, logs its full commit, and builds Linux x86-64 and Darwin arm64 executables from that immutable commit with `mise --no-config` and Go 1.26.5. Use the logged full commit instead of `latest` for reproducible retries. Other refs are rejected.

The mise plugin requires a repository mise config. Source mode does not test release archives, checksums, or caching; released mode remains the production verification path.

See [DEVELOPMENT.md](DEVELOPMENT.md) for testing and release instructions.

## License

MIT — see [LICENSE](LICENSE).
