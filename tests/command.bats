#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
  export TMPDIR="$BATS_TEST_TMPDIR/downloads"
  export MOCK_LOG="$BATS_TEST_TMPDIR/download.log"
  export BUILDKITE_PLUGIN_CONFIGURATION='{}'
  export MOCK_OS=Linux MOCK_ARCH=x86_64
  mkdir -p "$FIXTURE/bin" "$TMPDIR"
  : > "$MOCK_LOG"
  cat > "$FIXTURE/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" > "$FIXTURE/arguments"
printf '%s' "$BUILDKITE_PLUGIN_CONFIGURATION" > "$FIXTURE/configuration"
stat -c %a "$(dirname "$0")" > "$FIXTURE/mode" 2>/dev/null || stat -f %Lp "$(dirname "$0")" > "$FIXTURE/mode"
ls -A "$(dirname "$0")" > "$FIXTURE/files"
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  echo 'not extracted' > "$FIXTURE/LICENSE"
  tar -czf "$FIXTURE/archive.tar.gz" -C "$FIXTURE" buildkite-gha LICENSE
  checksums
  echo '{"tag_name":"v0.107.1"}' > "$FIXTURE/release.json"
  cat > "$FIXTURE/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
# Enforce the transport boundary on every request; never access the network.
[[ "$1" == --disable && "$2" == --fail && "$3" == --silent && "$4" == --show-error && "$5" == --location ]]
[[ "$6" == --globoff && "$7" == --proto && "$8" == '=https' && "$9" == --proto-redir && "${10}" == '=https' && "${11}" == --tlsv1.2 ]]
url="${12}"
[[ "${13}" == --output && $# == 14 && "$url" != *'#'* ]]
printf '%s\n' "$url" >> "$MOCK_LOG"
if [[ -n "${MOCK_FAIL_SUFFIX:-}" && "$url" == *"$MOCK_FAIL_SUFFIX" ]]; then
  echo 'curl: fixture HTTP failure' >&2
  exit 22
fi
case "$url" in
  https://api.github.com/repos/buildkite/buildkite-gha/releases/latest) source=release.json ;;
  https://github.com/buildkite/buildkite-gha/releases/download/*/checksums.txt) source=checksums.txt ;;
  https://github.com/buildkite/buildkite-gha/releases/download/*/buildkite-gha_*.tar.gz) source=archive.tar.gz ;;
  https://example.com/*) source=buildkite-gha ;;
  *) exit 64 ;;
esac
cp "$FIXTURE/$source" "${14}"
EOF
  cat > "$FIXTURE/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -s ]]; then echo "$MOCK_OS"; else echo "$MOCK_ARCH"; fi
EOF
  chmod +x "$FIXTURE/bin/"*
  export PATH="$FIXTURE/bin:$PATH"
}

checksums() {
  local hash
  hash="$(shasum -a 256 "$FIXTURE/archive.tar.gz")"
  for asset in Linux_x86_64 Linux_arm64 Darwin_arm64; do
    printf '%s  buildkite-gha_%s.tar.gz\n' "${hash%% *}" "$asset"
  done > "$FIXTURE/checksums.txt"
}

assert_clean() {
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "resolves latest once, verifies the release, and extracts only the executable privately" {
  export TAR_OPTIONS='--checkpoint-action=exec=false'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$MOCK_LOG")" -eq 3 ]
  [ "$(grep -c '/releases/latest$' "$MOCK_LOG")" -eq 1 ]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/buildkite-gha_Linux_x86_64.tar.gz' "$MOCK_LOG"
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/checksums.txt' "$MOCK_LOG"
  [ "$(cat "$FIXTURE/arguments")" = plugin ]
  [ "$(cat "$FIXTURE/mode")" = 700 ]
  ! grep -Fx LICENSE "$FIXTURE/files"
  assert_clean
}

@test "accepts exact version shorthand and prereleases without resolving latest" {
  for version in 0.107.1 v0.107.1 v1.0.0-rc.1 1.0.0-rc.1+build.2; do
    : > "$MOCK_LOG"
    export BUILDKITE_PLUGIN_CONFIGURATION="{\"version\":\"$version\"}"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(wc -l < "$MOCK_LOG")" -eq 2 ]
    grep -Fx "https://github.com/buildkite/buildkite-gha/releases/download/v${version#v}/checksums.txt" "$MOCK_LOG"
    assert_clean
  done
}

