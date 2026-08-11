# GitHub Actions Buildkite Plugin

Run a GitHub Actions workflow as native Buildkite jobs without creating a GitHub Actions run.

## Usage

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.8.0:
          workflow: .github/workflows/ci.yml
```

The importer step must have a `key`. Each workflow job and static matrix entry becomes a Buildkite job that depends on the importer.

### Configuration

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `workflow` | Yes | — | Path to the GitHub Actions workflow. |
| `version` | No | `latest` | Latest stable or an exact stable `buildkite-gha` CLI release newer than `0.8.0`. |
| `runners` | No | — | Exact `runs-on` mappings to Buildkite queues and optional immutable runtime images. |

The plugin release and CLI version are independent. By default, each importer resolves `latest` once to an exact release and logs the selected version. Pin an exact release to keep that selection fixed across importer retries. The selected CLI, rather than this plugin's transport schema, validates `workflow`, `runners`, and future configuration fields. This lets `buildkite-gha` extend the syntax without requiring a companion plugin release while preserving fail-closed validation.

Runner mappings combine scheduling and runtime-image selection without changing workflow files:

```yaml
plugins:
  - github-actions#v0.8.0:
      workflow: .github/workflows/ci.yml
      runners:
        - runs-on: ubuntu-latest
          queue: hosted
          image: buildkite.namespace-images.com/agent-base@sha256:04a6656f92b90269b3259fffaba67e08a3d03d8dc79b40d45c9ac3d9000e9e03
        - runs-on: macos-14
          queue: macos-sonoma-arm64
```

`runs-on` is matched after static workflow expressions and matrices are resolved. `image` is optional and must be an immutable `@sha256:` reference; omit it for macOS runners. Duplicate, unsupported, or unmapped required runner labels fail admission in `buildkite-gha`. Unmapped supported Linux labels retain the selected CLI release's existing Linux defaults; unmapped macOS labels fail instead of falling back to a Linux queue.

Repository checkout behavior is owned by `buildkite-gha` and Buildkite's repository-provider backend. Workflow permissions remain separate: checkout credentials do not populate `GITHUB_TOKEN` or `github.token`, enable private actions, or permit alternate repositories or refs.

## Compatibility

`buildkite-gha` intentionally supports a subset of GitHub Actions. After resolving or pinning a version, read the compatibility guide at the matching Git tag. The mixed-platform plugin contract requires a release newer than `v0.8.0` that publishes paired Linux x86-64 and Darwin arm64 archives. Unsupported behavior fails explicitly rather than silently choosing a substitute.

Key constraints for this plugin are:

- the importer must run on Linux x86-64;
- supported Ubuntu runner labels retain the selected CLI's Linux defaults unless a `runners` entry targets another queue or immutable image;
- supported macOS labels may target configured Apple Silicon queues when the paired `buildkite-gha` release supports them;
- macOS execution does not provide GitHub-hosted image or Xcode parity and does not add macOS Docker, job-container, or service-container support;
- private actions, arbitrary private-source access, Windows, OIDC, protected queues, and job or service containers are not supported; and
- cache, artifact, checkout, and credential support is limited to the specific integrations described in the compatibility guide.

Configure branch, tag, schedule, and pull request triggers in Buildkite. The workflow's `on:` block does not create Buildkite triggers. The CLI derives event context from Buildkite webhook metadata when available and falls back to Buildkite environment data.

The plugin downloads the Linux x86-64 importer and Darwin arm64 runtime from the same selected public `buildkite/buildkite-gha` release without a GitHub token. Both archives and cached copies are checked against that release's checksums; only the native Linux importer is executed for version verification. The hook stages both executables at private absolute paths and invokes the hidden zero-argument `buildkite-gha plugin` command. The CLI validates and publishes only runtime distributions required by the compiled graph.

## Caching

On hosted agents, attach the plugin's cache volume to speed up the importer:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    cache: "/cache/bkcache/github-actions-buildkite-plugin"
    plugins:
      - github-actions#v0.8.0:
          workflow: .github/workflows/ci.yml
```

Without this volume, the plugin falls back to an agent or user cache, then a temporary directory. Cached archives remain verified, and cache misses affect performance rather than correctness. This importer cache is separate from generated-job runtime caching and the workflow's `actions/cache` behavior.

See [DEVELOPMENT.md](DEVELOPMENT.md) for testing and release instructions.

## License

MIT — see [LICENSE](LICENSE).
