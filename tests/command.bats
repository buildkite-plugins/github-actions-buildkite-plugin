#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  export BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT="$TMP/cache"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_WORKFLOW=".github/workflows/ci.yml"
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION="0.1.0"
  export MOCK_LOG="$TMP/mock.log"
  mkdir -p "$TMP/bin" "$TMP/payload/mise/bin"
  : > "$MOCK_LOG"
  printf 'license\n' > "$TMP/payload/LICENSE"
  cat > "$TMP/payload/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'buildkite-gha 0.1.0'; exit; fi
printf 'executable=%s\n' "$0" >> "${MOCK_LOG:?}"
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  cat > "$TMP/payload/mise/bin/mise" <<'EOF'
#!/usr/bin/env bash
echo '2026.5.12 linux-x64 (test)'
EOF
  chmod +x "$TMP/payload/buildkite-gha" "$TMP/payload/mise/bin/mise"
  make_release
  tar -czf "$TMP/mise.tar.gz" -C "$TMP/payload" mise
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
  */mise-v2026.5.12-linux-x64.tar.gz) cp "${MOCK_MISE_ARCHIVE:?}" "$out" ;;
  */buildkite-gha_Linux_x86_64.tar.gz) cp "${MOCK_ARCHIVE:?}" "$out" ;;
  */checksums.txt) [[ "${MOCK_FAIL_CHECKSUMS:-}" != 1 ]] || exit 22; cp "${MOCK_CHECKSUMS:?}" "$out" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  cat > "$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  */mise-v2026.5.12-linux-x64.tar.gz)
    if [[ "${MOCK_BAD_MISE_CHECKSUM:-}" == 1 ]]; then
      printf '%064d  %s\n' 0 "$1"
    else
      printf 'bd0930c0b619f51ddb60e32e5cce18a5533567b2f1ba9fc4875b9f39a2bb3ed8  %s\n' "$1"
    fi
    ;;
  */mise/bin/mise) printf 'a238972a3162d710b85b28c324372e96ca4e4b486c81fe78695000d9fbc77c48  %s\n' "$1" ;;
  *) exec /usr/bin/sha256sum "$@" ;;
esac
EOF
  chmod +x "$TMP/bin/curl" "$TMP/bin/sha256sum"
  export MOCK_ARCHIVE="$TMP/release.tar.gz" MOCK_CHECKSUMS="$TMP/checksums.txt" MOCK_MISE_ARCHIVE="$TMP/mise.tar.gz"
  export PATH="$TMP/bin:$PATH"
}

make_release() {
  tar -czf "$TMP/release.tar.gz" -C "$TMP/payload" buildkite-gha LICENSE
  printf '%s  buildkite-gha_Linux_x86_64.tar.gz\n' "$(sha256sum "$TMP/release.tar.gz" | awk '{print $1}')" > "$TMP/checksums.txt"
}

teardown() { rm -rf "$TMP"; }

@test "installs and invokes importer with exact arguments" {
  export TMPDIR="$TMP/work"
  mkdir -p "$TMPDIR"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'upload --runtime-queue hosted .github/workflows/ci.yml' "$MOCK_LOG"
  grep -Fx 'https://github.com/jdx/mise/releases/download/v2026.5.12/mise-v2026.5.12-linux-x64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.1.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.1.0/checksums.txt' "$MOCK_LOG"
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "accepts a leading v and rejects version injection" {
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=v0.1.0
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
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

@test "rejects a mise archive checksum mismatch before installing the CLI" {
  export MOCK_BAD_MISE_CHECKSUM=1
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mise archive checksum verification failed"* ]]
  run grep -q '/buildkite-gha/releases/' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}

@test "rejects an unexpected mise version before installing the CLI" {
  cat > "$TMP/payload/mise/bin/mise" <<'EOF'
#!/usr/bin/env bash
echo '2026.5.13 linux-x64 (test)'
EOF
  chmod +x "$TMP/payload/mise/bin/mise"
  tar -czf "$TMP/mise.tar.gz" -C "$TMP/payload" mise
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extracted mise executable failed validation"* ]]
  run grep -q '/buildkite-gha/releases/' "$MOCK_LOG"
  [ "$status" -eq 1 ]
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
  [ ! -e "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.1.0/Linux_x86_64/evil" ]

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
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.1.0/checksums.txt' "$MOCK_LOG"
  run grep -q '/buildkite-gha_Linux_x86_64.tar.gz$' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  executable="$(awk -F= '/^executable=/ { print $2 }' "$MOCK_LOG")"
  [[ "$executable" == "$TMPDIR"/github-actions-buildkite-plugin-run.*/buildkite-gha ]]
  [[ "$executable" != "$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"/* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "replaces a tampered cached archive before execution" {
  run "$REPO/hooks/command"; [ "$status" -eq 0 ]
  cache="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.1.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz"
  mkdir "$TMP/tampered"
  printf 'license\n' > "$TMP/tampered/LICENSE"
  cat > "$TMP/tampered/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'buildkite-gha 0.1.0'; exit; fi
echo tampered >> "${MOCK_LOG:?}"
EOF
  chmod +x "$TMP/tampered/buildkite-gha"
  tar -czf "$cache" -C "$TMP/tampered" buildkite-gha LICENSE
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run grep -q '^tampered$' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.1.0/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
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
  [ -x "$MISE_HOSTED_CACHE_VOLUME_ROOT/github-actions-buildkite-plugin/mise/v2026.5.12/Linux_x86_64/mise/bin/mise" ]
  [ -f "$BUILDKITE_AGENT_DATA_PATH/cache/github-actions-buildkite-plugin/v0.1.0/Linux_x86_64/buildkite-gha_Linux_x86_64.tar.gz" ]
}

@test "replaces a mise cache containing unverified siblings" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mise_dir="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/mise/v2026.5.12/Linux_x86_64/mise/bin"
  printf '#!/bin/sh\nexit 99\n' > "$mise_dir/curl"
  chmod +x "$mise_dir/curl"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fx 'https://github.com/jdx/mise/releases/download/v2026.5.12/mise-v2026.5.12-linux-x64.tar.gz' "$MOCK_LOG"
  [ ! -e "$mise_dir/curl" ]
}

@test "concurrent installs converge on one valid cache" {
  "$REPO/hooks/command" >"$TMP/first.out" 2>&1 & first=$!
  "$REPO/hooks/command" >"$TMP/second.out" 2>&1 & second=$!
  wait "$first"
  wait "$second"
  destination="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/v0.1.0/Linux_x86_64"
  mise_destination="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT/mise/v2026.5.12/Linux_x86_64"
  [ -L "$destination" ]
  [ -L "$mise_destination" ]
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
