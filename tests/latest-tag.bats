#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO/.buildkite/scripts/update-latest-tag"
  TMP="$(mktemp -d)"
  export REAL_GIT="$(command -v git)"
  export REMOTE="$TMP/remote.git"
  export WORK="$TMP/work"
  export HOME="$TMP/home"
  export SECRET_LOG="$TMP/secret.log"
  export PUSH_LOG="$TMP/push.log"
  export MISE_LOG="$TMP/mise.log"
  export GH_LOG="$TMP/gh.log"
  mkdir -p "$HOME" "$TMP/bin"
  : > "$SECRET_LOG"
  : > "$PUSH_LOG"
  : > "$MISE_LOG"
  : > "$GH_LOG"
  unset GH_TOKEN GITHUB_TOKEN

  "$REAL_GIT" init --quiet --bare "$REMOTE"
  "$REAL_GIT" init --quiet "$WORK"
  "$REAL_GIT" -C "$WORK" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$WORK" config user.name Test
  "$REAL_GIT" -C "$WORK" config user.email test@example.com
  printf 'one\n' > "$WORK/file"
  "$REAL_GIT" -C "$WORK" add file
  "$REAL_GIT" -C "$WORK" commit --quiet -m one
  FIRST_COMMIT="$($REAL_GIT -C "$WORK" rev-parse HEAD)"
  printf 'two\n' >> "$WORK/file"
  "$REAL_GIT" -C "$WORK" commit --quiet -am two
  SECOND_COMMIT="$($REAL_GIT -C "$WORK" rev-parse HEAD)"
  printf 'three\n' >> "$WORK/file"
  "$REAL_GIT" -C "$WORK" commit --quiet -am three
  RELEASE_COMMIT="$($REAL_GIT -C "$WORK" rev-parse HEAD)"
  export FIRST_COMMIT SECOND_COMMIT RELEASE_COMMIT
  "$REAL_GIT" -C "$WORK" tag v1.2.3
  "$REAL_GIT" -C "$WORK" remote add canonical "$REMOTE"
  "$REAL_GIT" -C "$WORK" push --quiet canonical main refs/tags/v1.2.3
  "$REAL_GIT" -C "$WORK" remote add origin https://example.invalid/unauthenticated.git

  "$REAL_GIT" config --global \
    "url.file://${REMOTE}.insteadOf" \
    https://github.com/buildkite-plugins/github-actions-buildkite-plugin.git

  cat > "$TMP/bin/buildkite-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SECRET_LOG:?}"
[[ "$1" == secret && "$2" == get && "$3" == GITHUB_ACTIONS_PLUGIN_RELEASE_TOKEN ]]
printf '%s' test-release-token
AGENT
  cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'gh=%s\n' "$*" >> "${GH_LOG:?}"
[[ "$1" == auth && "$2" == git-credential && "$3" == get ]]
cat >/dev/null
printf 'username=x-access-token\npassword=%s\n' "${GH_TOKEN:?}"
GH
  export MOCK_GH="$TMP/bin/gh"
  cat > "$TMP/bin/mise" <<'MISE'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then
  echo '2026.8.4 linux-x64'
  exit
fi
printf 'mise=%s\n' "$*" >> "${MISE_LOG:?}"
if [[ "$1" == --no-config && "$2" == exec && "$3" == github-cli@2.97.0 && "$4" == -- && "$5" == sh && "$6" == -c && "$7" == 'command -v gh' ]]; then
  printf '%s\n' "${MOCK_GH:?}"
  exit
fi
exit 64
MISE
  chmod +x "$TMP/bin/buildkite-agent" "$TMP/bin/gh" "$TMP/bin/mise"
  export PATH="$TMP/bin:$PATH"
  export BUILDKITE_AGENT_BINARY="$TMP/bin/buildkite-agent"
  export BUILDKITE_TAG=v1.2.3
  export BUILDKITE_COMMIT="$RELEASE_COMMIT"
}

teardown() { rm -rf "$TMP"; }

latest_oid() {
  "$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/tags/latest
}

latest_commit() {
  "$REAL_GIT" --git-dir="$REMOTE" rev-parse 'refs/tags/latest^{commit}'
}

run_latest_tag() {
  cd "$WORK"
  "$SCRIPT"
}

