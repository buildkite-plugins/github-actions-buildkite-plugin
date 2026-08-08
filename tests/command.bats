#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  export REAL_CP="$(command -v cp)"
  export REAL_MKTEMP="$(command -v mktemp)"
  export BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT="$TMP/cache"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW=".github/workflows/ci.yml"
  export BUILDKITE_COMMIT=1111111111111111111111111111111111111111
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION BUILDKITE_PLUGIN__VERSION
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF BUILDKITE_PLUGIN__BUILDKITE_GHA_SOURCE_REF
  export MOCK_LOG="$TMP/mock.log"
  mkdir -p "$TMP/bin" "$TMP/payload"
  : > "$MOCK_LOG"
  printf 'license\n' > "$TMP/payload/LICENSE"
  cat > "$TMP/payload/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'buildkite-gha 0.5.0'; exit; fi
printf 'executable=%s\n' "$0" >> "${MOCK_LOG:?}"
printf 'group=%s\n' "${BUILDKITE_GROUP_LABEL:-}" >> "${MOCK_LOG:?}"
printf 'path=%s\n' "$PATH" >> "${MOCK_LOG:?}"
printf 'commit=%s\n' "${BUILDKITE_COMMIT:-}" >> "${MOCK_LOG:?}"
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  chmod +x "$TMP/payload/buildkite-gha"
  make_release
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
url=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "${MOCK_LOG:?}"
case "$url" in
  */buildkite-gha_Linux_x86_64.tar.gz) cp "${MOCK_ARCHIVE:?}" "$out" ;;
  */checksums.txt) [[ "${MOCK_FAIL_CHECKSUMS:-}" != 1 ]] || exit 22; cp "${MOCK_CHECKSUMS:?}" "$out" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git:%s\n' "$*" >> "${MOCK_LOG:?}"
if [[ "$*" == 'rev-parse --verify HEAD^{commit}' ]]; then
  [[ "${MOCK_CHECKOUT_FAIL:-}" != 1 ]] || exit 1
  printf '%s\n' "${MOCK_CHECKOUT_SHA:-2222222222222222222222222222222222222222}"
  exit 0
fi
if [[ "$*" == 'ls-remote --exit-code --refs https://github.com/buildkite/buildkite-gha.git refs/heads/main' ]]; then
  if [[ -n "${MOCK_SOURCE_OUTPUT:-}" ]]; then
    printf '%s' "$MOCK_SOURCE_OUTPUT"
    exit 0
  fi
  printf '%s\trefs/heads/main\n' "${MOCK_SOURCE_SHA:?}"
  exit 0
fi
exit 2
EOF
  chmod +x "$TMP/bin/git"
  export MOCK_ARCHIVE="$TMP/release.tar.gz" MOCK_CHECKSUMS="$TMP/checksums.txt"
  export PATH="$TMP/bin:$PATH"
  export EXPECTED_PATH="$PATH"
}

make_release() {
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" buildkite-gha LICENSE
  printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n' "$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')" > "$TMP/checksums.txt"
}

mock_source_tools() {
  export MOCK_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
  cat > "$TMP/bin/mise" <<'EOF'
#!/usr/bin/env bash
printf 'mise:%s\n' "$*" >> "${MOCK_LOG:?}"
printf 'source-env:MISE_YES=%s\n' "${MISE_YES:-}" >> "${MOCK_LOG:?}"
[[ "${MOCK_MISE_FAIL:-}" != 1 ]] || exit 1
[[ "$*" == '--no-config x go@1.26.5 -- env CGO_ENABLED=0 GOTOOLCHAIN=local go run -trimpath github.com/buildkite/buildkite-gha/cmd/buildkite-gha@'*' upload '* ]] || exit 2
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  chmod +x "$TMP/bin/mise"
}

teardown() { rm -rf "$TMP"; }

@test "installs and invokes importer with exact arguments" {
  export TMPDIR="$TMP/work"
  mkdir -p "$TMPDIR"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.5.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.5.0/checksums.txt' "$MOCK_LOG"
  grep -Fx "path=$EXPECTED_PATH" "$MOCK_LOG"
  [ "$output" = "~~~ :github: Prepare workflow" ]
  run grep -F 'github.com/jdx/mise' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "resolves a symbolic Buildkite commit to the checked-out commit" {
  export BUILDKITE_COMMIT=HEAD
  export MOCK_CHECKOUT_SHA=abcdef0123456789abcdef0123456789abcdef01
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'git:rev-parse --verify HEAD^{commit}' "$MOCK_LOG"
  grep -Fx "commit=$MOCK_CHECKOUT_SHA" "$MOCK_LOG"
}

@test "preserves an existing valid Buildkite commit" {
  export BUILDKITE_COMMIT=fedcba9876543210fedcba9876543210fedcba98
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx "commit=$BUILDKITE_COMMIT" "$MOCK_LOG"
  ! grep -q '^git:rev-parse ' "$MOCK_LOG"
}

@test "fails without invoking importer when the checked-out commit cannot be resolved" {
  export BUILDKITE_COMMIT=HEAD
  export MOCK_CHECKOUT_FAIL=1
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to resolve the checked-out commit"* ]]
  grep -Fx 'git:rev-parse --verify HEAD^{commit}' "$MOCK_LOG"
  ! grep -q '^upload ' "$MOCK_LOG"
}

@test "opts into private checkout only when explicitly enabled" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_PRIVATE_CHECKOUT=true
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'upload --private-checkout --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"

  : > "$MOCK_LOG"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_PRIVATE_CHECKOUT=false
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"

  : > "$MOCK_LOG"
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_PRIVATE_CHECKOUT
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"

  # An empty value falls back to the unprivileged default, as `version` does.
  : > "$MOCK_LOG"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_PRIVATE_CHECKOUT=
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
}

