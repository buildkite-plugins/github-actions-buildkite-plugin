#!/usr/bin/env bash

MISE_BOOTSTRAP_VERSION="2026.8.4"
MISE_BOOTSTRAP_SHA256="7d49c0c3633572f57e2383aec5284067675122b6824990f6ac927c5a40c81994"
MISE_MINIMUM_VERSION="2026.5.12"

mise_error() { echo "github-actions plugin: $*" >&2; }

mise_version() {
  local output
  output="$("$1" version 2>/dev/null)" || return 1
  if [[ "$output" =~ v?([0-9]{4})\.([0-9]+)\.([0-9]+) ]]; then
    printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return
  fi
  return 1
}

mise_is_compatible() {
  local version year month patch
  version="$(mise_version "$1")" || return 1
  IFS=. read -r year month patch <<< "$version"
  (( year > 2026 ||
    (year == 2026 && month > 5) ||
    (year == 2026 && month == 5 && patch >= 12) ))
}

mise_data_dir() {
  if [[ -n "${MISE_DATA_DIR:-}" ]]; then
    printf '%s\n' "$MISE_DATA_DIR"
  elif [[ "${BUILDKITE_COMPUTE_TYPE:-self-hosted}" == hosted && -d /cache/bkcache && -w /cache/bkcache ]]; then
    printf '%s\n' /cache/bkcache/mise
  elif [[ -n "${BUILDKITE_AGENT_DATA_PATH:-}" ]]; then
    printf '%s\n' "${BUILDKITE_AGENT_DATA_PATH}/cache/mise"
  elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
    printf '%s\n' "${XDG_DATA_HOME}/mise"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "${HOME}/.local/share/mise"
  else
    mise_error "HOME, XDG_DATA_HOME, MISE_DATA_DIR, or BUILDKITE_AGENT_DATA_PATH is required to install mise"
    return 1
  fi
}

install_mise() (
  local destination_dir archive extracted staged url checksum_output actual_checksum
  for command in curl tar sha256sum mktemp cp; do
    command -v "$command" >/dev/null 2>&1 || {
      mise_error "required command '$command' was not found"
      return 1
    }
  done

  destination_dir="$(dirname "$MISE_BIN")"
  mkdir -p "$destination_dir"
  archive="$(mktemp "${TMPDIR:-/tmp}/mise.tar.gz.XXXXXX")"
  extracted="$(mktemp -d "${TMPDIR:-/tmp}/mise.XXXXXX")"
  staged="$(mktemp "${destination_dir}/.mise.XXXXXX")"
  trap 'rm -rf -- "$archive" "$extracted" "$staged"' EXIT

  url="https://github.com/jdx/mise/releases/download/v${MISE_BOOTSTRAP_VERSION}/mise-v${MISE_BOOTSTRAP_VERSION}-linux-x64-musl.tar.gz"
  echo "github-actions plugin: installing mise ${MISE_BOOTSTRAP_VERSION}" >&2
  curl --disable --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "$url" --output "$archive"
  checksum_output="$(sha256sum "$archive")"
  actual_checksum="${checksum_output%% *}"
  [[ "$actual_checksum" == "$MISE_BOOTSTRAP_SHA256" ]] || {
    mise_error "mise release archive checksum verification failed"
    return 1
  }

  unset TAR_OPTIONS GZIP
  tar -xozf "$archive" -C "$extracted"
  [[ -f "$extracted/mise/bin/mise" && ! -L "$extracted/mise/bin/mise" ]] || {
    mise_error "mise release archive has an unexpected layout"
    return 1
  }
  cp -- "$extracted/mise/bin/mise" "$staged"
  chmod 0755 "$staged"
  mv -f -- "$staged" "$MISE_BIN"
  [[ "$(mise_version "$MISE_BIN")" == "$MISE_BOOTSTRAP_VERSION" ]] || {
    mise_error "installed mise reported an unexpected version"
    return 1
  }
)

setup_mise() {
  local candidate data_dir
  data_dir="$(mise_data_dir)"
  export MISE_DATA_DIR="$data_dir"
  if candidate="$(command -v mise 2>/dev/null)" && mise_is_compatible "$candidate"; then
    MISE_BIN="$candidate"
    return
  fi

  if [[ -n "${candidate:-}" ]]; then
    mise_error "mise on PATH is older than ${MISE_MINIMUM_VERSION}; using the managed version"
  fi
  MISE_BIN="${data_dir}/github-actions-buildkite-plugin/mise/${MISE_BOOTSTRAP_VERSION}/mise"
  if ! mise_is_compatible "$MISE_BIN"; then
    install_mise
  fi
}
