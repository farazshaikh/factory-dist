#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'Factory installer: %s\n' "$*" >&2; exit 1; }

main() {
  local version=latest repository=${FACTORY_RELEASE_REPO:-farazshaikh/factory-dist}
  local install_root=${FACTORY_INSTALL_ROOT:-"$HOME/.local/share/factory"}
  local bin_dir=${FACTORY_BIN_DIR:-"$HOME/.local/bin"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) [[ $# -ge 2 ]] || fail 'Missing --version value'; version=$2; shift 2 ;;
      --help) printf 'Usage: bash install.sh [--version RELEASE_TAG]\nEnvironment: FACTORY_RELEASE_REPO, FACTORY_INSTALL_ROOT, FACTORY_BIN_DIR\n'; return ;;
      *) fail "Unknown argument: $1" ;;
    esac
  done
  [[ "$repository" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || fail 'Invalid release repository'
  [[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail 'Invalid release tag'
  [[ "$install_root" == /* && "$bin_dir" == /* ]] || fail 'Install directories must be absolute paths'
  local utility
  for utility in curl tar mktemp uname awk; do command -v "$utility" >/dev/null || fail "Required command missing: $utility"; done
  local target
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
    Darwin/arm64|Darwin/aarch64) target=aarch64-apple-darwin ;;
    Darwin/x86_64) target=x86_64-apple-darwin ;;
    *) fail 'Supported platforms: Linux x86-64, macOS Apple Silicon, macOS Intel' ;;
  esac
  local checksum_tool
  if command -v sha256sum >/dev/null; then checksum_tool=sha256sum
  elif command -v shasum >/dev/null; then checksum_tool=shasum
  else fail 'SHA-256 verification requires sha256sum or shasum'; fi
  mkdir -p "$install_root/releases" "$bin_dir"
  install_root=$(cd "$install_root" && pwd -P)
  bin_dir=$(cd "$bin_dir" && pwd -P)
  if [[ -e "$bin_dir/factory" || -L "$bin_dir/factory" ]]; then
    [[ -L "$bin_dir/factory" ]] || fail "Refusing to overwrite $bin_dir/factory"
    case "$(readlink "$bin_dir/factory")" in
      "$install_root"/releases/*/factory-*/bin/factory) ;;
      *) fail "Refusing to replace an unmanaged symlink: $bin_dir/factory" ;;
    esac
  fi
  local work
  work=$(mktemp -d "$install_root/releases/.install-XXXXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  local base="https://github.com/$repository/releases"
  if [[ "$version" == latest ]]; then base="$base/latest/download"
  else base="$base/download/$version"; fi
  local package="factory-$target" archive="factory-$target.tar.gz"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "$base/$archive" --output "$work/$archive"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "$base/SHA256SUMS" --output "$work/SHA256SUMS"
  local expected actual
  expected=$(awk -v name="$archive" '$2 == name { print $1 }' "$work/SHA256SUMS")
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Missing or ambiguous package checksum'
  if [[ "$checksum_tool" == sha256sum ]]; then actual=$(sha256sum "$work/$archive")
  else actual=$(shasum -a 256 "$work/$archive"); fi
  [[ "${actual%% *}" == "$expected" ]] || fail 'Package checksum mismatch; nothing installed'
  tar -tzf "$work/$archive" > "$work/entries"
  awk -v root="$package" '
    $0 != root && index($0, root "/") != 1 { exit 1 }
    /(^|\/)\.\.(\/|$)/ { exit 1 }
  ' "$work/entries" || fail 'Unsafe package paths'
  tar -tvzf "$work/$archive" | awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { exit 1 }' \
    || fail 'Package contains unsupported links or special files'
  tar -xzf "$work/$archive" -C "$work"
  [[ -x "$work/$package/bin/factory" && -f "$work/$package/share/factory/ui/index.html" ]] \
    || fail 'Incomplete Factory package'
  "$work/$package/bin/factory" --version
  local installed
  installed=$(mktemp -d "$install_root/releases/$target-XXXXXXXX")
  mv "$work/$package" "$installed/$package"
  local link_dir
  link_dir=$(mktemp -d "$bin_dir/.factory-link-XXXXXXXX")
  ln -s "$installed/$package/bin/factory" "$link_dir/factory"
  mv -f "$link_dir/factory" "$bin_dir/factory"
  rmdir "$link_dir"
  rm -rf -- "$work"
  trap - EXIT
  printf '\nFactory installed at %s\n' "$bin_dir/factory"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) printf 'Add this directory to your shell PATH: %s\n' "$bin_dir" ;;
  esac
  printf 'In your project: factory init --name "My Project"\nThen: factory serve web\n'
}

main "$@"