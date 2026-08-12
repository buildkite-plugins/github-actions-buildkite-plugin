#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  export MOCK_LOG="$TMP/mock.log"
  export BUILDKITE_PLUGIN_CONFIGURATION='{"workflows":".github/workflows/ci.yml","runners":[{"runs-on":"ubuntu-latest","queue":"hosted"}]}'
  export BUILDKITE_COMMIT=1111111111111111111111111111111111111111
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION BUILDKITE_PLUGIN__VERSION
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_MINIMUM_RELEASE_AGE BUILDKITE_PLUGIN__MINIMUM_RELEASE_AGE
  unset MISE_DATA_DIR
  mkdir -p "$TMP/bin"
  : > "$MOCK_LOG"
  cat > "$TMP/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
printf 'runtime=%s %s\n' "$0" "$*" >> "${MOCK_LOG:?}"
printf 'runtime-configuration=%s\n' "${BUILDKITE_PLUGIN_CONFIGURATION:-}" >> "${MOCK_LOG:?}"
printf 'darwin-runtime=%s\n' "${BUILDKITE_GHA_PLUGIN_DEV_DARWIN_RUNTIME:-}" >> "${MOCK_LOG:?}"
printf 'runtime-root-mode=%s\n' "$(stat -c %a "$(dirname "$(dirname "$0")")")" >> "${MOCK_LOG:?}"
[[ "${1:-}" == plugin ]]
[[ "${BUILDKITE_GHA_PLUGIN_DEV_DARWIN_RUNTIME:-}" == /* ]]
[[ -x "$BUILDKITE_GHA_PLUGIN_DEV_DARWIN_RUNTIME" ]]
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  chmod +x "$TMP/buildkite-gha"
  export MOCK_RUNTIME_TEMPLATE="$TMP/buildkite-gha"
  write_mise "$TMP/bin/mise" 2026.8.4
  export PATH="$TMP/bin:$PATH"
}

write_mise() {
  local path="$1" version="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == version ]]; then
  echo "$version linux-x64"
  exit
fi
printf 'mise=%s\n' "\$*" >> "\${MOCK_LOG:?}"
printf 'configuration=%s\n' "\${BUILDKITE_PLUGIN_CONFIGURATION:-}" >> "\${MOCK_LOG:?}"
printf 'commit=%s\n' "\${BUILDKITE_COMMIT:-}" >> "\${MOCK_LOG:?}"
printf 'group=%s\n' "\${BUILDKITE_GROUP_LABEL:-}" >> "\${MOCK_LOG:?}"
printf 'minimum-release-age=%s\n' "\${MISE_MINIMUM_RELEASE_AGE:-}" >> "\${MOCK_LOG:?}"
printf 'github-cli-tokens=%s\n' "\${MISE_GITHUB_GH_CLI_TOKENS:-}" >> "\${MOCK_LOG:?}"
printf 'yes=%s\n' "\${MISE_YES:-}" >> "\${MOCK_LOG:?}"
printf 'cwd=%s\n' "\$PWD" >> "\${MOCK_LOG:?}"
printf 'prereleases=%s\n' "\${MISE_PRERELEASES:-}" >> "\${MOCK_LOG:?}"
printf 'url-replacements=%s\n' "\${MISE_URL_REPLACEMENTS:-}" >> "\${MOCK_LOG:?}"
printf 'installs-dir=%s\n' "\${MISE_INSTALLS_DIR:-}" >> "\${MOCK_LOG:?}"
printf 'credential-command=%s\n' "\${MISE_GITHUB_CREDENTIAL_COMMAND:-}" >> "\${MOCK_LOG:?}"
if [[ "\${1:-}" == --no-config && "\${2:-}" == exec && "\${4:-}" == -- && "\${5:-}" == buildkite-gha && "\${6:-}" == plugin ]]; then
  if [[ -z "\${BUILDKITE_PLUGIN_CONFIGURATION:-}" ]]; then
    echo 'buildkite-gha: plugin: BUILDKITE_PLUGIN_CONFIGURATION is required' >&2
    exit 2
  fi
  exit "\${MOCK_IMPORTER_EXIT:-0}"
fi
if [[ "\${1:-}" == --no-config && "\${2:-}" == exec && "\${3:-}" == go@1.26.5 && "\${4:-}" == -- && "\${5:-}" == env && "\${6:-}" == -u && "\${7:-}" == GOBIN && "\${8:-}" == CGO_ENABLED=0 && "\${9:-}" == GOTOOLCHAIN=local ]]; then
  goos="\${10#GOOS=}"
  goarch="\${11#GOARCH=}"
  gopath="\${12#GOPATH=}"
  gomodcache="\${13#GOMODCACHE=}"
  if [[ "\${14:-}" == go && "\${15:-}" == install && "\${16:-}" == -trimpath && -n "\$goos" && -n "\$goarch" && -n "\$gopath" && -n "\$gomodcache" ]]; then
    printf 'build=%s/%s:%s:%s:%s\n' "\$goos" "\$goarch" "\$gopath" "\$gomodcache" "\${17:-}" >> "\${MOCK_LOG:?}"
    if [[ "\${MOCK_BUILD_FAILURE_PLATFORM:-}" == "\$goos/\$goarch" ]]; then
      exit 42
    fi
    gobin="\$gopath/bin"
    if [[ "\$goos/\$goarch" != linux/amd64 ]]; then
      gobin="\$gobin/\${goos}_\${goarch}"
    fi
    mkdir -p "\$gobin"
    cp "\${MOCK_RUNTIME_TEMPLATE:?}" "\$gobin/buildkite-gha"
    chmod +x "\$gobin/buildkite-gha"
    exit
  fi
fi
exit 64
EOF
  chmod +x "$path"
}

prepare_bootstrap() {
  local payload="$TMP/payload"
  rm -f "$TMP/bin/mise"
  mkdir -p "$payload/mise/bin"
  write_mise "$payload/mise/bin/mise" 2026.8.4
  tar -czf "$TMP/mise.tar.gz" -C "$payload" mise

  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'curl=%s\n' "$*" >> "${MOCK_LOG:?}"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "${MOCK_MISE_ARCHIVE:?}" "$out"
EOF
  cat > "$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf 'sha256sum=%s\n' "$*" >> "${MOCK_LOG:?}"
[[ "${MOCK_CHECKSUM_FAILURE:-}" != 1 ]] || exit 1
printf '%s  %s\n' "${MOCK_MISE_SHA256:?}" "$1"
EOF
  chmod +x "$TMP/bin/curl" "$TMP/bin/sha256sum"
  export MOCK_MISE_ARCHIVE="$TMP/mise.tar.gz"
  export MOCK_MISE_SHA256=7d49c0c3633572f57e2383aec5284067675122b6824990f6ac927c5a40c81994
  export MISE_DATA_DIR="$TMP/mise-data"
  export PATH="$TMP/bin:/usr/bin:/bin"
}

teardown() { rm -rf "$TMP"; }

@test "uses mise from PATH to select latest and invoke the hidden plugin command" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"~~~ :github: Prepare workflows"* ]]
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@latest -- buildkite-gha plugin' "$MOCK_LOG"
  grep -Fx 'minimum-release-age=0s' "$MOCK_LOG"
  grep -Fx 'github-cli-tokens=false' "$MOCK_LOG"
  grep -Fx 'yes=1' "$MOCK_LOG"
  grep -Fx "cwd=$PWD" "$MOCK_LOG"
}

@test "passes exact versions and a configured minimum release age to mise" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=v0.9.0
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_MINIMUM_RELEASE_AGE=24h
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@0.9.0 -- buildkite-gha plugin' "$MOCK_LOG"
  grep -Fx 'minimum-release-age=24h' "$MOCK_LOG"
}

@test "passes a workflow glob to buildkite-gha without shell expansion" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"workflows":".github/workflows/**/*.yml","runners":[{"runs-on":"ubuntu-latest","queue":"hosted"}]}'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx "configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
}

@test "passes an explicit workflow path array to buildkite-gha unchanged" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"workflows":[".github/workflows/ci.yml",".github/workflows/release.yml"],"runners":[{"runs-on":"ubuntu-latest","queue":"hosted"}]}'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx "configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
}

