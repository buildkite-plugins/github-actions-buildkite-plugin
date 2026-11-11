# Development

## Use a custom executable

Build the CLI outside the plugin, then publish it at an HTTPS URL. Use `binary` to test that build instead of an official release. Don't combine `binary` with an explicit `version`, including `version: latest`.

> [!IMPORTANT]
> Use a CLI build that supports `binary` configuration. Older CLIs reject this property.

Use a raw executable URL, not an archive, local path, or URL template. Prefer an immutable URL with a `#sha256=` fragment containing its 64-digit hexadecimal SHA256. The fragment is removed before download, and the executable bytes are verified before execution. Plain HTTPS URLs remain available for development; other fragments are rejected.

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      binary: "https://example.com/buildkite-gha-linux-amd64#sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
```

Replace the example URL and checksum with your executable's values. A single URL covers the importer platform only. For workflows that need other platforms, supply a map with the importer and each required counterpart:

```yaml
plugins:
  - github-actions#latest:
      workflow: .github/workflows/ci.yml
      binary:
        linux/amd64: https://example.com/buildkite-gha-linux-amd64
        linux/arm64: https://example.com/buildkite-gha-linux-arm64
        darwin/arm64: https://example.com/buildkite-gha-darwin-arm64
        windows/amd64: https://example.com/buildkite-gha-windows-amd64.exe
