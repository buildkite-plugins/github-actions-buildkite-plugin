#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
  export TMPDIR="$BATS_TEST_TMPDIR/downloads"
  export MOCK_LOG="$BATS_TEST_TMPDIR/download.log"
  export BUILDKITE_PLUGIN_CONFIGURATION='{}'
  export BUILDKITE_GHA_PLUGIN_RELEASE='{"tag_name":"inherited-untrusted-metadata"}'
  export BUILDKITE_GHA_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
  unset BUILDKITE_CLEAN_CHECKOUT BUILDKITE_GIT_CLEAN_FLAGS
  export MOCK_OS=Linux MOCK_ARCH=x86_64
  mkdir -p "$FIXTURE/bin" "$TMPDIR"
  : > "$MOCK_LOG"
  cat > "$FIXTURE/buildkite-gha" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" > "$FIXTURE/arguments"
printf '%s' "$BUILDKITE_PLUGIN_CONFIGURATION" > "$FIXTURE/configuration"
printf '%s' "${BUILDKITE_GHA_PLUGIN_RELEASE:-}" > "$FIXTURE/metadata"
stat -c %a "$(dirname "$0")" > "$FIXTURE/mode" 2>/dev/null || stat -f %Lp "$(dirname "$0")" > "$FIXTURE/mode"
ls -A "$(dirname "$0")" > "$FIXTURE/files"
exit "${MOCK_IMPORTER_EXIT:-0}"
EOF
  release_metadata
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
  https://api.github.com/repos/buildkite/buildkite-gha/releases/latest|https://api.github.com/repos/buildkite/buildkite-gha/releases/tags/*) source=release.json ;;
  https://github.com/buildkite/buildkite-gha/releases/download/*/*.tar.gz) source=release.tar.gz ;;
  https://github.com/buildkite/buildkite-gha/releases/download/*/buildkite-gha_*) source=buildkite-gha ;;
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

release_metadata() {
  local hash
  hash="$(shasum -a 256 "$FIXTURE/buildkite-gha")"
  jq -n --arg hash "${hash%% *}" --arg tag "${1:-v0.107.1}" '{
    tag_name: $tag,
    assets: (["linux_x86_64", "linux_arm64", "darwin_arm64", "windows_x86_64.exe"] | map({
      name: ("buildkite-gha_" + .),
      browser_download_url: ("https://github.com/buildkite/buildkite-gha/releases/download/" + $tag + "/buildkite-gha_" + .),
      digest: ("sha256:" + $hash)
    }))
  }' > "$FIXTURE/release.json"
}

archive_metadata() {
  local hash
  tar -czf "$FIXTURE/release.tar.gz" -C "$FIXTURE" buildkite-gha
  hash="$(shasum -a 256 "$FIXTURE/release.tar.gz")"
  jq --arg hash "${hash%% *}" '
    .assets |= map(
      .name |= (sub("_linux_"; "_Linux_") | sub("_darwin_"; "_Darwin_") | sub("_windows_"; "_Windows_") | sub("\\.exe$"; "") | . + ".tar.gz") |
      .browser_download_url = ("https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/" + .name) |
      .digest = ("sha256:" + $hash)
    )
  ' "$FIXTURE/release.json" > "$FIXTURE/archive.json"
  mv "$FIXTURE/archive.json" "$FIXTURE/release.json"
}

assert_clean() {
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "historical archive pins execute unchanged and reuse verified archives without network" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"0.107.1","workflow":"ci.yml"}'
  archive_metadata
  hash="$(shasum -a 256 "$FIXTURE/release.tar.gz")"
  for host in Linux:x86_64:Linux_x86_64:linux-amd64 Linux:aarch64:Linux_arm64:linux-arm64 Darwin:arm64:Darwin_arm64:darwin-arm64; do
    IFS=: read -r MOCK_OS MOCK_ARCH asset platform <<< "$host"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -Fx "https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/buildkite-gha_$asset.tar.gz" "$MOCK_LOG"
    ! grep -q checksums.txt "$MOCK_LOG"
    [ "$(cat "$FIXTURE/arguments")" = plugin ]
    [ "$(cat "$FIXTURE/configuration")" = "$BUILDKITE_PLUGIN_CONFIGURATION" ]
    [ "$(cat "$FIXTURE/mode")" = 700 ]
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ]
    [ ! -s "$MOCK_LOG" ]
    printf corrupt > "$BUILDKITE_GHA_CACHE_DIR/archives/$platform/${hash%% *}"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
    cmp "$FIXTURE/release.tar.gz" "$BUILDKITE_GHA_CACHE_DIR/archives/$platform/${hash%% *}"
    assert_clean
  done
}

