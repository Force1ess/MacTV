# Build MacTV

[简体中文](BUILDING.zh-CN.md)

## Requirements

- Apple Silicon Mac with Xcode 26 / macOS 26 SDK or later.
- Node.js 22, npm, Python 3 and Git.
- The app deployment target is macOS 15.0. Runtime validation on macOS 15 is still pending.

## Build and run

```sh
git clone https://github.com/Force1ess/MacTV.git
cd MacTV
npm --prefix tools ci
ruby tools/build/prepare-release-runtime.rb
make build
open dist/MacTV.app
```

Runtime preparation downloads verified binaries and matching source, then rebuilds MPV with the macOS audio fix. Install optional plugins in MacTV from the official plugin source.

`make package` creates a versioned DMG in `dist/packages`. Tag releases are described in [Releasing](RELEASING.md).

## Development signing

For repeated local installations, configure a stable signing identity:

```sh
bash tools/build/setup-rcodesign.sh
ruby tools/build/file-signing.rb setup
make build
```

Keep the signing key outside Git. Development signing is separate from Developer ID signing and notarization.

See [Testing](TESTING.md), [Architecture](ARCHITECTURE.md), and [Plugin development](PLUGIN-DEVELOPMENT.md) for further work.
