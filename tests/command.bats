#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  export REAL_CP="$(command -v cp)"
  export REAL_CHMOD="$(command -v chmod)"
  export REAL_MKTEMP="$(command -v mktemp)"
  export BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT="$TMP/cache"
  export BUILDKITE_PLUGIN_CONFIGURATION='{"workflow":".github/workflows/ci.yml","version":"latest","runners":[{"runs-on":"ubuntu-latest","queue":"hosted","image":"registry.example.com/ci/linux@sha256:04a6656f92b90269b3259fffaba67e08a3d03d8dc79b40d45c9ac3d9000e9e03"},{"runs-on":"macos-14","queue":"macos-sonoma-arm64"}]}'
  export BUILDKITE_COMMIT=1111111111111111111111111111111111111111
  export MOCK_CLI_VERSION=0.9.0
  export MOCK_LATEST_URL=https://github.com/buildkite/buildkite-gha/releases/tag/v0.9.0
  export MOCK_LOG="$TMP/mock.log"
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION BUILDKITE_PLUGIN__VERSION
  unset BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_LINUX_AMD64 BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_DARWIN_ARM64
  unset BUILDKITE_USE_REPOSITORY_PROVIDER_GIT_CREDENTIALS BUILDKITE_USE_GITHUB_APP_GIT_CREDENTIALS
  mkdir -p "$TMP/bin" "$TMP/payload" "$TMP/darwin-payload"
  : > "$MOCK_LOG"
  printf 'license\n' > "$TMP/payload/LICENSE"
  printf 'license\n' > "$TMP/darwin-payload/LICENSE"
  cat > "$TMP/payload/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  echo "buildkite-gha ${MOCK_CLI_VERSION:-0.9.0}"
  exit
fi
printf 'executable=%s\n' "$0" >> "${MOCK_LOG:?}"
printf 'args=%s\n' "$*" >> "${MOCK_LOG:?}"
printf 'configuration=%s\n' "${BUILDKITE_PLUGIN_CONFIGURATION:-}" >> "${MOCK_LOG:?}"
printf 'linux-runtime=%s\n' "${BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_LINUX_AMD64:-}" >> "${MOCK_LOG:?}"
printf 'darwin-runtime=%s\n' "${BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_DARWIN_ARM64:-}" >> "${MOCK_LOG:?}"
printf 'commit=%s\n' "${BUILDKITE_COMMIT:-}" >> "${MOCK_LOG:?}"
printf 'group=%s\n' "${BUILDKITE_GROUP_LABEL:-}" >> "${MOCK_LOG:?}"
if [[ "${1:-}" != plugin || $# -ne 1 ]]; then
  exit 90
fi
if [[ -z "${BUILDKITE_PLUGIN_CONFIGURATION:-}" ]]; then
  echo 'buildkite-gha: plugin: BUILDKITE_PLUGIN_CONFIGURATION is required' >&2
  exit 2
fi
[[ -x "${BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_LINUX_AMD64:-}" ]] || exit 91
[[ -x "${BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_DARWIN_ARM64:-}" ]] || exit 92
printf 'linux-mode=%s\n' "$(stat -c %a "$BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_LINUX_AMD64")" >> "${MOCK_LOG:?}"
printf 'darwin-mode=%s\n' "$(stat -c %a "$BUILDKITE_GHA_PLUGIN_RUNTIME_DISTRIBUTION_DARWIN_ARM64")" >> "${MOCK_LOG:?}"
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  chmod +x "$TMP/payload/buildkite-gha"
  printf '\317\372\355\376darwin-arm64-test-payload\n' > "$TMP/darwin-payload/buildkite-gha"
  chmod 0644 "$TMP/darwin-payload/buildkite-gha"
  make_release
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == --disable ]] || exit 3
printf 'curl:%s\n' "$*" >> "${MOCK_LOG:?}"
url=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    -w|--write-out) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "${MOCK_LOG:?}"
case "$url" in
  https://github.com/buildkite/buildkite-gha/releases/latest)
    [[ "${MOCK_FAIL_LATEST:-}" != 1 ]] || exit 22
    printf '%s' "${MOCK_LATEST_URL:?}"
    ;;
  */buildkite-gha_Linux_x86_64.tar.gz)
    cp "${MOCK_LINUX_ARCHIVE:?}" "$out"
    ;;
  */buildkite-gha_Darwin_arm64.tar.gz)
    cp "${MOCK_DARWIN_ARCHIVE:?}" "$out"
    ;;
  */checksums.txt)
    [[ "${MOCK_FAIL_CHECKSUMS:-}" != 1 ]] || exit 22
    cp "${MOCK_CHECKSUMS:?}" "$out"
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  export MOCK_LINUX_ARCHIVE="$TMP/release.tar.gz"
  export MOCK_DARWIN_ARCHIVE="$TMP/darwin-release.tar.gz"
  export MOCK_CHECKSUMS="$TMP/checksums.txt"
  export PATH="$TMP/bin:$PATH"
}