@test "prefers raw assets and never falls back to archives for invalid raw metadata or bytes" {
  cp "$FIXTURE/release.json" "$FIXTURE/raw.json"
  archive_metadata
  jq -s '.[0].assets += .[1].assets | .[0]' "$FIXTURE/raw.json" "$FIXTURE/release.json" > "$FIXTURE/both.json"
  for mutation in '.' '.assets[0].digest = "bad"'; do
    jq "$mutation" "$FIXTURE/both.json" > "$FIXTURE/release.json"
    run "$REPO/hooks/command"
    if [[ "$mutation" == . ]]; then
      [ "$status" -eq 0 ] || { echo "$output"; false; }
      grep -q '/buildkite-gha_linux_x86_64$' "$MOCK_LOG"
    else
      [ "$status" -ne 0 ]
      [ ! -e "$FIXTURE/arguments" ]
    fi
    ! grep -q '\.tar.gz' "$MOCK_LOG"
    rm -rf "$BUILDKITE_GHA_CACHE_DIR" "$FIXTURE/arguments"
    : > "$MOCK_LOG"
  done
  cp "$FIXTURE/both.json" "$FIXTURE/release.json"
  printf corrupt >> "$FIXTURE/buildkite-gha"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  ! grep -q '\.tar.gz' "$MOCK_LOG"
  [ ! -e "$FIXTURE/arguments" ]
  assert_clean
}

@test "rejects corrupt archives and archives without a regular executable" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"v0.107.1"}'
  archive_metadata
  printf corrupt >> "$FIXTURE/release.tar.gz"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"release archive checksum verification failed"* ]]
  [ ! -e "$FIXTURE/arguments" ]
  [ ! -d "$BUILDKITE_GHA_CACHE_DIR/archives" ]
  rm -rf "$BUILDKITE_GHA_CACHE_DIR"

  rm "$FIXTURE/buildkite-gha"
  ln -s /bin/true "$FIXTURE/buildkite-gha"
  release_metadata
  archive_metadata
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE/arguments" ]
  assert_clean
}

@test "resolves latest once, verifies raw bytes, and hands the release to the CLI" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -c '/releases/latest$' "$MOCK_LOG")" -eq 1 ]
  grep -Fx 'https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/buildkite-gha_linux_x86_64' "$MOCK_LOG"
  ! grep -q 'checksums.txt' "$MOCK_LOG"
  [ "$(jq -c . "$FIXTURE/metadata")" = "$(jq -c . "$FIXTURE/release.json")" ]
  [ "$(cat "$FIXTURE/arguments")" = plugin ]
  [ "$(cat "$FIXTURE/mode")" = 700 ]
  assert_clean
}

@test "accepts exact version shorthand and prereleases without resolving latest" {
  for version in 0.107.1 v0.107.1 v1.0.0-rc.1 1.0.0-rc.1+build.2; do
    release_metadata "v${version#v}"
    : > "$MOCK_LOG"
    export BUILDKITE_GHA_CACHE_DIR="$BATS_TEST_TMPDIR/cache/$version"
    export BUILDKITE_PLUGIN_CONFIGURATION="{\"version\":\"$version\"}"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(wc -l < "$MOCK_LOG")" -eq 2 ]
    grep -Fx "https://api.github.com/repos/buildkite/buildkite-gha/releases/tags/v${version#v}" "$MOCK_LOG"
    assert_clean
  done
}

@test "selects Linux arm64 and native macOS arm64 release assets" {
  for host in Linux:aarch64:linux_arm64 Darwin:arm64:darwin_arm64; do
    IFS=: read -r MOCK_OS MOCK_ARCH asset <<< "$host"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -Fx "https://github.com/buildkite/buildkite-gha/releases/download/v0.107.1/buildkite-gha_$asset" "$MOCK_LOG"
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
  [ ! -s "$FIXTURE/metadata" ]
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
      export BUILDKITE_GHA_CACHE_DIR="$BATS_TEST_TMPDIR/cache/$hash"
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

@test "reuses metadata and verified binaries, keeps exact tags separate, and repairs corrupt binaries" {
  hash="$(shasum -a 256 "$FIXTURE/buildkite-gha")"
  cached="$BUILDKITE_GHA_CACHE_DIR/binaries/linux-amd64/${hash%% *}"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]

  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"v0.107.1"}'
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  grep -q '/tags/v0.107.1$' "$MOCK_LOG"

  printf corrupt > "$cached"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  ! grep -q 'api.github.com' "$MOCK_LOG"
  cmp "$FIXTURE/buildkite-gha" "$cached"

  # Numeric shorthand shares the exact-tag entry, not the latest selector.
  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"0.107.1"}'
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
  assert_clean
}

