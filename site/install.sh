#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'Factory installer: %s\n' "$*" >&2; exit 1; }

download() {
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 180 --max-filesize "$3" "$1" --output "$2"
}

main() (
  set -euo pipefail
  umask 077
  version=latest
  repository=${FACTORY_RELEASE_REPO:-farazshaikh/factory-dist}
  install_root=${FACTORY_INSTALL_ROOT:-"$HOME/.local/share/factory"}
  bin_dir=${FACTORY_BIN_DIR:-"$HOME/.local/bin"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) [[ $# -ge 2 ]] || fail 'Missing --version value'; version=$2; shift 2 ;;
      --help) printf 'Usage: bash install.sh [--version SEMVER]\nEnvironment: FACTORY_RELEASE_REPO, FACTORY_INSTALL_ROOT, FACTORY_BIN_DIR\nRequires OpenSSL RSA-PSS support. Verifies publisher signature before executing the binary, then checks current TUF metadata.\n'; return ;;
      *) fail "Unknown argument: $1" ;;
    esac
  done
  [[ "$repository" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$ ]] || fail 'Invalid release repository'
  stable_pattern='^[0-9]+\.[0-9]+\.[0-9]+([+][a-zA-Z0-9.-]+)?$'
  [[ "$version" == latest || "$version" =~ $stable_pattern ]] || fail 'Version must be a stable SemVer, not a release tag'
  [[ "$install_root" == /* && "$bin_dir" == /* ]] || fail 'Install directories must be absolute paths'
  for utility in curl tar mktemp uname awk openssl; do command -v "$utility" >/dev/null || fail "Required command missing: $utility"; done
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
    Darwin/arm64|Darwin/aarch64) target=aarch64-apple-darwin ;;
    Darwin/x86_64) target=x86_64-apple-darwin ;;
    *) fail 'Supported platforms: Linux x86-64, macOS Apple Silicon, macOS Intel' ;;
  esac
  if command -v sha256sum >/dev/null; then checksum_tool=sha256sum
  elif command -v shasum >/dev/null; then checksum_tool=shasum
  else fail 'SHA-256 verification requires sha256sum or shasum'; fi
  if [[ -e "$bin_dir/factory" || -L "$bin_dir/factory" ]]; then
    [[ -L "$bin_dir/factory" && -x "$bin_dir/factory" ]] || fail "Refusing to overwrite $bin_dir/factory"
    case "$(readlink "$bin_dir/factory")" in
      "$install_root"/releases/*/bin/factory) ;;
      *) fail 'Refusing to replace an unmanaged symlink' ;;
    esac
    if [[ "$version" != latest ]]; then
      installed_version=$("$bin_dir/factory" --version)
      [[ "${installed_version##* }" == "$version" ]] || fail 'An existing installation can only update through the current signed stable channel; omit --version'
      printf 'Factory %s is already installed.\n' "$version"
      return
    fi
    printf 'Managed installation found; checking the signed stable channel.\n'
    "$bin_dir/factory" update stage
    printf 'If a newer release was staged, activate it with: %s update apply\nRunning servers were not restarted.\n' "$bin_dir/factory"
    return
  fi
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  base="https://${repository%%/*}.github.io/${repository#*/}/updates"
  selector=$version
  [[ "$selector" != latest ]] || selector=stable
  download "$base/install/$selector-$target.txt" "$work/index" 256
  IFS=' ' read -r selected expected extra < "$work/index" || fail 'Missing bootstrap index'
  [[ "$selected" =~ $stable_pattern && "$expected" =~ ^[a-f0-9]{64}$ && -z "$extra" ]] || fail 'Invalid bootstrap index'
  [[ "$version" == latest || "$version" == "$selected" ]] || fail 'Bootstrap version mismatch'
  package="factory-$target"
  archive="factory-$selected-$target.tar.gz"
  printf 'Downloading Factory %s for %s.\n' "$selected" "$target"
  download "$base/targets/$archive" "$work/$archive" 536870912
  download "$base/install/$selected-$target.json" "$work/descriptor.json" 65536
  if [[ "$checksum_tool" == sha256sum ]]; then actual=$(sha256sum "$work/$archive")
  else actual=$(shasum -a 256 "$work/$archive"); fi
  [[ "${actual%% *}" == "$expected" ]] || fail 'Package checksum mismatch; nothing installed'
  download "$base/targets/publisher.pem" "$work/publisher.pem" 16384
  download "$base/targets/$archive.sig" "$work/archive.sig" 1024
  openssl pkey -pubin -in "$work/publisher.pem" -outform DER -out "$work/publisher.der" \
    || fail 'OpenSSL cannot decode publisher key'
  if [[ "$checksum_tool" == sha256sum ]]; then public_hash=$(sha256sum "$work/publisher.der")
  else public_hash=$(shasum -a 256 "$work/publisher.der"); fi
  [[ "${public_hash%% *}" == 80d4d6cf32c2dfbd7a4558881997602a8a062ab28faa0a98429dcb3093e7befb ]] \
    || fail 'Publisher key does not match the pinned signing identity; nothing installed'
  openssl dgst -sha256 -verify "$work/publisher.pem" -signature "$work/archive.sig" \
    -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 -sigopt rsa_mgf1_md:sha256 "$work/$archive" \
    || fail 'Publisher signature verification failed; nothing installed'
  printf 'Publisher signature verified. Checking current signed release metadata during installation.\n'
  tar -tzf "$work/$archive" > "$work/entries"
  awk -v root="$package" '
    $0 != root && index($0, root "/") != 1 { exit 1 }
    /(^|\/)\.\.(\/|$)/ || /\\/ { exit 1 }
    seen[$0]++ { exit 1 }
  ' "$work/entries" || fail 'Unsafe package paths'
  tar -tvzf "$work/$archive" | awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { exit 1 }' \
    || fail 'Package contains unsupported links or special files'
  tar -xOzf "$work/$archive" "$package/bin/factory" > "$work/factory"
  [[ -s "$work/factory" ]] || fail 'Missing Factory executable'
  chmod 700 "$work/factory"
  FACTORY_INSTALL_ROOT="$install_root" FACTORY_BIN_DIR="$bin_dir" \
    "$work/factory" update install --package "$work/$archive" --manifest "$work/descriptor.json"
  [[ -L "$bin_dir/factory" && -x "$bin_dir/factory" ]] || fail 'Installer did not create the managed executable'
  printf '\nFactory installed at %s\n' "$bin_dir/factory"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) printf 'Add this directory to your shell PATH: %s\n' "$bin_dir" ;;
  esac
  printf 'In your project: factory init --name "My Project"\nThen: factory serve web\n'
)

main "$@"