@test "selects Linux arm64 and native macOS arm64 release assets" {
  for host in Linux:aarch64:Linux_arm64 Darwin:arm64:Darwin_arm64; do
    IFS=: read -r MOCK_OS MOCK_ARCH asset <<< "$host"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -Fx "https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/buildkite-gha_$asset.tar.gz" "$MOCK_LOG"
    assert_clean
  done
}

@test "passes configuration byte-for-byte and preserves runtime exit status" {
  export BUILDKITE_PLUGIN_CONFIGURATION=' {"version":"0.107.1", "workflows":["ci.yml"],"runners":"CLI validates this","future":{"nested":[true,3]}} '
  export BUILDKITE_PLUGIN_GITHUB_ACTIONS_VERSION=ignored-flattened-value
  export MOCK_IMPORTER_EXIT=37
  run "$REPO/hooks/command"
  [ "$status" -eq 37 ]
  [ "$(cat "$FIXTURE/configuration")" = "$BUILDKITE_PLUGIN_CONFIGURATION" ]
  assert_clean
}

@test "downloads a raw executable without release lookup or archives" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"binary":"https://example.com/custom?build=123"}'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$MOCK_LOG")" = 'https://example.com/custom?build=123' ]
  [ "$(cat "$FIXTURE/files")" = buildkite-gha ]
  [ "$(cat "$FIXTURE/configuration")" = "$BUILDKITE_PLUGIN_CONFIGURATION" ]
  assert_clean
}

@test "downloads only the importer from the platform map and keeps counterpart URLs unchanged" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"binary":{"linux/amd64":"https://example.com/linux","linux/arm64":"https://example.com/arm","darwin/arm64":"https://example.com/mac","windows/amd64":"https://example.com/windows.exe"}}'
  for host in Linux:x86_64:linux Linux:arm64:arm Darwin:arm64:mac; do
    IFS=: read -r MOCK_OS MOCK_ARCH name <<< "$host"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$MOCK_LOG")" = "https://example.com/$name" ]
    [ "$(cat "$FIXTURE/configuration")" = "$BUILDKITE_PLUGIN_CONFIGURATION" ]
    assert_clean
  done
}

@test "verifies raw executable checksums with either hex case before invoking" {
  hash="$(shasum -a 256 "$FIXTURE/buildkite-gha")"
  for hash in "${hash%% *}" "$(printf '%s' "${hash%% *}" | tr 'a-f' 'A-F')"; do
    for MOCK_OS in Linux Darwin; do
      [[ "$MOCK_OS" == Linux ]] && MOCK_ARCH=x86_64 || MOCK_ARCH=arm64
      export BUILDKITE_PLUGIN_CONFIGURATION="{\"binary\":\"https://example.com/custom#sha256=$hash\"}"
      : > "$MOCK_LOG"
      run "$REPO/hooks/command"
      [ "$status" -eq 0 ] || { echo "$output"; false; }
      [ "$(cat "$MOCK_LOG")" = https://example.com/custom ]
      [ "$(cat "$FIXTURE/configuration")" = "$BUILDKITE_PLUGIN_CONFIGURATION" ]
      assert_clean
    done
  done
}

@test "never invokes an executable with a wrong checksum" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"binary":{"linux/amd64":"https://example.com/custom#sha256=0000000000000000000000000000000000000000000000000000000000000000"}}'
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"binary checksum verification failed"* ]]
  [ ! -e "$FIXTURE/arguments" ]
  assert_clean
}

