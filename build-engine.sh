#!/usr/bin/env bash
# build-engine.sh - build a portable Flutter engine SDK from source.
#
# This follows the Linux builds in meta-flutter/flutter-engine (Apache-2.0;
# see README.md for provenance), with the engine patches of patches/ applied,
# and the build's own toolchain patch (toolchain/):
#
#   linux-engine-sdk-<mode>-<arch>-<revision>-<patchset>.tar.gz
#   linux-engine-sdk-<mode>-<arch>-<revision>-<patchset>.tar.gz.sha256
#
# <patchset> is the content of PATCHSET: the engine is not upstream's at
# <revision>, so its artifacts must not pass for it. Bump PATCHSET whenever
# patches/ changes.
#
# The tarball contains flutter/engine/src/out/<out>/engine-sdk/{include,lib},
# which is what Veshell's dev build and packaging/scripts/build-veshell.sh read.
# It is built against the Debian bullseye sysroot so it runs on Debian/Fedora,
# unlike the Nix engine build (whose outputs are patched to the Nix loader).
# arm64 is cross-compiled, as Flutter itself does.
#
# Usage: build-engine.sh MODE ARCH REVISION OUT_DIR [WORK_DIR]
#   MODE      release | debug | profile | debug-unopt
#   ARCH      x86_64 | arm64
#   REVISION  Flutter engine revision (SDK bin/internal/engine.version)
#   OUT_DIR   where the tarball and .sha256 are written
#   WORK_DIR  scratch checkout (default: $PWD/engine-build)
set -euo pipefail

usage='usage: build-engine.sh MODE ARCH REVISION OUT_DIR [WORK_DIR]'
mode="${1:?$usage}"
target_arch="${2:?$usage}"
revision="${3:?$usage}"
out_dir="${4:?$usage}"
work="${5:-$PWD/engine-build}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
patchset="$(tr -d '[:space:]' < "$script_dir/PATCHSET")"
[[ -n "$patchset" ]] || { printf 'PATCHSET is empty\n' >&2; exit 1; }

case "$target_arch" in
  x86_64)
    arch=x64
    linux_cpu=x64
    target_triple=x86_64-unknown-linux-gnu
    target_sysroot=debian_bullseye_amd64-sysroot
    ;;
  arm64)
    arch=arm64
    linux_cpu=arm64
    target_triple=aarch64-unknown-linux-gnu
    target_sysroot=debian_bullseye_arm64-sysroot
    ;;
  *) printf 'unknown architecture: %s\n' "$target_arch" >&2; exit 2 ;;
esac

case "$mode" in
  release)     gn_mode=release; out_name=linux_release_$linux_cpu ;;
  debug)       gn_mode=debug;   out_name=linux_debug_$linux_cpu ;;
  profile)     gn_mode=profile; out_name=linux_profile_$linux_cpu ;;
  debug-unopt) gn_mode=debug;   out_name=linux_debug_unopt_$linux_cpu ;;
  *) printf 'unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac

asset="linux-engine-sdk-${mode}-${target_arch}-${revision}-${patchset}"
mkdir -p "$out_dir" "$work"
out_dir="$(cd "$out_dir" && pwd)"
work="$(cd "$work" && pwd)"
engine_src="$work/flutter/engine/src"
sdk_rel="flutter/engine/src/out/${out_name}/engine-sdk"

log() { printf '\n==> %s\n' "$*" >&2; }

log "Preparing depot_tools"
if [[ ! -d "$work/depot_tools" ]]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$work/depot_tools"
fi
export PATH="$work/depot_tools:$PATH"
export VPYTHON_VIRTUALENV_ROOT="$work/vpython"

log "Syncing the Flutter engine sources at $revision"
if [[ ! -d "$work/flutter" ]]; then
  git clone --depth 1 https://github.com/flutter/flutter.git "$work/flutter"
fi
(
  cd "$work/flutter"
  gclient config --spec 'solutions=[{"managed":False,"name":".","url":"https://github.com/flutter/flutter.git","custom_deps":{},"custom_vars":{"download_android_deps":False,"download_windows_deps":False,"download_linux_deps":True},"deps_file":"DEPS","safesync_url":""}]'
  gclient sync --force --shallow --no-history -R -D --revision "$revision" -j"$(nproc)" -v
)

log "Installing the $target_sysroot sysroot"
(
  cd "$engine_src"
  build/linux/sysroot_scripts/install-sysroot.py --arch="$arch"
)

# patches/ changes the engine, and is shared with the Nix build
# (free-explorers/flutter-engine-nix); toolchain/ only adapts this build.
for patch_file in "$script_dir"/toolchain/*.patch "$script_dir"/patches/*.patch; do
  log "Applying $(basename "$patch_file")"
  if ! ( cd "$work/flutter" && git apply "$patch_file" ); then
    if ( cd "$work/flutter" && git apply --reverse --check "$patch_file" ); then
      log "$(basename "$patch_file") already applied"
    else
      printf 'error: could not apply %s\n' "$patch_file" >&2
      exit 1
    fi
  fi
done

log "Configuring the $gn_mode build"
(
  cd "$engine_src"
  clang_root="$(find . -iname clang++ -print -quit)"
  [[ -n "$clang_root" ]] || { printf 'clang++ not found after sync\n' >&2; exit 1; }
  clang_root="$(dirname "$clang_root")"
  clang_root="$(dirname "$clang_root")"
  gn_args=(
    "--runtime-mode=$gn_mode"
    --embedder-for-target
    --no-build-embedder-examples
    --no-goma --no-rbe
    --no-stripped --no-enable-unittests
    --no-dart-version-git-info
    --linux-cpu "$linux_cpu"
    --target-os linux
    --target-sysroot "$PWD/build/linux/$target_sysroot"
    --target-toolchain "$PWD/$clang_root"
    --target-triple "$target_triple"
  )
  [[ "$mode" == debug-unopt ]] && gn_args+=(--unoptimized)
  ./flutter/tools/gn "${gn_args[@]}"
  ninja -C "out/$out_name"
)

log "Packaging the SDK"
sdk_dir="$work/$sdk_rel"
rm -rf "$sdk_dir"
mkdir -p "$sdk_dir/include" "$sdk_dir/lib"
if [[ -f "$engine_src/out/$out_name/flutter_embedder.h" ]]; then
  cp "$engine_src/out/$out_name/flutter_embedder.h" "$sdk_dir/include/flutter_embedder.h"
else
  cp "$engine_src/flutter/shell/platform/embedder/embedder.h" "$sdk_dir/include/flutter_embedder.h"
fi
cp "$engine_src/out/$out_name/libflutter_engine.so" "$sdk_dir/lib/"
test -s "$sdk_dir/include/flutter_embedder.h"
test -s "$sdk_dir/lib/libflutter_engine.so"

tar -C "$work" -czf "$out_dir/$asset.tar.gz" "$sdk_rel/"
(
  cd "$out_dir"
  sha256sum -b "$asset.tar.gz" > "$asset.tar.gz.sha256"
)
log "Wrote $out_dir/$asset.tar.gz"
cat "$out_dir/$asset.tar.gz.sha256"