@test "builds paired runtimes from one source commit and runs only Linux with the private Darwin path" {
  commit=abcdef0123456789abcdef0123456789abcdef01
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF="$commit"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"building Linux amd64 and Darwin arm64 runtimes from buildkite-gha source commit $commit with Go 1.26.5"* ]]
  grep -E "^build=linux/amd64:/[^:]+:/[^:]+:github.com/buildkite/buildkite-gha/cmd/buildkite-gha@$commit$" "$MOCK_LOG"
  grep -E "^build=darwin/arm64:/[^:]+:/[^:]+:github.com/buildkite/buildkite-gha/cmd/buildkite-gha@$commit$" "$MOCK_LOG"
  grep -E '^runtime=/[^ ]+/go/bin/buildkite-gha plugin$' "$MOCK_LOG"
  grep -Fx "runtime-configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
  darwin_runtime="$(sed -n 's/^darwin-runtime=//p' "$MOCK_LOG")"
  [[ "$darwin_runtime" == /*/go/bin/darwin_arm64/buildkite-gha ]]
  grep -Fx 'runtime-root-mode=700' "$MOCK_LOG"
  [ ! -e "$darwin_runtime" ]
  grep -Fx 'minimum-release-age=' "$MOCK_LOG"
}

@test "stops and removes source runtimes when a cross-build fails" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF=abcdef0123456789abcdef0123456789abcdef01
  export MOCK_BUILD_FAILURE_PLATFORM=darwin/arm64
  run "$REPO/hooks/command"
  [ "$status" -eq 42 ] || { echo "$output"; false; }
  ! grep -q '^runtime=' "$MOCK_LOG"
  source_gopath="$(sed -n 's/^build=linux\/amd64:\([^:]*\):.*$/\1/p' "$MOCK_LOG")"
  [ -n "$source_gopath" ]
  [ ! -e "${source_gopath%/*}" ]
}

@test "rejects invalid or ambiguous source configuration" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF=main
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected a full lowercase 40-character commit"* ]]
  [ ! -s "$MOCK_LOG" ]

  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF=abcdef0123456789abcdef0123456789abcdef01
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=0.9.0
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version and source-ref are mutually exclusive"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "rejects versions outside the stable plugin contract" {
  for version in 0.8.0 0.9.0-rc.1 01.2.3 main ABCDEF0123456789ABCDEF0123456789ABCDEF01 abcdef0123456789abcdef0123456789abcdef0 '1.0.0/../../bad'; do
    : > "$MOCK_LOG"
    export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION="$version"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected latest or an exact stable release from 0.9.0 onward"* ]]
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "isolates mise settings while preserving an explicit data directory" {
  export MISE_DATA_DIR="$TMP/trusted-mise-data"
  export MISE_MINIMUM_RELEASE_AGE_EXCLUDES='github:*'
  export MISE_PRERELEASES=1
  export MISE_URL_REPLACEMENTS='https://github.com|https://example.test'
  export MISE_INSTALLS_DIR="$TMP/untrusted-installs"
  export MISE_GITHUB_CREDENTIAL_COMMAND='echo credential-command-ran'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'prereleases=' "$MOCK_LOG"
  grep -Fx 'url-replacements=' "$MOCK_LOG"
  grep -Fx 'installs-dir=' "$MOCK_LOG"
  grep -Fx 'credential-command=' "$MOCK_LOG"
}

@test "leaves plugin parsing and Buildkite context normalization to buildkite-gha" {
  export BUILDKITE_COMMIT=HEAD
  export BUILDKITE_GROUP_LABEL="GitHub Actions / checks"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx "configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
  grep -Fx 'commit=HEAD' "$MOCK_LOG"
  grep -Fx 'group=GitHub Actions / checks' "$MOCK_LOG"

  unset BUILDKITE_PLUGIN_CONFIGURATION
  run "$REPO/hooks/command"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BUILDKITE_PLUGIN_CONFIGURATION is required"* ]]
}

@test "passes future behavioral configuration through unchanged" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"workflows":"ci.yml","future":{"nested":[true,3]},"runners":"validated-by-buildkite-gha"}'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx "configuration=$BUILDKITE_PLUGIN_CONFIGURATION" "$MOCK_LOG"
}

@test "ignores legacy aliases and propagates buildkite-gha failures" {
  export BUILDKITE_PLUGIN__VERSION=0.9.0
  export BUILDKITE_PLUGIN__MINIMUM_RELEASE_AGE=7d
  export MOCK_IMPORTER_EXIT=37
  run "$REPO/hooks/command"
  [ "$status" -eq 37 ] || { echo "$output"; false; }
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@latest -- buildkite-gha plugin' "$MOCK_LOG"
  grep -Fx 'minimum-release-age=0s' "$MOCK_LOG"
}

@test "rejects unsupported platforms before invoking mise" {
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

@test "installs a pinned verified mise when it is not on PATH and reuses it" {
  prepare_bootstrap
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"installing mise 2026.8.4"* ]]
  grep -F 'curl=--disable --fail --silent --show-error --location --proto =https --proto-redir =https --tlsv1.2 https://github.com/jdx/mise/releases/download/v2026.8.4/mise-v2026.8.4-linux-x64-musl.tar.gz --output ' "$MOCK_LOG"
  grep -F 'sha256sum=' "$MOCK_LOG"
  [ -x "$MISE_DATA_DIR/github-actions-buildkite-plugin/mise/2026.8.4/mise" ]
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@latest -- buildkite-gha plugin' "$MOCK_LOG"

  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '^curl=' "$MOCK_LOG"
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@latest -- buildkite-gha plugin' "$MOCK_LOG"
}

@test "replaces an old mise and stops when bootstrap verification fails" {
  prepare_bootstrap
  write_mise "$TMP/bin/mise" 2025.1.0
  export MOCK_MISE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mise on PATH is older than 2026.5.12"* ]]
  [[ "$output" == *"mise release archive checksum verification failed"* ]]
  ! grep -q '^mise=--no-config exec ' "$MOCK_LOG"
}
