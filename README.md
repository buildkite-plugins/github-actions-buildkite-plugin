# GitHub Actions Buildkite plugin

The GitHub Actions Buildkite plugin imports a GitHub Actions workflow as native steps in Buildkite Pipelines.

## Usage

Add the plugin to a [Buildkite Pipelines command step](https://buildkite.com/docs/pipelines/configure/step-types/command-step). The `workflow` attribute specifies the workflow file to import:

```yaml
steps:
  - label: ":github: GitHub Actions"
    key: "github-actions"
    plugins:
      - github-actions#v0.2.0:
          workflow: .github/workflows/ci.yml
```

The command step must define a `key`. The importer uses this key to make the generated steps depend on the upload step. The plugin downloads and verifies the public [`buildkite-gha` CLI](https://github.com/buildkite/buildkite-gha), then uses it to translate and upload the workflow.

### Pin the CLI version

The plugin tag and `buildkite-gha` CLI version are independent. The `version` attribute defaults to `0.2.0`. To prevent a future plugin default from changing the CLI version, pin the version explicitly:

```yaml
steps:
  - key: "github-actions"
    plugins:
      - github-actions#v0.2.0:
          workflow: .github/workflows/ci.yml
          version: 0.2.0
```

## Requirements

The importer command step requires a Buildkite agent running Linux x86-64 (`x86_64` or `amd64`). The plugin selects the `hosted` runtime queue for generated action jobs. You cannot configure this queue.

JavaScript actions run with Node.js `20.20.2` or `24.18.0`. The official Node.js binaries installed by mise require glibc 2.28 or newer. Shell-only workflows and the static `buildkite-gha` CLI do not have this requirement.

## Security and caching

The plugin installs mise version `2026.5.12` when needed. It verifies both the pinned release archive and the exact cached executable tree with SHA-256.

The plugin downloads `buildkite-gha` releases without a GitHub token from the hard-coded public [`buildkite/buildkite-gha` repository](https://github.com/buildkite/buildkite-gha). Every job fetches the published checksum and works with a private copy of the release archive. The plugin verifies the checksum and fixed CLI-only layout before running a job-private extraction.

On the importer, mise uses a [cache volume on Buildkite hosted agents](https://buildkite.com/docs/agent/buildkite-hosted/cache-volumes) when one is available. Otherwise, it uses the Buildkite agent data path or standard user cache directories. The CLI passes the importer's verified mise executable to generated action jobs, so the hosted runtime does not need mise preinstalled.

Generated action jobs automatically attach a dedicated cache volume for Node.js installations managed by mise. The runtime verifies the digest and directly invokes the exact Node.js executable. It reinstalls a cache entry if the digest does not match. Cache misses do not affect correctness, and shell-only jobs do not attach this runtime cache.

The action runtime installs Node.js through mise's pinned core backend with mise configuration disabled. This prevents the workflow repository's mise configuration from changing the compatibility runtime.

## Behavior and limitations

The CLI translates and uploads the workflow. The plugin does not add a control plane or rewrite action inputs. GitHub Actions `on:` does not configure Buildkite Pipelines triggers, and the plugin does not yet provide protected capabilities. Configure the pipeline's triggers and specify the workflow file directly.

## Development

For local testing instructions and the test-only cache override, see the [development guide](DEVELOPMENT.md).

## License

This project uses the MIT License. See the [license file](LICENSE).
