#!/usr/bin/env bash
# Build Warp's OSS-channel Debian package using the Warp source tree's own Linux bundler.

set -Eeuo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
warp_source_input="${WARP_SOURCE_DIR:-$repo_root/../warp}"

[[ -d "$warp_source_input" ]] || fail "Warp source directory not found: $warp_source_input"
warp_source_dir="$(cd -- "$warp_source_input" && pwd)"

[[ -x "$warp_source_dir/script/bundle" ]] || fail "Warp bundle script is not executable at $warp_source_dir/script/bundle"
[[ -f "$warp_source_dir/app/Cargo.toml" ]] || fail "Warp app manifest not found under $warp_source_dir"

cargo_target_input="${CARGO_TARGET_DIR:-$warp_source_dir/target}"
mkdir -p -- "$cargo_target_input"
cargo_target_dir="$(cd -- "$cargo_target_input" && pwd)"
export CARGO_TARGET_DIR="$cargo_target_dir"
export SETTINGS_SCHEMA_CACHE="${SETTINGS_SCHEMA_CACHE:-$cargo_target_dir/.settings_schema_cache.json}"

to_oss_release_tag() {
  local tag="${1#refs/tags/}"

  if [[ "$tag" =~ ^(v[0-9]+(\.[0-9]+)*)\.(dev|preview|stable|oss)_([0-9]+)$ ]]; then
    printf '%s.oss_%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}"
    return 0
  fi

  return 1
}

# Warp's upstream Debian bundler appends apt repository setup for every channel.
# This repository publishes OSS builds as standalone .deb files, so remove that
# setup from the generated maintainer scripts before publishing the package.
strip_apt_repository_setup_from_deb() (
  set -Eeuo pipefail

  local deb_path="$1"
  local work_dir extract_dir rebuilt_deb

  work_dir="$(mktemp -d)"
  trap 'rm -rf -- "$work_dir"' EXIT

  extract_dir="$work_dir/package"
  rebuilt_deb="$work_dir/$(basename -- "$deb_path")"

  dpkg-deb -R "$deb_path" "$extract_dir"

  python3 - "$extract_dir/DEBIAN/postinst" "$extract_dir/DEBIAN/postrm" <<'PY'
from pathlib import Path
import sys

postinst = Path(sys.argv[1])
postrm = Path(sys.argv[2])


def strip_from_marker(path: Path, marker: str) -> None:
    text = path.read_text()
    marker_index = text.find(marker)
    if marker_index >= 0:
        path.write_text(text[:marker_index].rstrip() + "\n")


def append_if_missing(path: Path, marker: str, block: str) -> None:
    text = path.read_text()
    if marker not in text:
        path.write_text(text.rstrip() + "\n\n" + block.strip() + "\n")


strip_from_marker(postinst, "# Determine the path to the apt-config command.\nAPT_CONFIG=")
append_if_missing(
    postinst,
    "Remove stale apt repository files created by older OSS Debian packages",
    r'''
# Remove stale apt repository files created by older OSS Debian packages. The
# OSS channel is distributed as standalone .deb artifacts, not as an apt repo.
APT_CONFIG="$(command -v apt-config 2> /dev/null || true)"
if [ -n "$APT_CONFIG" ]; then
  eval $("$APT_CONFIG" shell APT_SOURCE_LIST_DIR 'Dir::Etc::sourceparts/d')
  if [ -n "${APT_SOURCE_LIST_DIR:-}" ]; then
    rm -f "${APT_SOURCE_LIST_DIR}warpdotdev-oss.list"
    rm -f "${APT_SOURCE_LIST_DIR}warpdotdev-oss.sources"
  fi

  eval $("$APT_CONFIG" shell APT_TRUSTED_KEYRING_DIR 'Dir::Etc::trustedparts/d')
  if [ -n "${APT_TRUSTED_KEYRING_DIR:-}" ]; then
    rm -f "${APT_TRUSTED_KEYRING_DIR}warpdotdev-oss.gpg"
  fi
fi
''',
)

bad_needles = (
    "https://releases.warp.dev/linux/deb",
    'cat > "$APT_SOURCE_LIST"',
    "SIGNING_KEY_PATH",
    "SIGNINGKEY",
)
for script in (postinst, postrm):
    text = script.read_text()
    for needle in bad_needles:
        if needle in text:
            raise SystemExit(f"{script}: repository setup still contains {needle!r}")
PY

  fakeroot dpkg-deb -b "$extract_dir" "$rebuilt_deb" >/dev/null
  mv -f -- "$rebuilt_deb" "$deb_path"
)

