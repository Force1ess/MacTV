# Releasing MacTV

The `Release` workflow builds and publishes an Apple Silicon DMG when a
`vMAJOR.MINOR` or `vMAJOR.MINOR.PATCH` tag is pushed. A suffix such as `-beta.1` marks the GitHub
release as a prerelease and prevents it from becoming the latest stable release.
Invalid tags fail before runtime preparation. Source checks also run on pushes.

## Repository configuration

- Enable GitHub Actions and ensure the account has available runner minutes.
- The publish job uses a separate `contents: write` permission. The build job
  has read-only repository access. Optional plugins are installed separately.

Do not put tokens, account sessions, or signing keys in source or artifacts.
This workflow does not change repository visibility.

## Build and artifacts

The ARM `macos-15` runner with Xcode 26.3 prepares the Rime, subtitle, and MPV
runtimes. MPV is rebuilt with the checked-in CoreAudio fix, pinned build tools,
verified Vulkan headers, and the base runtime's matching source inventory.
The release uses the MPV and dependency bottles pinned in
[the runtime lock](../resources/native-mpv/BOTTLES.json). Update the lock and the
rebuild recipe together when upgrading the runtime. Preparation downloads
dependencies without installing them system-wide.

Swift tests, plugin checks, source checks, release-version tests, app signing
verification, and DMG verification must succeed before publication. Artifacts:

- `MacTV-VERSION-arm64.dmg`: the app and installation instructions.
- `MacTV-source.tar.gz`: the tagged MacTV source.
- `MacTV-native-runtime-sources.tar.gz`: the collected base runtime source.
  Rebuilt MPV source, patches, headers and build recipe, and the minimal subtitle
  tool's source are also included inside the app.

The tag supplies the release version; its numeric core is written into
`CFBundleShortVersionString`. The internal build counter supplies `CFBundleVersion`; it is separate from the user-facing version.
The full version, including prerelease suffix, is stored as `MacTVReleaseVersion`.
Checked-in app metadata is not rewritten. Packaging rejects a tag/app mismatch.

These builds use **ad-hoc signing** and are **not notarized**. They do not inherit
the developer's local signing identity or previous permission approvals. A future
Developer ID distribution needs nested runtime signing, hardened-runtime review,
and notarization before claiming normal Gatekeeper installation. Never advise
users to disable system security.

## Publish

After reviewing and testing the desired commit, a maintainer can create and push
a tag, for example:

```sh
git tag -a v1.0-rc.1 -m 'MacTV 1.0 release candidate 1'
git push origin v1.0-rc.1
```

**Pushing the tag publishes a GitHub release after checks pass.** A build or main
branch push alone does not publish. This guide is not an instruction to create a
tag before the release is ready. A tag does not replace playback or device
validation.

If compilation fails, no release is published. If publication fails after the
build succeeds, inspect the `release-package` workflow artifact and rerun only
the failed publish job. Do not move a released tag to different source.

## Deployment target

The app and native runtime target macOS 15. Newer SwiftUI effects and display
APIs remain availability-guarded. The runtime bottle cache is platform-specific,
and both C and MPV's custom Swift compilation target 15.0. Build verification
rejects dependencies above the app target. Actual macOS 15 execution remains
unverified until tested on that OS; a successful newer-system run is insufficient.

If preview Command Line Tools reference SwiftUI macros absent from that tool
installation, select a supported installed SDK explicitly using `SDKROOT`, for
example `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Tests accept the
equivalent `--sdk` argument. This is a workspace build setting, not a global
`xcode-select` change. App packaging asks
SwiftPM for the binary output directory instead of assuming the pre-Swift 7
layout. These build-tool requirements do not raise the app deployment target.