@test "rejects a non-boolean private-checkout without running importer" {
  for value in yes 1 TRUE ' true' '--event-path'; do
    : > "$MOCK_LOG"
    export BUILDKITE_PLUGIN_GITHUB_ACTIONS_PRIVATE_CHECKOUT="$value"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ] || { echo "accepted '$value'"; false; }
    [[ "$output" == *"private-checkout must be true or false"* ]]
    run grep -q '^upload ' "$MOCK_LOG"
    [ "$status" -eq 1 ]
  done
}

@test "preserves the workflow group label for the importer" {
  export BUILDKITE_GROUP_LABEL="GitHub Actions / checks"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'group=GitHub Actions / checks' "$MOCK_LOG"
}

@test "accepts a leading v and rejects version injection" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=v0.5.0
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION='1.0.0/../../bad'
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"strict pre-1.0 semver"* ]]
}

@test "builds latest source at its resolved main commit" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF=latest
  mock_source_tools
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"buildkite-gha source latest resolved to $MOCK_SOURCE_SHA"* ]]
  grep -Fx 'git:ls-remote --exit-code --refs https://github.com/buildkite/buildkite-gha.git refs/heads/main' "$MOCK_LOG"
  grep -Fx "mise:--no-config x go@1.26.5 -- env CGO_ENABLED=0 GOTOOLCHAIN=local go run -trimpath github.com/buildkite/buildkite-gha/cmd/buildkite-gha@$MOCK_SOURCE_SHA upload --runtime-queue hosted .github/workflows/ci.yml" "$MOCK_LOG"
  grep -Fx 'source-env:MISE_YES=1' "$MOCK_LOG"
  run grep -F 'releases/download' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}

@test "builds an exact source commit without resolving latest" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF=abcdef0123456789abcdef0123456789abcdef01
  mock_source_tools
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '^git:' "$MOCK_LOG"
  grep -Fx 'mise:--no-config x go@1.26.5 -- env CGO_ENABLED=0 GOTOOLCHAIN=local go run -trimpath github.com/buildkite/buildkite-gha/cmd/buildkite-gha@abcdef0123456789abcdef0123456789abcdef01 upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
}

@test "rejects invalid or ambiguous source configuration without running importer" {
  mock_source_tools
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF=latest
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=0.5.0
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version and buildkite-gha-source-ref are mutually exclusive"* ]]

  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF=main
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected latest or a full lowercase 40-character commit"* ]]

  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF=latest
  export MOCK_SOURCE_OUTPUT="$MOCK_SOURCE_SHA refs/heads/main
$MOCK_SOURCE_SHA refs/heads/main
"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not resolve to exactly one commit"* ]]
}

@test "source build failure does not fall back to a release" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_BUILDKITE_GHA_SOURCE_REF=latest
  export MOCK_MISE_FAIL=1
  mock_source_tools
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  ! grep -E 'releases/download|^upload ' "$MOCK_LOG"
}

@test "requires workflow and rejects unsupported platform" {
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workflow is required"* ]]
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW=--event-path
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workflow must be a path"* ]]
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW=x
  cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -s ]] && echo Darwin || echo arm64
EOF
  chmod +x "$TMP/bin/uname"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only Linux x86-64"* ]]
}

@test "rejects missing malformed duplicate and mismatched checksums without running importer" {
  for content in '' 'not-a-checksum' "$(printf '%064d  buildkite-gha_Linux_x86_64.tar.gz\n%064d  buildkite-gha_Linux_x86_64.tar.gz' 0 0)" "$(printf '%064d  buildkite-gha_Linux_x86_64.tar.gz' 0)"; do
    rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"; printf '%s\n' "$content" > "$TMP/checksums.txt"; : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    ! grep -q '^upload ' "$MOCK_LOG"
  done
}

@test "rejects unexpected content and symlinks before extraction" {
  printf 'bad\n' > "$TMP/payload/evil"
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" buildkite-gha LICENSE evil
  printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n' "$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')" > "$TMP/checksums.txt"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]] || { echo "$output"; false; }
  [ ! -e "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.5.0/Linux_x86_64/evil" ]

  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  rm "$TMP/payload/buildkite-gha"
  ln -s /etc/passwd "$TMP/payload/buildkite-gha"
  make_release
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]]
}