@test "rejects malformed URLs, fragments, maps, conflicting and retired acquisition options before download" {
  for configuration in \
    '{"version":"latest","binary":"https://example.com/custom"}' \
    '{"source-ref":"main"}' '{"minimum-release-age":"0s"}' \
    '{"binary":null}' '{"binary":{}}' '{"binary":[]}' \
    '{"binary":{"darwin/arm64":"https://example.com/mac"}}' \
    '{"binary":{"linux/amd64":"https://example.com/linux","windows/arm64":"https://example.com/windows"}}' \
    '{"binary":{"linux/amd64":"https://example.com/linux","windows/amd64":"http://example.com/windows"}}' \
    '{"binary":"http://example.com/custom"}' '{"binary":"/tmp/custom"}' \
    '{"binary":"https://user:password@example.com/custom"}' \
    '{"binary":"https://example.com/custom\u0000"}' \
    '{"binary":"https://example.com/custom#"}' \
    '{"binary":"https://example.com/custom#sha256=abc"}' \
    '{"binary":"https://example.com/custom#sha512=abc"}' \
    '{"binary":"https://example.com/custom#sha256=0000000000000000000000000000000000000000000000000000000000000000#sha256=0000000000000000000000000000000000000000000000000000000000000000"}'; do
    export BUILDKITE_PLUGIN_CONFIGURATION="$configuration"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ] || { echo "$configuration"; false; }
    [ ! -s "$MOCK_LOG" ]
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}

@test "rejects invalid configuration JSON, source refs and inexact versions" {
  for configuration in '' 'not-json' '[]' 'null' '{} {}' \
    '{"version":null}' '{"version":1}' '{"version":""}' '{"version":"main"}' \
    '{"version":"v1.2.3\n"}' '{"version":"v1.2.3\u0000"}' \
    '{"version":"01.2.3"}' '{"version":"1.2"}' '{"version":"1.2.3-01"}' \
    '{"version":"1.2.3/../../bad"}'; do
    export BUILDKITE_PLUGIN_CONFIGURATION="$configuration"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ] || { echo "$configuration"; false; }
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "rejects unsupported importer platforms including Windows" {
  for host in Darwin:x86_64 Windows_NT:x86_64 Linux:riscv64; do
    IFS=: read -r MOCK_OS MOCK_ARCH <<< "$host"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported importer platform"* ]]
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "fails closed on missing or invalid latest tag metadata" {
  for response in '{}' '{"tag_name":"main"}' '{"tag_name":"v1.2.3/../../bad"}' 'not-json'; do
    printf '%s' "$response" > "$FIXTURE/release.json"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}

@test "preserves curl failure and cleans partial downloads at every acquisition stage" {
  for MOCK_FAIL_SUFFIX in /latest .tar.gz checksums.txt /custom; do
    export MOCK_FAIL_SUFFIX
    [[ "$MOCK_FAIL_SUFFIX" == /custom ]] && export BUILDKITE_PLUGIN_CONFIGURATION='{"binary":"https://example.com/custom"}'
    run "$REPO/hooks/command"
    [ "$status" -eq 22 ]
    [[ "$output" == *"curl: fixture HTTP failure"* ]]
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}

@test "rejects missing, duplicate and incorrect release checksums without invoking" {
  for failure in missing duplicate mismatch; do
    checksums
    case "$failure" in
      missing) : > "$FIXTURE/checksums.txt" ;;
      duplicate) head -n 1 "$FIXTURE/checksums.txt" >> "$FIXTURE/checksums.txt" ;;
      mismatch) printf 'tampering' >> "$FIXTURE/archive.tar.gz" ;;
    esac
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ]
    [[ "$output" == *checksum* ]]
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}

@test "rejects archives with missing, linked, or duplicate executable members" {
  for failure in missing symlink hardlink duplicate; do
    case "$failure" in
      missing) tar -czf "$FIXTURE/archive.tar.gz" -C "$FIXTURE" LICENSE ;;
      symlink)
        rm "$FIXTURE/buildkite-gha"
        ln -s LICENSE "$FIXTURE/buildkite-gha"
        tar -czf "$FIXTURE/archive.tar.gz" -C "$FIXTURE" buildkite-gha ;;
      hardlink)
        rm "$FIXTURE/buildkite-gha"
        ln "$FIXTURE/LICENSE" "$FIXTURE/buildkite-gha"
        tar -czf "$FIXTURE/archive.tar.gz" -C "$FIXTURE" LICENSE buildkite-gha ;;
      duplicate) tar -czf "$FIXTURE/archive.tar.gz" -C "$FIXTURE" buildkite-gha buildkite-gha ;;
    esac
    checksums
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ] || { echo "$failure: $output"; false; }
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}
