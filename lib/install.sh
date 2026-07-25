#!/usr/bin/env bash

gha_error() { echo "github-actions plugin: $*" >&2; }

gha_require() {
  command -v "$1" >/dev/null 2>&1 || { gha_error "required command '$1' was not found"; return 1; }
}

gha_version() {
  local value="${1#v}"
  if [[ ! "$value" =~ ^0\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    gha_error "invalid CLI version '$1'; expected strict pre-1.0 semver (for example 0.1.0)"
    return 1
  fi
  printf '%s\n' "$value"
}

gha_cache_root() {
  local root
  if [[ -n "${BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT:-}" ]]; then
    root="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  elif [[ -n "${BUILDKITE_AGENT_DATA_PATH:-}" ]]; then
    root="${BUILDKITE_AGENT_DATA_PATH}/cache/github-actions-buildkite-plugin"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    root="${XDG_CACHE_HOME}/buildkite/github-actions-buildkite-plugin"
  elif [[ -n "${HOME:-}" ]]; then
    root="${HOME}/.cache/buildkite/github-actions-buildkite-plugin"
  else
    mktemp -d "${TMPDIR:-/tmp}/github-actions-buildkite-plugin-cache.XXXXXX"
    return
  fi
  if mkdir -p "$root" 2>/dev/null && [[ -w "$root" ]]; then
    printf '%s\n' "$root"
  else
    gha_error "cache '$root' is unavailable; using a temporary cache"
    mktemp -d "${TMPDIR:-/tmp}/github-actions-buildkite-plugin-cache.XXXXXX"
  fi
}

gha_validate_archive() {
  local archive="$1" listing="$2"
  LC_ALL=C tar -tvzf "$archive" > "$listing" || { gha_error "release archive is not a valid gzip tar archive"; return 1; }
  awk '
    BEGIN { ok["buildkite-gha"]="-"; ok["LICENSE"]="-"; ok["runtimes"]="d"; ok["runtimes/node20"]="d"; ok["runtimes/node20/bin"]="d"; ok["runtimes/node20/bin/node"]="-"; ok["runtimes/node20/LICENSE"]="-"; ok["runtimes/node24"]="d"; ok["runtimes/node24/bin"]="d"; ok["runtimes/node24/bin/node"]="-"; ok["runtimes/node24/LICENSE"]="-" }
    { name=$NF; sub(/^\.\//, "", name); sub(/\/$/, "", name); type=substr($1,1,1); if (!(name in ok) || type != ok[name] || seen[name]++) exit 1 }
    END { for (name in ok) if (!seen[name] && ok[name] == "-") exit 1 }
  ' "$listing" || { gha_error "release archive contains an unexpected, missing, duplicate, or unsafe entry"; return 1; }
}

gha_verify_distribution() {
  local dir="$1" version="$2" output actual expected
  local required=(LICENSE buildkite-gha runtimes/node20/LICENSE runtimes/node20/bin/node runtimes/node24/LICENSE runtimes/node24/bin/node)
  local path
  for path in "${required[@]}"; do [[ -f "$dir/$path" && ! -L "$dir/$path" ]] || return 1; done
  expected=$'LICENSE\nbuildkite-gha\nruntimes\nruntimes/node20\nruntimes/node20/LICENSE\nruntimes/node20/bin\nruntimes/node20/bin/node\nruntimes/node24\nruntimes/node24/LICENSE\nruntimes/node24/bin\nruntimes/node24/bin/node'
  actual="$(find "$dir" -mindepth 1 -printf '%P\n' | LC_ALL=C sort)" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  chmod 0755 "$dir" "$dir/runtimes" "$dir/runtimes/node20" "$dir/runtimes/node20/bin" "$dir/runtimes/node24" "$dir/runtimes/node24/bin"
  chmod 0644 "$dir/LICENSE" "$dir/runtimes/node20/LICENSE" "$dir/runtimes/node24/LICENSE"
  chmod 0755 "$dir/buildkite-gha" "$dir/runtimes/node20/bin/node" "$dir/runtimes/node24/bin/node"
  output="$("$dir/buildkite-gha" --version 2>/dev/null)" || return 1
  [[ "$output" == "buildkite-gha $version" ]] || { gha_error "downloaded CLI reports an unexpected version: $output"; return 1; }
  "$dir/runtimes/node20/bin/node" --version 2>/dev/null | grep -Eq '^v20\.' || return 1
  "$dir/runtimes/node24/bin/node" --version 2>/dev/null | grep -Eq '^v24\.' || return 1
}

install_buildkite_gha() (
  local raw="$1" version tag root destination invalid work archive checksums listing checksum matches staged
  version="$(gha_version "$raw")" || return 1
  tag="v${version}"
  root="$(gha_cache_root)" || return 1
  destination="${root}/${tag}/Linux_x86_64"
  if [[ -x "$destination/buildkite-gha" ]] && gha_verify_distribution "$destination" "$version"; then
    printf '%s\n' "$destination"
    return
  fi
  for command in curl tar sha256sum awk grep mktemp; do gha_require "$command" || return 1; done
  if [[ -e "$destination" || -L "$destination" ]]; then
    invalid="${destination}.invalid.$$"
    if mv -T -- "$destination" "$invalid" 2>/dev/null; then
      rm -rf -- "$invalid"
    fi
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/github-actions-buildkite-plugin.XXXXXX")" || return 1
  archive="$work/buildkite-gha_Linux_x86_64.tar.gz"; checksums="$work/checksums.txt"; listing="$work/listing"
  trap 'rm -rf "$work"' EXIT
  local base="https://github.com/buildkite/buildkite-gha/releases/download/${tag}"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "${base}/buildkite-gha_Linux_x86_64.tar.gz" -o "$archive" || { gha_error "failed to download CLI archive for $tag"; return 1; }
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "${base}/checksums.txt" -o "$checksums" || { gha_error "failed to download checksums for $tag"; return 1; }
  matches="$(awk '$2 == "buildkite-gha_Linux_x86_64.tar.gz" && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ { print tolower($1) }' "$checksums")"
  [[ "$(printf '%s\n' "$matches" | grep -c .)" -eq 1 ]] || { gha_error "checksums.txt must contain exactly one valid archive checksum"; return 1; }
  checksum="$(printf '%s' "$matches")"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status || { gha_error "CLI archive checksum verification failed"; return 1; }
  gha_validate_archive "$archive" "$listing" || return 1
  staged="$(mktemp -d "${root}/.${tag}.XXXXXX")" || return 1
  tar -xzf "$archive" -C "$staged" --no-same-owner --no-same-permissions || { rm -rf "$staged"; gha_error "failed to extract CLI archive"; return 1; }
  gha_verify_distribution "$staged" "$version" || { rm -rf "$staged"; gha_error "extracted CLI or bundled Node runtimes failed validation"; return 1; }
  mkdir -p "$(dirname "$destination")"
  if mv -T "$staged" "$destination" 2>/dev/null; then :; else
    rm -rf "$staged"
    gha_verify_distribution "$destination" "$version" || { gha_error "concurrent CLI installation did not produce a valid cache"; return 1; }
  fi
  printf '%s\n' "$destination"
)