@test "reuses a remotely verified cached archive in a private directory" {
  export TMPDIR="$TMP/work"
  mkdir -p "$TMPDIR"
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  [ "$(grep -c '^upload ' "$MOCK_LOG")" -eq 1 ]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.5.0/checksums.txt' "$MOCK_LOG"
  run grep -q '/buildkite-gha_Linux_x86_64.tar.gz$' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  executable="$(awk -F= '/^executable=/ { print $2 }' "$MOCK_LOG")"
  [[ "$executable" == "$TMPDIR"/github-actions-buildkite-plugin-run.*/buildkite-gha ]]
  [[ "$executable" != "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"/* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "replaces a tampered cached archive before execution" {
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  cache="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.5.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz"
  mkdir "$TMP/tampered"
  printf 'license\n' > "$TMP/tampered/LICENSE"
  cat > "$TMP/tampered/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'buildkite-gha 0.5.0'; exit; fi
echo tampered >> "${MOCK_LOG:?}"
EOF
  chmod +x "$TMP/tampered/buildkite-gha"
  tar -czf "$cache" -C "$TMP/tampered" buildkite-gha LICENSE
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run grep -q '^tampered$' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.5.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  [ "$(grep -c '^upload ' "$MOCK_LOG")" -eq 1 ]
}

@test "fails closed when cached archive cannot be checked upstream" {
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  export MOCK_FAIL_CHECKSUMS=1
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  run grep -q '^upload ' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}

@test "uses an attached hosted cache volume" {
  unset BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT
  export BUILDKITE_COMPUTE_TYPE=hosted
  export BUILDKITE_AGENT_DATA_PATH="$TMP/agent"
  export MISE_HOSTED_CACHE_VOLUME_ROOT="$TMP/hosted-cache"
  mkdir -p "$MISE_HOSTED_CACHE_VOLUME_ROOT"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MISE_HOSTED_CACHE_VOLUME_ROOT/github-actions-buildkite-plugin/v0.5.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz" ]
  [ ! -e "$BUILDKITE_AGENT_DATA_PATH/cache/github-actions-buildkite-plugin" ]
}

@test "falls back to the agent cache when the hosted volume is unavailable" {
  unset BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT
  export BUILDKITE_COMPUTE_TYPE=hosted
  export BUILDKITE_AGENT_DATA_PATH="$TMP/agent"
  export MISE_HOSTED_CACHE_VOLUME_ROOT="$TMP/not-attached"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$BUILDKITE_AGENT_DATA_PATH/cache/github-actions-buildkite-plugin/v0.5.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz" ]
}

@test "falls back when an explicit test cache override is unavailable" {
  printf 'not a directory\n' > "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"cache '$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT' is unavailable; using a temporary cache"* ]]
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
}

@test "continues when the verified CLI archive cannot be cached" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.5.0"
  cat > "$TMP/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'/v0.5.0/.Linux_x86_64.'* ]]; then exit 1; fi
exec "${REAL_MKTEMP:?}" "$@"
EOF
  chmod +x "$TMP/bin/mktemp"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"continuing without caching"* ]]
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
  [ ! -e "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.5.0/Linux_x86_64" ]
}

@test "downloads after a cached archive copy fails partway" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cat > "$TMP/bin/cp" <<'EOF'
#!/usr/bin/env bash
destination="${!#}"
if [[ "$*" == *'/cache/v0.5.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz'* ]]; then
  printf 'partial\n' > "$destination"
  exit 1
fi
exec "${REAL_CP:?}" "$@"
EOF
  chmod +x "$TMP/bin/cp"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.5.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
}

@test "concurrent installs converge on one valid cache" {
  "$REPO/hooks/command" >"$TMP/first.out" 2>&1 & first=$!
  "$REPO/hooks/command" >"$TMP/second.out" 2>&1 & second=$!
  wait "$first"
  wait "$second"
  destination="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.5.0/Linux_x86_64"
  [ -L "$destination" ]
  cached_archive="$destination/buildkite-gha_Linux_x86_64.tar.gz"
  [ -f "$cached_archive" ]
  expected="$(awk '$2 == "buildkite-gha_Linux_x86_64.tar.gz" { print $1 }' "$TMP/checksums.txt")"
  [ "$(/usr/bin/sha256sum "$cached_archive" | awk '{ print $1 }')" = "$expected" ]
  [ "$(grep -c '^upload --runtime-queue hosted ' "$MOCK_LOG")" -eq 2 ]
}

@test "propagates importer failure and never runs importer after install failure" {
  export MOCK_IMPORTER_EXIT=37
  run "$REPO/hooks/command"
  [ "$status" -eq 37 ] || { echo "$output"; false; }
  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"; : > "$MOCK_LOG"; printf 'broken\n' > "$TMP/checksums.txt"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  run grep -q '^upload ' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}