make_release() {
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" buildkite-gha LICENSE
  tar -czf "$TMP/darwin-release.tar.gz" -C "$TMP/darwin-payload" buildkite-gha LICENSE
  write_checksums
}

write_checksums() {
  printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n%s  buildkite-gha_Darwin_arm64.tar.gz\n' \
    "$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')" \
    "$(sha256sum "$TMP/darwin-release.tar.gz" | awk '{print $1}')" > "$TMP/checksums.txt"
}

assert_plugin_invocation() {
  local linux_runtime darwin_runtime distribution
  grep -Fx 'args=plugin' "$MOCK_LOG"
  ! grep -q '^args=upload' "$MOCK_LOG"
  grep -Fx "configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
  linux_runtime="$(sed -n 's/^linux-runtime=//p' "$MOCK_LOG" | tail -1)"
  darwin_runtime="$(sed -n 's/^darwin-runtime=//p' "$MOCK_LOG" | tail -1)"
  distribution="$(dirname "$(dirname "$linux_runtime")")"
  [ "$linux_runtime" = "$distribution/Linux_x86_64/buildkite-gha" ]
  [ "$darwin_runtime" = "$distribution/Darwin_arm64/buildkite-gha" ]
  [[ "$distribution" = /* ]]
  [[ "$distribution" != "${BUILDKITE_BUILD_CHECKOUT_PATH:-$REPO}"/* ]]
}

teardown() { rm -rf "$TMP"; }

@test "resolves latest, stages paired distributions, and invokes only plugin" {
  export TMPDIR="$TMP/work"
  export BUILDKITE_BUILD_CHECKOUT_PATH="$REPO"
  mkdir -p "$TMPDIR"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"latest buildkite-gha release resolved to v0.9.0"* ]]
  [[ "$output" == *"~~~ :github: Prepare workflow"* ]]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/latest' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/checksums.txt' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/buildkite-gha_Darwin_arm64.tar.gz' "$MOCK_LOG"
  [ "$(grep -c '^curl:--disable ' "$MOCK_LOG")" -eq 4 ]
  grep -Fx 'linux-mode=755' "$MOCK_LOG"
  grep -Fx 'darwin-mode=755' "$MOCK_LOG"
  assert_plugin_invocation
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "uses an exact pinned stable release without resolving latest" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=v0.8.1
  export MOCK_CLI_VERSION=0.8.1
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '/releases/latest$' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.8.1/checksums.txt' "$MOCK_LOG"
  assert_plugin_invocation

  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  : > "$MOCK_LOG"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=1.0.0
  export MOCK_CLI_VERSION=1.0.0
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v1.0.0/checksums.txt' "$MOCK_LOG"
}

@test "passes plugin configuration and context through without parsing" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"future-syntax":{"nested":[true,3]},"runners":"deliberately-invalid-for-the-real-cli"}'
  export BUILDKITE_COMMIT=HEAD
  export BUILDKITE_GROUP_LABEL="GitHub Actions / checks"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx "configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
  grep -Fx 'commit=HEAD' "$MOCK_LOG"
  grep -Fx 'group=GitHub Actions / checks' "$MOCK_LOG"
  assert_plugin_invocation
}

@test "delegates missing configuration errors and importer failures" {
  unset BUILDKITE_PLUGIN_CONFIGURATION
  run "$REPO/hooks/command"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BUILDKITE_PLUGIN_CONFIGURATION is required"* ]]

  export BUILDKITE_PLUGIN_CONFIGURATION='{"workflow":"ci.yml"}'
  export MOCK_IMPORTER_EXIT=37
  run "$REPO/hooks/command"
  [ "$status" -eq 37 ]
}

@test "ignores legacy acquisition aliases" {
  export BUILDKITE_PLUGIN__VERSION=0.8.0
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/latest' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/checksums.txt' "$MOCK_LOG"
}

@test "rejects invalid versions and unexpected latest redirects" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION='1.0.0/../../bad'
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected latest or an exact stable release newer than 0.8.0"* ]]
  ! grep -q '/releases/download/' "$MOCK_LOG"

  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=0.7.2
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer than 0.8.0"* ]]

  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=0.8.0
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer than 0.8.0"* ]]

  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=0.9.0-rc.1
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exact stable release"* ]]

  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION
  export MOCK_LATEST_URL=https://example.com/buildkite-gha/releases/tag/v0.9.0
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolved to an unexpected URL"* ]]
}

@test "fails when latest cannot be resolved" {
  export MOCK_FAIL_LATEST=1
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to resolve the latest buildkite-gha release"* ]]
  ! grep -q '/releases/download/' "$MOCK_LOG"
}

@test "rejects unsupported importer platforms before resolving a release" {
  cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -s ]] && echo Darwin || echo arm64
EOF
  chmod +x "$TMP/bin/uname"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only Linux x86-64"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "normalizes relative temporary paths to private absolute runtime paths" {
  mkdir "$TMP/work"
  run bash -c 'cd "$1" && TMPDIR=work "$2/hooks/command"' _ "$TMP" "$REPO"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_plugin_invocation
  linux_runtime="$(sed -n 's/^linux-runtime=//p' "$MOCK_LOG")"
  [[ "$linux_runtime" == "$TMP"/work/github-actions-buildkite-plugin-run.*/Linux_x86_64/buildkite-gha ]]
}