```

Each map URL also accepts a checksum fragment. The plugin downloads only its importer executable and forwards the configuration unchanged. The companion CLI downloads and verifies counterparts only when needed, with no release fallback for a missing platform. Use matching builds across the map. Windows amd64 is a counterpart platform only.

> [!WARNING]
> Custom URLs select code that runs with the importer's authority. HTTPS protects transport, not publisher trust; a checksum pins bytes but does not establish who built them. Use trusted publishers and do not put credentials in URLs. URLs remain in pipeline configuration and may appear in errors.

`source-ref` and `minimum-release-age` are retired and fail with an error. Use `binary` to test unreleased code and an exact `version` instead of delaying `latest`.

## Binary acquisition

For custom importers, use a Linux amd64/arm64 or native macOS arm64 agent with Bash, curl, jq, mktemp, and outbound HTTPS access to Buildkite and GitHub. Windows importers are not supported. The importer's `agents` configuration selects its queue; `runners` mappings select generated jobs, not the importer.

Linux also requires `sha256sum`; macOS requires `shasum`. Historical release archives require `tar`. These dependencies are used by the hook only on their applicable paths, not declared as unconditional agent plugin requirements.

The plugin reads release metadata from the configured `BUILDKITE_AGENT_ENDPOINT` at `/jobs/<job-id>/github-actions/releases/latest` or `/jobs/<job-id>/github-actions/releases/tags/<tag>`. Like the existing runner, environment, and variable APIs, this requires the current job's `BUILDKITE_AGENT_ACCESS_TOKEN` and `BUILDKITE_JOB_ID`. The endpoint must use HTTPS. Buildkite caches published release metadata for one hour using server-side GitHub access. Binaries still download directly from GitHub. The plugin sends the job token only to the Agent API and does not follow metadata redirects. Endpoint failures stop acquisition without falling back to the anonymous API.

The plugin also caches this metadata locally for one hour, separately for `latest` and each exact tag. Cache hits do not extend either window. The combined server and local caches can delay a new `latest` by about two hours. Agent API responses use `Cache-Control: no-store`; shared caching stays inside Rails. Expired or malformed local metadata requires a successful authenticated lookup; a failed refresh does not fall back to stale local data. Concurrent cold server misses can duplicate upstream requests, bounded by a shared limit of 30 per minute; expiry refreshes use a five-second race-condition window.

The plugin validates the release tag, selected asset URL, and SHA256 digest on cache hits and fresh responses. It prefers the platform's raw executable and verifies its bytes against that digest. For historical releases without a raw asset, it verifies the release archive's API digest and extracts only `buildkite-gha`. Invalid raw metadata or bytes fail without falling back to an archive. It does not fetch `checksums.txt`, install mise, or build Go source.

`BUILDKITE_CLEAN_CHECKOUT` values `1`, `t`, `T`, `true`, `TRUE`, and `True` bypass local metadata for that import and refresh the cache entry from Buildkite. They do not bypass Buildkite's shared cache. False, empty, and unrecognized values do not bypass the cache. `BUILDKITE_GIT_CLEAN_FLAGS` does not affect caching. This plugin policy supplements the agent's checkout removal; it does not delete shared binary caches.

The plugin passes the resolved release to the CLI in `BUILDKITE_GHA_PLUGIN_RELEASE`. CLIs with metadata-handoff support use it for counterpart selection without another API request. Historical CLIs retain their own counterpart acquisition. Custom binaries clear this internal environment variable.

The importer hook also sets `BUILDKITE_GHA_PLUGIN_MULTIPLATFORM_RUN=1` to advertise this plugin's expanded execution support. Release metadata alone does not establish that capability: older plugin pins must retain their existing delivery path when paired with a newer CLI.

Official binaries and checksum-pinned custom binaries use a local cache keyed by platform and digest. Each invocation copies cached bytes into a private temporary directory and verifies them before execution. Missing or corrupt entries are downloaded and verified before replacing the cache entry. Plain custom URLs are downloaded each time. Custom URLs never use the release metadata cache. A warm release import makes no network requests for metadata or binaries until its metadata expires. Refreshing metadata does not download the binary again when its digest is unchanged.

Historical releases cache the verified archive by platform and archive digest, then extract the executable into the private temporary directory on each invocation. Warm imports need no archive download. Historical release assets and exact version pins remain unchanged.

The cache root is the first available setting below. Explicit paths must be absolute. If the cache cannot be written, the plugin still downloads and verifies the executable for that invocation.

| Setting | Cache root |
| --- | --- |
| `BUILDKITE_GHA_CACHE_DIR` | The specified path |
| `MISE_DATA_DIR` | `$MISE_DATA_DIR/buildkite-gha` (existing agent compatibility) |
| Writable hosted-agent cache | `/cache/bkcache/buildkite-gha` |
| `BUILDKITE_AGENT_DATA_PATH` | `$BUILDKITE_AGENT_DATA_PATH/cache/buildkite-gha` |
| `XDG_CACHE_HOME` | `$XDG_CACHE_HOME/buildkite-gha` |
| `HOME` | `$HOME/.cache/buildkite-gha` |

Released CLIs also use `MISE_DATA_DIR` to cache other-platform runtimes. If unset, the plugin passes its selected cache root as `MISE_DATA_DIR` when launching the CLI, without installing mise. Explicit settings remain unchanged. These CLI-owned entries live under `$MISE_DATA_DIR/buildkite-gha/releases`.

Cache reuse requires persistent storage shared by the relevant invocations; separate ephemeral agents do not share it automatically. Keep the cache writable only by trusted importers, isolated from untrusted jobs: cached metadata supplies the expected binary digest. The private execution directory is removed on exit.

In importer mode, the plugin validates acquisition properties only. All other options, including `workflow`, `workflows`, `runners`, and `oidc`, pass unchanged to the selected CLI for strict validation.

## Execute a pinned plan

The `run` option launches an existing job plan instead of importing a workflow. It cannot be combined with importer options. Importers select this mode only for their supported delivery contracts.

Pin the plugin revision as well as the runtime bytes. Replace the plugin reference, plan digest, and producer UUID below with the values recorded for the build:

```yaml
plugins:
  - github-actions#<pinned-plugin-ref>:
      run:
        plan:
          digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
          producer: 11111111-1111-4111-8111-111111111111
        runtime:
          platform: linux/amd64
          url: https://github.com/buildkite/buildkite-gha/releases/download/v0.129.0/buildkite-gha_linux_x86_64
          sha256: 87abdffbafc6e91256552f97d13138982804802a7370bd096c033658902f0bef
        hosted-tool-cache: true
