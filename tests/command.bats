#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  export MOCK_LOG="$TMP/mock.log"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW=".github/workflows/ci.yml"
  export BUILDKITE_COMMIT=1111111111111111111111111111111111111111
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION BUILDKITE_PLUGIN__VERSION
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF
  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_MINIMUM_RELEASE_AGE BUILDKITE_PLUGIN__MINIMUM_RELEASE_AGE
  unset MISE_DATA_DIR
  mkdir -p "$TMP/bin"
  : > "$MOCK_LOG"
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
printf 'workflow=%s\n' "\${BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW:-}" >> "\${MOCK_LOG:?}"
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
  if [[ -z "\${BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW:-}" ]]; then
    echo 'buildkite-gha: plugin: BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW is required' >&2
    exit 2
  fi
  exit "\${MOCK_IMPORTER_EXIT:-0}"
fi
if [[ "\${1:-}" == --no-config && "\${2:-}" == exec && "\${3:-}" == go@1.26.5 && "\${4:-}" == -- && "\${5:-}" == env && "\${6:-}" == CGO_ENABLED=0 && "\${7:-}" == GOTOOLCHAIN=local && "\${8:-}" == go && "\${9:-}" == run && "\${10:-}" == -trimpath && "\${12:-}" == plugin ]]; then
  exit "\${MOCK_IMPORTER_EXIT:-0}"
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
  [[ "$output" == *"~~~ :github: Prepare workflow"* ]]
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@latest -- buildkite-gha plugin' "$MOCK_LOG"
  grep -Fx 'minimum-release-age=0s' "$MOCK_LOG"
  grep -Fx 'github-cli-tokens=false' "$MOCK_LOG"
  grep -Fx 'yes=1' "$MOCK_LOG"
  grep -Fx "cwd=$PWD" "$MOCK_LOG"
}

@test "passes exact versions and a configured minimum release age to mise" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=v0.8.0
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_MINIMUM_RELEASE_AGE=24h
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'mise=--no-config exec github:buildkite/buildkite-gha@0.8.0 -- buildkite-gha plugin' "$MOCK_LOG"
  grep -Fx 'minimum-release-age=24h' "$MOCK_LOG"
}

@test "builds and runs a full buildkite-gha source commit through mise" {
  commit=abcdef0123456789abcdef0123456789abcdef01
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF="$commit"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"building buildkite-gha source commit $commit with Go 1.26.5"* ]]
  grep -Fx "mise=--no-config exec go@1.26.5 -- env CGO_ENABLED=0 GOTOOLCHAIN=local go run -trimpath github.com/buildkite/buildkite-gha/cmd/buildkite-gha@$commit plugin" "$MOCK_LOG"
  grep -Fx 'minimum-release-age=' "$MOCK_LOG"
}

@test "rejects invalid or ambiguous source configuration" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF=main
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected a full lowercase 40-character commit"* ]]
  [ ! -s "$MOCK_LOG" ]

  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_SOURCE_REF=abcdef0123456789abcdef0123456789abcdef01
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=0.8.0
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version and source-ref are mutually exclusive"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "rejects versions outside the stable plugin contract" {
  for version in 0.7.2 0.8.0-rc.1 01.2.3 main ABCDEF0123456789ABCDEF0123456789ABCDEF01 abcdef0123456789abcdef0123456789abcdef0 '1.0.0/../../bad'; do
    : > "$MOCK_LOG"
    export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION="$version"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected latest or an exact stable release from 0.8.0 onward"* ]]
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
  grep -Fx 'workflow=.github/workflows/ci.yml' "$MOCK_LOG"
  grep -Fx 'commit=HEAD' "$MOCK_LOG"
  grep -Fx 'group=GitHub Actions / checks' "$MOCK_LOG"

  unset BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW
  run "$REPO/hooks/command"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW is required"* ]]
}

@test "ignores legacy aliases and propagates buildkite-gha failures" {
  export BUILDKITE_PLUGIN__VERSION=0.8.0
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