@test "metadata expires at one hour without extending freshness on cache hits" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  metadata_cache="$BUILDKITE_GHA_CACHE_DIR/releases/latest.json"
  modified="$(stat -c %Y "$metadata_cache" 2>/dev/null || stat -f %m "$metadata_cache")"
  cat > "$FIXTURE/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == +%s ]]
echo "$MOCK_NOW"
EOF
  chmod +x "$FIXTURE/bin/date"
  export MOCK_NOW=$((modified + 3599))
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
  [ "$(stat -c %Y "$metadata_cache" 2>/dev/null || stat -f %m "$metadata_cache")" = "$modified" ]

  export MOCK_NOW=$((modified + 3600))
  release_metadata v0.108.0
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = https://api.github.com/repos/buildkite/buildkite-gha/releases/latest ]
  [ "$(jq -r .tag_name "$FIXTURE/metadata")" = v0.108.0 ]

  # An expired response selecting different bytes also downloads the new binary.
  echo '# next release' >> "$FIXTURE/buildkite-gha"
  release_metadata v0.109.0
  touch -t 200001010000 "$metadata_cache"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 2 ]
  grep -q '/v0.109.0/buildkite-gha_linux_x86_64$' "$MOCK_LOG"
  assert_clean
}

@test "only recognized clean-checkout true values refresh metadata and keep verified binaries" {
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  export BUILDKITE_GIT_CLEAN_FLAGS='-ffxdq'
  for value in '' false 0 f F FALSE False invalid 1 t T TRUE true True; do
    export BUILDKITE_CLEAN_CHECKOUT="$value"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$value: $output"; false; }
    case "$value" in
      1|t|T|TRUE|true|True)
        [ "$(cat "$MOCK_LOG")" = https://api.github.com/repos/buildkite/buildkite-gha/releases/latest ] ;;
      *) [ ! -s "$MOCK_LOG" ] ;;
    esac
  done
  assert_clean
}

@test "malformed cached metadata is refreshed and failed refreshes never use stale metadata" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"v0.107.1"}'
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  metadata_cache="$BUILDKITE_GHA_CACHE_DIR/releases/tags/v0.107.1.json"
  for mutation in '.tag_name = "v9.0.0"' '.assets = []' '.assets[0].digest = "bad"' '.assets[0].browser_download_url = "http://example.com/binary"'; do
    jq "$mutation" "$FIXTURE/release.json" > "$metadata_cache"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$mutation: $output"; false; }
    [ "$(cat "$MOCK_LOG")" = https://api.github.com/repos/buildkite/buildkite-gha/releases/tags/v0.107.1 ]
    [ "$(jq -c . "$FIXTURE/metadata")" = "$(jq -c . "$FIXTURE/release.json")" ]
  done
  printf 'not-json' > "$metadata_cache"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]

  touch -t 200001010000 "$metadata_cache"
  export MOCK_FAIL_SUFFIX=/v0.107.1
  rm "$FIXTURE/arguments"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 22 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  [ ! -e "$FIXTURE/arguments" ]
  assert_clean
}

@test "reuses pinned binaries without network, repairs corruption, and respects changed pins" {
  hash="$(shasum -a 256 "$FIXTURE/buildkite-gha")"
  hash="${hash%% *}"
  export BUILDKITE_PLUGIN_CONFIGURATION="{\"binary\":\"https://example.com/custom#sha256=$hash\"}"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  : > "$MOCK_LOG"
  export MOCK_FAIL_SUFFIX=/custom
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
  unset MOCK_FAIL_SUFFIX

  printf corrupt > "$BUILDKITE_GHA_CACHE_DIR/binaries/linux-amd64/$hash"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  cmp "$FIXTURE/buildkite-gha" "$BUILDKITE_GHA_CACHE_DIR/binaries/linux-amd64/$hash"

  # A different checksum at the same URL must select different bytes.
  echo '# next candidate' >> "$FIXTURE/buildkite-gha"
  hash="$(shasum -a 256 "$FIXTURE/buildkite-gha")"
  export BUILDKITE_PLUGIN_CONFIGURATION="{\"binary\":\"https://example.com/custom#sha256=${hash%% *}\"}"
  : > "$MOCK_LOG"
  run "$REPO/hooks/command"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  cmp "$FIXTURE/buildkite-gha" "$BUILDKITE_GHA_CACHE_DIR/binaries/linux-amd64/${hash%% *}"

  export BUILDKITE_PLUGIN_CONFIGURATION='{"binary":"https://example.com/custom"}'
  : > "$MOCK_LOG"
  for attempt in 1 2; do
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ]
  done
  [ "$(wc -l < "$MOCK_LOG")" -eq 2 ]
  assert_clean
}