@test "ignores inherited tar and gzip execution options" {
  export TAR_OPTIONS="--checkpoint=1 --checkpoint-action=exec=touch $TMP/tar-options-executed"
  export GZIP=-9
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TMP/tar-options-executed" ]
  assert_plugin_invocation
}

@test "rejects missing malformed duplicate and mismatched checksums" {
  linux_checksum="$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')"
  for content in \
    '' \
    'not-a-checksum' \
    "$(printf '%064d  buildkite-gha_Linux_x86_64.tar.gz\n%064d  buildkite-gha_Linux_x86_64.tar.gz' 0 0)" \
    "$(printf '%064d  buildkite-gha_Linux_x86_64.tar.gz' 0)" \
    "$linux_checksum  buildkite-gha_Linux_x86_64.tar.gz" \
    "$(printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n%064d  buildkite-gha_Darwin_arm64.tar.gz\n%064d  buildkite-gha_Darwin_arm64.tar.gz' "$linux_checksum" 0 0)" \
    "$(printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n%064d  buildkite-gha_Darwin_arm64.tar.gz' "$linux_checksum" 0)"; do
    rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
    printf '%s\n' "$content" > "$TMP/checksums.txt"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    ! grep -q '^args=plugin$' "$MOCK_LOG"
  done
}

@test "rejects unexpected archive content and symlinks" {
  printf 'bad\n' > "$TMP/payload/evil"
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" buildkite-gha LICENSE evil
  write_checksums
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]] || { echo "$output"; false; }

  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  rm "$TMP/payload/buildkite-gha"
  ln -s /etc/passwd "$TMP/payload/buildkite-gha"
  make_release
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]]
  ! grep -q '^args=plugin$' "$MOCK_LOG"
}

@test "rejects malformed Darwin archives without executing either distribution" {
  printf 'bad\n' > "$TMP/darwin-payload/extra"
  tar -czf "$TMP/darwin-release.tar.gz" -C "$TMP/darwin-payload" buildkite-gha LICENSE extra
  write_checksums
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]] || { echo "$output"; false; }
  ! grep -q '^args=plugin$' "$MOCK_LOG"
}

@test "validates Darwin archive and mode without executing its binary" {
  cat > "$TMP/darwin-payload/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
echo darwin-was-executed >> "${MOCK_LOG:?}"
exit 86
EOF
  chmod 0644 "$TMP/darwin-payload/buildkite-gha"
  make_release
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '^darwin-was-executed$' "$MOCK_LOG"
  grep -Fx 'darwin-mode=755' "$MOCK_LOG"
}

@test "fails closed when a staged distribution cannot be secured" {
  cat > "$TMP/bin/chmod" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'github-actions-buildkite-plugin-run.'*'/Darwin_arm64'* ]]; then exit 1; fi
exec "${REAL_CHMOD:?}" "$@"
EOF
  chmod +x "$TMP/bin/chmod"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to set CLI distribution executable modes"* ]] || { echo "$output"; false; }
  ! grep -q '^args=plugin$' "$MOCK_LOG"
}