```

`plan.producer` is the exact job UUID holding `.buildkite-gha/plans/<sha256>.json` and any event artifact, not a step key that could select a different retry. Alternatively, use `plan.path` for a local plan file or `plan.inline` for base64-encoded plan JSON, with the same required digest. Select exactly one source. The plugin copies or decodes the plan; it never rewrites its bytes or source, event, target, or runtime bindings.

Local and inline plans can supply `event: {inline: <base64 JSON>}` or `event: {env: BUILDKITE_GHA_EVENT_PAYLOAD}`. The latter reads base64 from that separate environment variable and unsets it before execution, keeping large events out of the plugin configuration's per-string environment limit. Select exactly one event source. The plugin verifies decoded bytes against the verified plan's `event.payload_digest`, requires `event.payload_artifact: true`, and uploads `.buildkite-gha/events/<sha256>.json` from the real execution job. It then passes that job's UUID to `run-job --artifact-producer`. The decoded event limit is 64 KiB. An event source cannot override `plan.producer`; without one, local plans must not require an event artifact. Importers retain their own workflow size limits. Payload bytes are not diagnostic output.

The runtime URL must point to a raw executable over HTTPS, without credentials or a fragment. SHA-256 is mandatory. The platform must match the host: `linux/amd64`, `linux/arm64`, `darwin/arm64`, or `windows/amd64`. Acquisition reuses the platform-and-digest cache and verifies the private copy before execution. A missing or corrupt entry downloads only that pinned URL. Execution never reads release metadata or resolves `latest`, including on retries or clean checkouts.

Start the command hook as root or as `runner` with passwordless sudo, on a disposable Linux worker. In addition to the acquisition dependencies, setup requires `getent`, `useradd`, `usermod`, `install`, `sudo`, `chown`, `chmod`, and `find`; Docker socket access may require `groupadd`. Artifact references require `buildkite-agent`. Setup provisions the same non-root `runner` identity, `/home/runner`, passwordless sudo and Docker socket access as the existing generated Linux bootstrap. It grants access to the agent's Job API socket, keeps the plan and executable root-owned and non-writable by `runner`, and preserves PATH, the incoming umask, and runtime job credentials. This is compatibility setup, not a security boundary against a workflow with sudo.

`hosted-tool-cache: true` grants `runner` access to an existing `/opt/hostedtoolcache` on Linux and passes `--hosted-tool-cache` to the runtime. It defaults to false. An existing `BUILDKITE_GHA_MISE_DATA_DIR` and its sibling `runtime` directory are made writable by `runner`; the runtime still owns tool installation. Runtime execution does not set `MISE_DATA_DIR` to the launcher's binary cache. Custom cache-volume ownership remains on the existing launcher.

macOS keeps the agent's current identity, HOME and PATH. When hosted tool caching is enabled, setup creates `/Users/runner/hostedtoolcache` and grants the current user ownership, matching the generated macOS launcher. It requires passwordless sudo for that setup, not Linux user provisioning.

Windows uses the native `command.ps1` hook with PowerShell 7, `curl.exe`, and `buildkite-agent`. It keeps the agent's identity and environment, verifies bytes with SHA-256, and preserves the runtime exit status. Its cache uses `BUILDKITE_GHA_CACHE_DIR`, `MISE_DATA_DIR`, or `BUILDKITE_AGENT_DATA_PATH` in the same order as Unix, then `%LOCALAPPDATA%/buildkite-gha`. Windows supports execution only, not imports.

`namespace: true` selects native Namespace image setup on Linux or macOS: single-node Docker builders load their output into the local daemon; multi-node builders still require `--load`. Linux also restores image tool paths from `/etc/environment` and enables runtime hostname repair. It does not select agents or enable hosted tool caching; those remain the producer's decisions. Do not set it for other worker images.

The released `run-job` command still validates the plan format, required capabilities, runtime digest, host and target, and hydrates digest-bound event artifacts. Its exit status passes through unchanged (for example, a failed workflow shell command normally yields runtime status 1, not the shell command's status). Existing emitted commands and importer configuration are unchanged. Continuation uploads retain their existing path.

## Run local checks

Install [mise](https://mise.jdx.dev/), then run:

```bash
mise install
mise run check
```

Mise manages contributor tools only, not importer installation. The importer dependencies are listed in [`plugin.yml`](plugin.yml).

The offline Bats suite tests the plugin boundary: acquisition configuration, platform selection, HTTPS download policy, API digest verification, cache reuse and repair, release metadata handoff, unchanged CLI configuration, exit status, and temporary-file cleanup. It uses real executable hashes, a fake download transport, and a recording executable. Workflow behavior belongs in the CLI's tests, not simulated CLI implementations here. ShellCheck checks the hook; CI also runs the Buildkite plugin linter.

## CI smoke coverage

[`.buildkite/pipeline.yml`](.buildkite/pipeline.yml) defaults to the historical CLI pin `0.107.1` and the current build's full plugin commit, including native macOS importers. For a release compatibility check, set the build environment variable `PLUGIN_SMOKE_VERSION` to an exact stable CLI version or `latest`. Set `PLUGIN_SMOKE_REF` to an immutable plugin version or full commit to check the same workflows with an older plugin. Normal CI keeps the historical defaults.

The released-runtime smoke graphs cover:

- Linux default and explicit images with the dedicated `runner` user.
- A Linux-to-macOS dependency and a macOS-only graph, imported from Linux.
- The same mixed and macOS-only fixtures imported from native macOS arm64.

These checks exercise real released CLI integration on Linux x86-64 and native macOS arm64 agents. They do not exercise Windows or Linux arm64 agents, custom binaries, secrets, or a cache service. Source builds are not part of plugin acquisition or CI. Do not add manual hosted builds or releases to local checks.

For an explicitly authorized disposable Linux launcher proof, set `PLUGIN_PINNED_RUNTIME_PROOF=1`. This replaces the normal smoke graph with one released-v0.129.0 importer and one execution job. The job runs the emitted legacy command and the candidate hook from the exact checkout against the same saved plan. It compares identity, permissions, output and exit status, reads a harmless variable through the real Job API, and checks cold/warm downloads and bad-digest rejection. Artifact uploads and downloads use the real agent; the proof only intercepts pipeline emission to install the comparison command. It does not exercise plugin checkout installation, cross-worker cache persistence or other platforms.

For the four-platform scheduled plugin gate, set `PLUGIN_PINNED_RUNTIME_PROOF=platforms`, `GITHUB_EVENT_NAME=workflow_dispatch`, and `PINNED_PROOF_LINUX_QUEUE`, `PINNED_PROOF_ARM_QUEUE`, `PINNED_PROOF_MAC_QUEUE`, and `PINNED_PROOF_WINDOWS_QUEUE` to existing matching queues. `PINNED_PROOF_VERSION` defaults to `0.133.0`; `PINNED_PROOF_PLUGIN_REF` defaults to the build commit. Run with `PINNED_PROOF_PLAN_SOURCE=producer` and again with `inline` or `env`. Set `PINNED_PROOF_NAMESPACE=1` with a compatible Linux queue to exercise native image tools and Docker loading. The proof uses released plans and binaries, normal plugin installation, cross-platform output transport, provider tokens, and allowed-failure commands. It replaces legacy commands with the plugin contract before scheduling, so it proves the consumer, not unchanged importer emission. Inspect job logs, result manifests, and the `platform-runtime-plans.json` receipt; a green soft-failed job alone does not prove its workflow ran. Later importer gates must schedule their emitted jobs unchanged. None of these checks proves cross-worker cache reuse or scheduler retries.

## Release the plugin

Plugin releases are immutable Git tags with asset-free GitHub Releases. The release tasks require `gh` authenticated with write access to `buildkite-plugins/github-actions-buildkite-plugin`:

```bash
mise exec -- gh auth login
mise exec -- gh auth setup-git
```

Before tagging:

1. Deploy and verify the Buildkite release-metadata endpoint before publishing a plugin that uses it. Keep the endpoint available after promotion, including for retries with pinned plugin versions.
1. Confirm the recommended CLI has a public release and the documented behavior is shipped. Do not advertise custom-binary support until its companion CLI support ships.
1. Review the current product compatibility and security documentation.
1. Update every `github-actions#vX.Y.Z` reference in `README.md` to the plugin version being released.
1. Wait for the Buildkite build for `main` to pass, including released-runtime smokes.

From a clean, up-to-date local `main`:

```bash
mise run release:tag vX.Y.Z
```

The task runs local checks and refuses dirty, outdated, existing, or malformed releases. The tag triggers another Buildkite build. After that build passes its static checks and live smokes, publish it:

```bash
mise run release:publish vX.Y.Z
```

The publish task creates or updates the GitHub Release and moves the lightweight `latest` tag with an explicit lease. It refuses backward or divergent promotion and is safe to rerun. CI holds no release-write credential.

Stable `vX.Y.Z` plugin tags stay immutable. `github-actions#latest` follows the manually promoted plugin alias; configuration `version: latest` independently resolves the latest stable CLI release through Buildkite's cached release-metadata endpoint.