if [[ -n "${GIT_RELEASE_TAG:-}" ]]; then
  provided_release_tag="$GIT_RELEASE_TAG"
  if ! GIT_RELEASE_TAG="$(to_oss_release_tag "$provided_release_tag")"; then
    fail "GIT_RELEASE_TAG must be a Warp release tag like v0.YYYY.MM.DD.HH.MM.stable_00 or v0.YYYY.MM.DD.HH.MM.oss_00; got '$provided_release_tag'"
  fi
else
  requested_release_tag=""
  if [[ -n "${WARP_REF:-}" ]]; then
    requested_release_tag="$WARP_REF"
  else
    requested_release_tag="$(git -C "$warp_source_dir" describe --tags --exact-match 2>/dev/null || true)"
  fi

  if [[ -n "$requested_release_tag" ]] && GIT_RELEASE_TAG="$(to_oss_release_tag "$requested_release_tag")"; then
    :
  else
    version_timestamp="$(date -u +%Y.%m.%d.%H.%M)"
    version_suffix="00"
    if [[ "${GITHUB_RUN_NUMBER:-}" =~ ^[0-9]+$ ]]; then
      version_suffix="$(printf '%02d' "$GITHUB_RUN_NUMBER")"
    fi
    GIT_RELEASE_TAG="v0.${version_timestamp}.oss_${version_suffix}"
  fi
fi

[[ "$GIT_RELEASE_TAG" =~ ^v[0-9]+(\.[0-9]+)*\.oss_[0-9]+$ ]] || fail "resolved GIT_RELEASE_TAG must look like v0.YYYY.MM.DD.HH.MM.oss_00; got '$GIT_RELEASE_TAG'"
export GIT_RELEASE_TAG

printf 'Using Warp source: %s\n' "$warp_source_dir"
printf 'Using cargo target dir: %s\n' "$cargo_target_dir"
printf 'Using release tag: %s\n' "$GIT_RELEASE_TAG"

shopt -s nullglob
stale_bundle_dirs=("$cargo_target_dir"/*/bundle/linux)
if ((${#stale_bundle_dirs[@]})); then
  rm -rf -- "${stale_bundle_dirs[@]}"
fi

(
  cd -- "$warp_source_dir"
  ./script/bundle --channel oss --packages deb
)

deb_candidates=("$cargo_target_dir"/*/bundle/linux/warp-terminal-oss_*.deb)
if ((${#deb_candidates[@]} != 1)); then
  printf 'Found %d deb candidate(s):\n' "${#deb_candidates[@]}" >&2
  printf '  %s\n' "${deb_candidates[@]:-}" >&2
  fail "expected exactly one warp-terminal-oss .deb artifact"
fi

deb_path="$(cd -- "$(dirname -- "${deb_candidates[0]}")" && pwd)/$(basename -- "${deb_candidates[0]}")"
package_name="$(dpkg-deb --field "$deb_path" Package)"
architecture="$(dpkg-deb --field "$deb_path" Architecture)"

[[ "$package_name" == "warp-terminal-oss" ]] || fail "unexpected package name '$package_name' in $deb_path"
[[ "$architecture" == "amd64" || "$architecture" == "arm64" ]] || fail "unexpected package architecture '$architecture' in $deb_path"

strip_apt_repository_setup_from_deb "$deb_path"
printf 'Removed apt repository setup from Debian maintainer scripts.\n'

printf 'Built Debian package: %s\n' "$deb_path"
dpkg-deb --info "$deb_path"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'deb_path=%s\n' "$deb_path"
    printf 'deb_name=%s\n' "$(basename -- "$deb_path")"
    printf 'packages_dir=%s\n' "$(dirname -- "$deb_path")"
    printf 'release_tag=%s\n' "$GIT_RELEASE_TAG"
  } >> "$GITHUB_OUTPUT"
fi
