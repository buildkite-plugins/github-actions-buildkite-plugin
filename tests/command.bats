#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  export BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT="$TMP/cache"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW=".github/workflows/ci.yml"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION="0.1.0"
  export MOCK_LOG="$TMP/mock.log"
  mkdir -p "$TMP/bin" "$TMP/payload/runtimes/node20/bin" "$TMP/payload/runtimes/node24/bin"
  : > "$MOCK_LOG"
  printf 'license\n' > "$TMP/payload/LICENSE"
  printf 'node license\n' > "$TMP/payload/runtimes/node20/LICENSE"
  printf 'node license\n' > "$TMP/payload/runtimes/node24/LICENSE"
  cat > "$TMP/payload/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'buildkite-gha 0.1.0'; exit; fi
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  cat > "$TMP/payload/runtimes/node20/bin/node" <<'EOF'
#!/usr/bin/env bash
echo v20.19.0
EOF
  cat > "$TMP/payload/runtimes/node24/bin/node" <<'EOF'
#!/usr/bin/env bash
echo v24.4.0
EOF
  chmod +x "$TMP/payload/buildkite-gha" "$TMP/payload/runtimes/node20/bin/node" "$TMP/payload/runtimes/node24/bin/node"
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
  */checksums.txt) cp "${MOCK_CHECKSUMS:?}" "$out" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  export MOCK_ARCHIVE="$TMP/release.tar.gz" MOCK_CHECKSUMS="$TMP/checksums.txt"
  export PATH="$TMP/bin:$PATH"
}

make_release() {
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" \
    buildkite-gha LICENSE runtimes/node20/bin/node runtimes/node20/LICENSE runtimes/node24/bin/node runtimes/node24/LICENSE
  printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n' "$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')" > "$TMP/checksums.txt"
}

teardown() { rm -rf "$TMP"; }

@test "installs and invokes importer with exact arguments" {
  export TMPDIR="$TMP/work"
  mkdir -p "$TMPDIR"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.1.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.1.0/checksums.txt' "$MOCK_LOG"
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "accepts a leading v and rejects version injection" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=v0.1.0
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION='1.0.0/../../bad'
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"strict pre-1.0 semver"* ]]
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
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" buildkite-gha LICENSE runtimes/node20/bin/node runtimes/node20/LICENSE runtimes/node24/bin/node runtimes/node24/LICENSE evil
  printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n' "$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')" > "$TMP/checksums.txt"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]]
  [ ! -e "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.1.0/Linux_x86_64/evil" ]

  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  rm "$TMP/payload/buildkite-gha"
  ln -s /etc/passwd "$TMP/payload/buildkite-gha"
  make_release
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected, missing, duplicate, or unsafe"* ]]
}

@test "reuses valid cache without downloading" {
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  [ "$(grep -c '^upload ' "$MOCK_LOG")" -eq 1 ]
  run grep -q '^https://' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}

@test "propagates importer failure and never runs importer after install failure" {
  export MOCK_IMPORTER_EXIT=37
  run "$REPO/hooks/command"
  [ "$status" -eq 37 ]
  rm -rf "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"; : > "$MOCK_LOG"; printf 'broken\n' > "$TMP/checksums.txt"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  run grep -q '^upload ' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}