install_git_wrapper() {
  cat > "$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
is_push=false
credential_helper_config=""
for argument in "$@"; do
  [[ "$argument" == push ]] && is_push=true
  [[ "$argument" == credential.helper='!'* ]] && credential_helper_config="$argument"
  if [[ "$argument" == *test-release-token* ]]; then
    echo "token leaked in git arguments" >&2
    exit 97
  fi
done
if [[ "$is_push" == true ]]; then
  credential="$(printf 'protocol=https\nhost=github.com\n\n' | "$REAL_GIT" \
    -c credential.helper= -c "${credential_helper_config:?}" credential fill)"
  printf 'credential-%s\n' "$credential" >> "${PUSH_LOG:?}"
  printf 'push=%s\n' "$*" >> "${PUSH_LOG:?}"
  if [[ "${RACE_ONCE:-}" == 1 && ! -e "${RACE_STATE:?}" ]]; then
    : > "$RACE_STATE"
    "$REAL_GIT" --git-dir="${REMOTE:?}" update-ref refs/tags/latest "${SECOND_COMMIT:?}"
  fi
elif [[ -n "${GH_TOKEN:-}" ]]; then
  echo "release token exposed to non-push git command" >&2
  exit 98
fi
exec "$REAL_GIT" "$@"
GIT
  chmod +x "$TMP/bin/git"
  export PATH="$TMP/bin:$PATH"
}

@test "pipeline publishes only after static checks and both uploaded smoke jobs" {
  pipeline="$REPO/.buildkite/pipeline.yml"
  release_block="$(sed -n '/label: ":github: Update latest plugin tag"/,/      YAML/p' "$pipeline")"

  grep -F 'key: "plugin-tests"' "$pipeline"
  grep -F 'key: "plugin-lint"' "$pipeline"
  grep -F 'key: "shellcheck"' "$pipeline"
  for dependency in plugin-tests plugin-lint shellcheck; do
    [[ "$release_block" == *"- \"$dependency\""* ]]
  done
  [[ "$release_block" == *'- "live-plugin-smoke-importer"'* ]]
  [[ "$release_block" == *'- "live-source-ref-smoke-importer"'* ]]
  grep -F 'buildkite-agent pipeline upload --no-interpolation' "$pipeline"
  [[ "$release_block" == *'if: '\''build.tag != null && build.tag =~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$/'\'''* ]]
  [[ "$release_block" == *'command: .buildkite/scripts/update-latest-tag'* ]]
  [[ "$release_block" != *allow_dependency_failure* ]]
}

@test "rejects non-stable tag builds before reading the release secret" {
  for tag in '' 1.2.3 v1.2 v1.2.3-rc.1 v01.2.3 v1.02.3 v1.2.03; do
    export BUILDKITE_TAG="$tag"
    run run_latest_tag
    [ "$status" -ne 0 ]
    [[ "$output" == *"BUILDKITE_TAG must be a stable vX.Y.Z tag"* ]]
  done
  [ ! -s "$SECRET_LOG" ]
  run "$REAL_GIT" --git-dir="$REMOTE" rev-parse --verify refs/tags/latest
  [ "$status" -ne 0 ]
}

@test "configures the canonical push with the fetched credential and a lightweight destination" {
  install_git_wrapper
  run run_latest_tag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(latest_oid)" = "$RELEASE_COMMIT" ]
  [ "$($REAL_GIT --git-dir="$REMOTE" cat-file -t refs/tags/latest)" = commit ]
  grep -Fx 'secret get GITHUB_ACTIONS_PLUGIN_RELEASE_TOKEN' "$SECRET_LOG"
  grep -Fx 'mise=--no-config exec github-cli@2.97.0 -- sh -c command -v gh' "$MISE_LOG"
  grep -Fx 'gh=auth git-credential get' "$GH_LOG"
  grep -Fx 'password=test-release-token' "$PUSH_LOG"
  grep -F 'https://github.com/buildkite-plugins/github-actions-buildkite-plugin.git' "$PUSH_LOG"
  grep -F -- "--force-with-lease=refs/tags/latest:" "$PUSH_LOG"
  grep -F -- '-c credential.helper=' "$PUSH_LOG"
  grep -F -- 'credential.helper=!' "$PUSH_LOG"
  grep -F -- '-c http.extraHeader=' "$PUSH_LOG"
  grep -F -- '--no-follow-tags' "$PUSH_LOG"
  ! grep -F 'example.invalid' "$PUSH_LOG"
  ! grep -F 'push=' "$PUSH_LOG" | grep -F 'test-release-token'
}

@test "accepts an annotated release tag and publishes its commit directly" {
  "$REAL_GIT" -C "$WORK" tag -d v1.2.3
  "$REAL_GIT" -C "$WORK" tag -a v1.2.3 -m release "$RELEASE_COMMIT"
  "$REAL_GIT" -C "$WORK" push --quiet --force canonical refs/tags/v1.2.3

  run run_latest_tag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(latest_oid)" = "$RELEASE_COMMIT" ]
  [ "$($REAL_GIT --git-dir="$REMOTE" cat-file -t refs/tags/latest)" = commit ]
}

@test "an idempotent rerun leaves lightweight latest unchanged" {
  run run_latest_tag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  first_oid="$(latest_oid)"

  : > "$SECRET_LOG"
  run run_latest_tag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"latest already points directly"* ]]
  [ "$(latest_oid)" = "$first_oid" ]
  [ ! -s "$SECRET_LOG" ]
}

