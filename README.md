# flutter-engine

Source-built Linux Flutter engine SDKs for
[Veshell](https://github.com/free-explorers/veshell): the embedder library
(`libflutter_engine.so`) and its header (`flutter_embedder.h`), for x86_64 and
arm64, in the release, debug and profile runtime modes.

## What is built

Flutter's engine at a given revision (the SDK's `bin/internal/engine.version`),
with the engine patches of [`patches/`](patches) applied in order:

- `0002-embedder-partial-repaint-with-a-compositor.patch`: partial repaint for
  embedders that composite with `FlutterCompositor`.
- `0003-flow-do-not-damage-texture-layers-whose-texture-has-no-new-frame.patch`:
  a texture layer whose texture has no new frame is not repainted.
- `0004-embedder-damage-only-what-changed-in-an-external-texture-frame.patch`:
  `FlutterEngineMarkExternalTextureFrameAvailableWithInfo`, so that only the
  damaged part of an external texture's new frame is repainted.

They are the single source of Veshell's engine changes: the Nix build
([free-explorers/flutter-engine-nix](https://github.com/free-explorers/flutter-engine-nix))
applies the same files, pinned by revision. The patches of
[`toolchain/`](toolchain) only adapt this build (the LLVM binutils of Flutter's
own clang toolchain) and are not part of the engine.

[`PATCHSET`](PATCHSET) names this set of patches. The engine is not upstream's,
so every artifact carries it:

```
linux-engine-sdk-<mode>-<arch>-<revision>-<patchset>.tar.gz
linux-engine-sdk-<mode>-<arch>-<revision>-<patchset>.tar.gz.sha256
```

Veshell pins the same value (`flutter_engine_patchset` in its `Cargo.toml`).
Whenever `patches/` changes, bump `PATCHSET` and Veshell's pin together.

The libraries are built against the Debian bullseye sysroot, so they run on
current Debian, Fedora and Arch. arm64 is cross-compiled from x86_64.

## Building

The [Engine Release](.github/workflows/engine-release.yml) workflow builds every
mode and architecture in parallel and publishes one release per artifact. It
is started by hand, or by Veshell's Flutter bump, with the engine revision.

Locally:

```sh
./build-engine.sh release x86_64 <revision> dist
```

The checkout and the build need tens of GB.

## Download and checksum validation

```sh
asset=linux-engine-sdk-release-x86_64-<revision>-<patchset>
curl -L -O https://github.com/free-explorers/flutter-engine/releases/download/$asset/$asset.tar.gz
curl -L -O https://github.com/free-explorers/flutter-engine/releases/download/$asset/$asset.tar.gz.sha256
sha256sum -c $asset.tar.gz.sha256
```

Never use a binary artifact you cannot check against its expected checksum.

## Provenance

The build follows the Linux builds of
[meta-flutter/flutter-engine](https://github.com/meta-flutter/flutter-engine)
(Apache-2.0), from which this repository was forked, including its clang
toolchain patch.
