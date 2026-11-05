# Frozen MPV CoreAudio source rebuild

[简体中文](README.zh-CN.md)

MPV 0.41 passes an `AudioChannelLayout` where the AudioUnit channel-map API
expects an integer array. macOS 27 rejects it with error -50 and disables
audio, including when the HDMI device is configured correctly. This source
build backports [upstream fix 3dae21b](https://github.com/mpv-player/mpv/commit/3dae21b1ed4793912a8f9de1c5eb3cf32d227bce).
It keeps the existing 43-component dependency runtime. It does not force stereo,
change default devices, use an exclusive output, or substitute a null audio sink.
Multichannel speaker mapping remains a separate acceptance item; the upstream
fix notes the pre-existing mapping issue #15584.

Prepare the original runtime's frozen Homebrew bottle cache and source-material
directory using `tools/build/package-native-mpv.rb`. Prepare project-local build
tools with Python's venv and the pinned `meson==1.9.2` and `ninja==1.13.0` packages.
Extract the pkgconf 3.0.10 arm64 Sequoia bottle recorded in `TOOLS.json`, without
installing it. Download the Vulkan-Headers archive pinned in `BUILD.json`.

Run from a MacTV source checkout on an ARM Mac:

```sh
ruby tools/build/rebuild-native-mpv.rb \
  --cache FROZEN_BOTTLE_CACHE --materials SOURCE_MATERIALS \
  --runtime ORIGINAL_RUNTIME --pkgconf EXTRACTED_PKGCONF_ROOT \
  --headers VULKAN_HEADERS_ARCHIVE --output .build/mpv-coreaudio-source-build
```

The command operates offline and checks source identities. `MTV_MESON` and
`MTV_NINJA` can explicitly select the same pinned tool versions. Apple SDK zlib
and bzip2 descriptors come from actual SDK header versions. Frozen pkg-config
metadata and linker aliases are relocated only inside the build workspace.
No source or runtime input is modified, and no system package is installed.
An exclusive workspace lock prevents concurrent builds. A completed preparation
can resume with the same inputs after a compiler/configuration error.

The output `runtime/` retains existing dependencies and notices, replaces only
libmpv, removes absolute build search paths and includes matching MPV source,
the original Homebrew patches, the upstream fix, headers and this build recipe
under `source/mpv-local-build/`. OpenGL, Vulkan, native hardware decoding and
the audio drivers remain enabled. The CLI/manual and unused VapourSynth bridge
are not built. MacTV already disables mpv scripts and uses its own plugin host.

`SOURCE.json` distinguishes the locally rebuilt library from its base bottle.
Its binary checksum is explicitly before application signing; app signing can
change it. `RESULT.json` records build completion, not playback acceptance or
permission to publish. Run the installed-app HDMI and modern-playback checks
after installing the rebuilt runtime. Physical television sound/color and
multichannel mapping require separate evidence.

## macOS compatibility

`BUILD.json` sets the runtime deployment target to macOS 15.0 and selects
`arm64_sequoia` bottles. The full Homebrew formula API is used because the
Homebrew 7 CLI API filters bottle metadata to the build host. Archives are
verified against the official SHA-256 metadata and cached separately by platform;
no system formulae are installed or upgraded.

MPV uses a custom Swift compiler command which does not inherit the C deployment
target. The rebuild explicitly passes the ARM macOS 15 target to Swift and checks
both the intermediate Swift archive and final library. Application packaging
rejects any bundled binary requiring a newer macOS, rather than silently raising
the application's minimum. Binary checks do not replace testing on macOS 15.