@test "replaces an existing annotated latest tag with a forward lightweight tag" {
  "$REAL_GIT" -C "$WORK" tag -a latest -m old-latest "$FIRST_COMMIT"
  "$REAL_GIT" -C "$WORK" push --quiet canonical refs/tags/latest
  old_oid="$(latest_oid)"
  [ "$old_oid" != "$FIRST_COMMIT" ]

  run run_latest_tag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(latest_oid)" = "$RELEASE_COMMIT" ]
  [ "$($REAL_GIT --git-dir="$REMOTE" cat-file -t refs/tags/latest)" = commit ]
}

@test "refuses a delayed release rollback before reading the secret" {
  printf 'four\n' >> "$WORK/file"
  "$REAL_GIT" -C "$WORK" commit --quiet -am four
  newer_commit="$($REAL_GIT -C "$WORK" rev-parse HEAD)"
  "$REAL_GIT" -C "$WORK" push --quiet canonical main
  "$REAL_GIT" --git-dir="$REMOTE" update-ref refs/tags/latest "$newer_commit"
  "$REAL_GIT" -C "$WORK" checkout --quiet "$RELEASE_COMMIT"

  run run_latest_tag
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to move latest backwards"* ]]
  [ "$(latest_commit)" = "$newer_commit" ]
  [ ! -s "$SECRET_LOG" ]
}

@test "refuses a divergent latest before reading the secret" {
  empty_tree="$(printf '' | "$REAL_GIT" -C "$WORK" mktree)"
  divergent_commit="$(printf 'divergent\n' | "$REAL_GIT" -C "$WORK" commit-tree "$empty_tree")"
  "$REAL_GIT" -C "$WORK" push --quiet canonical "$divergent_commit:refs/heads/divergent"
  "$REAL_GIT" --git-dir="$REMOTE" update-ref refs/tags/latest "$divergent_commit"

  run run_latest_tag
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to move latest across divergent history"* ]]
  [ "$(latest_commit)" = "$divergent_commit" ]
  [ ! -s "$SECRET_LOG" ]
}

@test "retries a deterministic lease race and advances from the concurrent ancestor" {
  "$REAL_GIT" --git-dir="$REMOTE" update-ref refs/tags/latest "$FIRST_COMMIT"
  export RACE_ONCE=1
  export RACE_STATE="$TMP/race-state"
  install_git_wrapper

  run run_latest_tag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"latest changed concurrently; retrying with a fresh lease"* ]]
  [ "$(latest_oid)" = "$RELEASE_COMMIT" ]
  [ "$(grep -c '^push=' "$PUSH_LOG")" -eq 2 ]
  grep -F -- "--force-with-lease=refs/tags/latest:$FIRST_COMMIT" "$PUSH_LOG"
  grep -F -- "--force-with-lease=refs/tags/latest:$SECOND_COMMIT" "$PUSH_LOG"
}

@test "rejects local or canonical release mismatches before reading the secret" {
  export BUILDKITE_COMMIT="$SECOND_COMMIT"
  run run_latest_tag
  [ "$status" -ne 0 ]
  [[ "$output" == *"HEAD resolves to"* ]]
  [ ! -s "$SECRET_LOG" ]

  export BUILDKITE_COMMIT="$RELEASE_COMMIT"
  "$REAL_GIT" -C "$WORK" tag -f v1.2.3 "$SECOND_COMMIT"
  "$REAL_GIT" -C "$WORK" push --quiet --force canonical refs/tags/v1.2.3

  run run_latest_tag
  [ "$status" -ne 0 ]
  [[ "$output" == *"not BUILDKITE_COMMIT"* ]]
  [ ! -s "$SECRET_LOG" ]
}