@test "uses persistent cache defaults and tolerates an unavailable cache" {
  unset BUILDKITE_GHA_CACHE_DIR MISE_DATA_DIR BUILDKITE_AGENT_DATA_PATH XDG_CACHE_HOME
  export BUILDKITE_COMPUTE_TYPE=self-hosted
  # System tools must not use mise shims while testing changes to its data directory.
  export PATH="$FIXTURE/bin:/usr/bin:/bin:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"0.107.1"}'
  hash="$(shasum -a 256 "$FIXTURE/buildkite-gha")"
  for setting in HOME XDG_CACHE_HOME BUILDKITE_AGENT_DATA_PATH MISE_DATA_DIR BUILDKITE_GHA_CACHE_DIR; do
    case "$setting" in
      HOME) root="$HOME/.cache/buildkite-gha" ;;
      XDG_CACHE_HOME) export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg"; root="$XDG_CACHE_HOME/buildkite-gha" ;;
      BUILDKITE_AGENT_DATA_PATH) export BUILDKITE_AGENT_DATA_PATH="$BATS_TEST_TMPDIR/agent"; root="$BUILDKITE_AGENT_DATA_PATH/cache/buildkite-gha" ;;
      MISE_DATA_DIR) export MISE_DATA_DIR="$BATS_TEST_TMPDIR/mise"; root="$MISE_DATA_DIR/buildkite-gha" ;;
      BUILDKITE_GHA_CACHE_DIR) export BUILDKITE_GHA_CACHE_DIR="$BATS_TEST_TMPDIR/explicit"; root="$BUILDKITE_GHA_CACHE_DIR" ;;
    esac
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    cmp "$FIXTURE/buildkite-gha" "$root/binaries/linux-amd64/${hash%% *}"
  done
  touch "$BATS_TEST_TMPDIR/not-a-directory"
  for root in "$BATS_TEST_TMPDIR/not-a-directory/cache" relative-cache; do
    export BUILDKITE_GHA_CACHE_DIR="$root"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(wc -l < "$MOCK_LOG")" -eq 2 ]
    assert_clean
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
  for MOCK_FAIL_SUFFIX in /latest /buildkite-gha_linux_x86_64 /custom; do
    export MOCK_FAIL_SUFFIX
    [[ "$MOCK_FAIL_SUFFIX" == /custom ]] && export BUILDKITE_PLUGIN_CONFIGURATION='{"binary":"https://example.com/custom"}'
    run "$REPO/hooks/command"
    [ "$status" -eq 22 ]
    [[ "$output" == *"curl: fixture HTTP failure"* ]]
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}

@test "rejects missing, duplicate and invalid asset metadata without downloading binaries" {
  for mutation in \
    'del(.assets)' '.assets = []' '.assets += [.assets[0]]' \
    '.assets[0].name += ".tar.gz"' \
    'del(.assets[0].digest)' '.assets[0].digest = "sha256:not-a-hash"' \
    '.assets[0].digest |= sub("sha256:"; "md5:")' \
    '.assets[0].digest += "\n"' \
    '.assets[0].browser_download_url = "http://example.com/binary"' \
    '.assets[0].browser_download_url = "https://user:password@example.com/binary"' \
    '.assets[0].browser_download_url += "\u0000"'; do
    release_metadata
    jq "$mutation" "$FIXTURE/release.json" > "$FIXTURE/modified.json"
    mv "$FIXTURE/modified.json" "$FIXTURE/release.json"
    : > "$MOCK_LOG"
    run "$REPO/hooks/command"
    [ "$status" -ne 0 ] || { echo "$mutation: $output"; false; }
    [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
    [ ! -e "$FIXTURE/arguments" ]
    assert_clean
  done
}

@test "rejects corrupt release bytes and never caches or runs them" {
  printf tampering >> "$FIXTURE/buildkite-gha"
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"release binary checksum verification failed"* ]]
  [ ! -e "$FIXTURE/arguments" ]
  [ ! -d "$BUILDKITE_GHA_CACHE_DIR/binaries" ]
  assert_clean
}

@test "rejects a release response for a different explicit version" {
  export BUILDKITE_PLUGIN_CONFIGURATION='{"version":"v0.108.0"}'
  run "$REPO/hooks/command"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag does not match"* ]]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  [ ! -e "$FIXTURE/arguments" ]
  assert_clean
}
