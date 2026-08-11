#!/usr/bin/env bash

gha_error() { echo "github-actions plugin: $*" >&2; }

gha_require() {
  command -v "$1" >/dev/null 2>&1 || { gha_error "required command '$1' was not found"; return 1; }
}

gha_version() {
  local value="${1#v}" major minor
  if [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    if [[ "$major" != 0 || "$minor" =~ ^(8|9|[1-9][0-9]+)$ ]]; then
      printf '%s\n' "$value"
      return
    fi
  fi
  gha_error "invalid CLI version '$1'; expected latest or an exact stable release from 0.8.0 onward"
  return 1
}

gha_resolve_version() {
  local raw="$1" resolved tag
  if [[ "$raw" != latest ]]; then
    gha_version "$raw"
    return
  fi
  gha_require curl || return 1
  resolved="$(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output /dev/null --write-out '%{url_effective}' \
    https://github.com/buildkite/buildkite-gha/releases/latest)" || {
    gha_error "failed to resolve the latest buildkite-gha release"
    return 1
  }
  tag="${resolved#https://github.com/buildkite/buildkite-gha/releases/tag/}"
  if [[ "$tag" == "$resolved" || "$resolved" != "https://github.com/buildkite/buildkite-gha/releases/tag/$tag" ]]; then
    gha_error "latest buildkite-gha release resolved to an unexpected URL: $resolved"
    return 1
  fi
  resolved="$(gha_version "$tag")" || return 1
  gha_error "latest buildkite-gha release resolved to v$resolved"
  printf '%s\n' "$resolved"
}

gha_cache_root() {
  local hosted_root root
  if [[ -n "${BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT:-}" ]]; then
    root="$BUILDKITE_GITHUB_ACTIONS_PLUGIN_CACHE_ROOT"
  elif [[ "${BUILDKITE_COMPUTE_TYPE:-self-hosted}" == hosted ]] &&
    hosted_root="${MISE_HOSTED_CACHE_VOLUME_ROOT:-/cache/bkcache}" &&
    [[ -d "$hosted_root" && -w "$hosted_root" ]]; then
    root="${hosted_root}/github-actions-buildkite-plugin"
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
    BEGIN { ok["buildkite-gha"]="-"; ok["LICENSE"]="-" }
    { name=$NF; sub(/^\.\//, "", name); sub(/\/$/, "", name); type=substr($1,1,1); if (!(name in ok) || type != ok[name] || seen[name]++) exit 1 }
    END { for (name in ok) if (!seen[name] && ok[name] == "-") exit 1 }
  ' "$listing" || { gha_error "release archive contains an unexpected, missing, duplicate, or unsafe entry"; return 1; }
}

gha_verify_distribution() {
  local dir="$1" version="$2" output actual expected
  local required=(LICENSE buildkite-gha)
  local path
  for path in "${required[@]}"; do [[ -f "$dir/$path" && ! -L "$dir/$path" ]] || return 1; done
  expected=$'LICENSE\nbuildkite-gha'
  actual="$(cd "$dir" && find . -print | sed '1d; s#^\./##' | LC_ALL=C sort)" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  chmod 0755 "$dir" "$dir/buildkite-gha"
  chmod 0644 "$dir/LICENSE"
  output="$("$dir/buildkite-gha" --version 2>/dev/null)" || return 1
  [[ "$output" == "buildkite-gha $version" ]] || { gha_error "downloaded CLI reports an unexpected version: $output"; return 1; }
}

install_buildkite_gha() (
  local raw="$1" version tag root destination cached_archive invalid work archive checksums listing checksum matches actual_checksum staged run cache_hit
  unset TAR_OPTIONS GZIP
  version="$(gha_resolve_version "$raw")" || return 1
  tag="v${version}"
  root="$(gha_cache_root)" || return 1
  destination="${root}/${tag}/Linux_x86_64"
  cached_archive="$destination/buildkite-gha_Linux_x86_64.tar.gz"
  for command in curl tar sha256sum awk grep mktemp cp; do gha_require "$command" || return 1; done
  work="$(mktemp -d "${TMPDIR:-/tmp}/github-actions-buildkite-plugin.XXXXXX")" || return 1
  archive="$work/buildkite-gha_Linux_x86_64.tar.gz"; checksums="$work/checksums.txt"; listing="$work/listing"
  trap 'rm -rf "$work"' EXIT
  local base="https://github.com/buildkite/buildkite-gha/releases/download/${tag}"
  curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 "${base}/checksums.txt" -o "$checksums" || { gha_error "failed to download checksums for $tag"; return 1; }
  matches="$(awk '$2 == "buildkite-gha_Linux_x86_64.tar.gz" && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ { print tolower($1) }' "$checksums")"
  [[ "$(printf '%s\n' "$matches" | grep -c .)" -eq 1 ]] || { gha_error "checksums.txt must contain exactly one valid archive checksum"; return 1; }
  checksum="$(printf '%s' "$matches")"

  cache_hit=false
  if [[ -f "$cached_archive" && ! -L "$cached_archive" ]] && cp -- "$cached_archive" "$archive" 2>/dev/null; then
    actual_checksum="$(sha256sum "$archive" | awk 'NR == 1 { print tolower($1) }')" || actual_checksum=""
    [[ "$actual_checksum" != "$checksum" ]] || cache_hit=true
  fi
  if [[ "$cache_hit" != true ]]; then
    rm -f -- "$archive"
    if [[ -e "$destination" || -L "$destination" ]]; then
      invalid="${destination}.invalid.$$"
      if mv -- "$destination" "$invalid" 2>/dev/null; then
        rm -rf -- "$invalid"
      fi
    fi
    curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 "${base}/buildkite-gha_Linux_x86_64.tar.gz" -o "$archive" || { gha_error "failed to download CLI archive for $tag"; return 1; }
  fi
  actual_checksum="$(sha256sum "$archive" | awk 'NR == 1 { print tolower($1) }')" || { gha_error "could not hash CLI archive"; return 1; }
  [[ "$actual_checksum" == "$checksum" ]] || { gha_error "CLI archive checksum verification failed"; return 1; }
  gha_validate_archive "$archive" "$listing" || return 1

  if [[ ! -f "$cached_archive" || -L "$cached_archive" ]]; then
    staged=""
    if mkdir -p "$(dirname "$destination")" 2>/dev/null &&
      staged="$(mktemp -d "$(dirname "$destination")/.Linux_x86_64.XXXXXX" 2>/dev/null)" &&
      cp -- "$archive" "$staged/buildkite-gha_Linux_x86_64.tar.gz" 2>/dev/null; then
      if ln -sn "${staged##*/}" "$destination" 2>/dev/null; then :; else
        rm -rf -- "$staged" 2>/dev/null || :
      fi
    else
      [[ -z "$staged" ]] || rm -rf -- "$staged" 2>/dev/null || :
      gha_error "cache '$root' could not store the CLI archive; continuing without caching"
    fi
  fi

  run="$(mktemp -d "${TMPDIR:-/tmp}/github-actions-buildkite-plugin-run.XXXXXX")" || return 1
  tar -xzf "$archive" -C "$run" || { rm -rf "$run"; gha_error "failed to extract CLI archive"; return 1; }
  gha_verify_distribution "$run" "$version" || { rm -rf "$run"; gha_error "extracted CLI failed validation"; return 1; }
  printf '%s\n' "$run"
)