@test "reuses both remotely verified cached archives in a private run directory" {
  export TMPDIR="$TMP/work"
  mkdir -p "$TMPDIR"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/latest' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/checksums.txt' "$MOCK_LOG"
  ! grep -q '/buildkite-gha_Linux_x86_64.tar.gz$' "$MOCK_LOG"
  ! grep -q '/buildkite-gha_Darwin_arm64.tar.gz$' "$MOCK_LOG"
  [ "$(grep -c '^args=plugin$' "$MOCK_LOG")" -eq 1 ]
  executable="$(sed -n 's/^executable=//p' "$MOCK_LOG")"
  [[ "$executable" == "$TMPDIR"/github-actions-buildkite-plugin-run.*/Linux_x86_64/buildkite-gha ]]
  [[ "$executable" != "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"/* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "replaces tampered Linux and Darwin cached archives" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  linux_cache="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.9.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz"
  darwin_cache="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.9.0/Darwin_arm64/buildkite-gha_Darwin_arm64.tar.gz"
  mkdir "$TMP/tampered"
  printf 'license\n' > "$TMP/tampered/LICENSE"
  cat > "$TMP/tampered/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
echo tampered-was-executed >> "${MOCK_LOG:?}"
exit 86
EOF
  chmod +x "$TMP/tampered/buildkite-gha"
  tar -czf "$linux_cache" -C "$TMP/tampered" buildkite-gha LICENSE
  tar -czf "$darwin_cache" -C "$TMP/tampered" buildkite-gha LICENSE
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '^tampered-was-executed$' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/buildkite-gha_Darwin_arm64.tar.gz' "$MOCK_LOG"
  [ "$(grep -c '^args=plugin$' "$MOCK_LOG")" -eq 1 ]
}

@test "fails closed when cached archives cannot be checked upstream" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  export MOCK_FAIL_CHECKSUMS=1
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  ! grep -q '^args=plugin$' "$MOCK_LOG"
}

@test "uses an attached hosted cache and falls back to the agent cache" {
  unset BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT
  export BUILDKITE_COMPUTE_TYPE=hosted
  export BUILDKITE_AGENT_DATA_PATH="$TMP/agent"
  export MISE_HOSTED_CACHE_VOLUME_ROOT="$TMP/hosted-cache"
  mkdir -p "$MISE_HOSTED_CACHE_VOLUME_ROOT"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MISE_HOSTED_CACHE_VOLUME_ROOT/github-actions-buildkite-plugin/v0.9.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz" ]
  [ -f "$MISE_HOSTED_CACHE_VOLUME_ROOT/github-actions-buildkite-plugin/v0.9.0/Darwin_arm64/buildkite-gha_Darwin_arm64.tar.gz" ]
  [ ! -e "$BUILDKITE_AGENT_DATA_PATH/cache/github-actions-buildkite-plugin" ]

  rm -rf "$MISE_HOSTED_CACHE_VOLUME_ROOT"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$BUILDKITE_AGENT_DATA_PATH/cache/github-actions-buildkite-plugin/v0.9.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz" ]
  [ -f "$BUILDKITE_AGENT_DATA_PATH/cache/github-actions-buildkite-plugin/v0.9.0/Darwin_arm64/buildkite-gha_Darwin_arm64.tar.gz" ]
}

@test "falls back when an explicit cache root is unavailable" {
  printf 'not a directory\n' > "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"cache '$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT' is unavailable; using a temporary cache"* ]]
  assert_plugin_invocation
}

@test "continues when a verified archive cannot be cached" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.9.0"
  cat > "$TMP/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'/v0.9.0/.Linux_x86_64.'* ]]; then exit 1; fi
exec "${REAL_MKTEMP:?}" "$@"
EOF
  chmod +x "$TMP/bin/mktemp"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"continuing without caching"* ]]
  [ ! -e "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.9.0/Linux_x86_64" ]
  assert_plugin_invocation
}

@test "downloads after a cached archive copy fails partway" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  cat > "$TMP/bin/cp" <<'EOF'
#!/usr/bin/env bash
destination="${!#}"
if [[ "$*" == *'/cache/v0.9.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz'* ]]; then
  printf 'partial\n' > "$destination"
  exit 1
fi
exec "${REAL_CP:?}" "$@"
EOF
  chmod +x "$TMP/bin/cp"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.9.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  assert_plugin_invocation
}

@test "concurrent installs converge on separate valid platform caches" {
  "$REPO/hooks/command" >"$TMP/first.out" 2>&1 & first=$!
  "$REPO/hooks/command" >"$TMP/second.out" 2>&1 & second=$!
  wait "$first"
  wait "$second"
  for platform in Linux_x86_64 Darwin_arm64; do
    destination="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.9.0/$platform"
    [ -L "$destination" ]
    cached_archive="$destination/buildkite-gha_${platform}.tar.gz"
    [ -f "$cached_archive" ]
    expected="$(awk -v asset="buildkite-gha_${platform}.tar.gz" '$2 == asset { print $1 }' "$TMP/checksums.txt")"
    [ "$(/usr/bin/sha256sum "$cached_archive" | awk '{ print $1 }')" = "$expected" ]
  done
  [ "$(grep -c '^args=plugin$' "$MOCK_LOG")" -eq 2 ]
}

@test "never invokes plugin after installation failure" {
  printf 'broken\n' > "$TMP/checksums.txt"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  ! grep -q '^args=plugin$' "$MOCK_LOG"
}
