# Third-party code and assets

[简体中文](THIRD-PARTY.zh-CN.md)

MacTV's own code uses the root GPL-3.0 license. Third-party files retain their original copyright notices and licenses.

| Component | Source | Current handling |
| --- | --- | --- |
| libmpv and dependencies | mpv-player/mpv; official Homebrew bottles | Vendor binaries stay outside Git. Packaging records versions, bottle sources and license metadata. |
| MoltenVK | KhronosGroup/MoltenVK; Homebrew | Included in the native GPU runtime; upstream licensing must accompany distribution. |
| librime | rime/librime | BSD; interface headers and upstream license retained in src/Sources/RimeBridge/upstream. |
| Input schemas and dictionaries | Rime luna-pinyin, prelude, stroke and essay | Setup retains LICENSE / AUTHORS; each data package keeps its own terms. |
| OpenCC | Rime's upstream dependency package | License and data provenance are retained. |
| FFmpeg subtitle tool | FFmpeg/FFmpeg | Minimal LGPL build with its corresponding source archive, build script and license. |
| TypeScript | microsoft/TypeScript | Development dependency pinned in tools/package-lock.json. |
| Optional platform icons | Official sites and App Store assets | Downloaded icons stay outside Git and are excluded from default builds. Cards use their manifest's system symbol when an icon is absent. Local provenance is documented in resources/brand-icons/SOURCES.md. |

The source repository excludes downloaded runtime binaries. Complete license texts, corresponding source, relinking materials and permission to redistribute platform icons still need review before a public binary release. SOURCE.json metadata alone does not supply those materials.

The default package excludes VLC. Historical VLC and IINA extraction tools are development comparisons, rather than approved public distribution paths.

## Prepare frozen runtime materials

Use the bottle cache from the build that produced the runtime, together with
that runtime's own `SOURCE.json`:

```sh
ruby tools/build/package-native-mpv.rb --materials-from CACHE SOURCE.json OUTPUT
```

This offline operation copies root-level notices, the frozen formula and its
SPDX source inventory for every component. It never evaluates formula code or
changes installed packages. Add `--fetch-sources` to download archives and
patches whose upstream SHA256 identities are recorded in the frozen inventory.
Missing files, a source-version mismatch or invalid source identity prevent a
complete result. A pinned Git source is fetched at its exact frozen commit,
checked with Git's object verification and archived as a self-contained shallow
repository. Its locally generated archive checksum is identified separately
from an upstream archive checksum. Unpack and clone that repository to rebuild;
the latest upstream branch is never substituted.

`MATERIALS.json` distinguishes material completeness from legal review. A complete
file inventory alone does not approve a binary release. The current 43-component inventory has corresponding source objects and notices collected. Packaging and in-app attribution remain separate release checks. About MacTV now displays the bundled notices; the source-material archive must still accompany a distributed runtime.

Metadata and artwork come from their respective services. About MacTV includes the approved TMDB logo and required application notice, and credits TVmaze with its CC BY-SA license and link. These marks identify the data sources and do not imply endorsement. API access, subscription entitlements and asset use follow the respective service's rules.

Use `--pack-materials MATERIALS ARCHIVE` to package only the declared source, recipe and notice files. `--bundle-notices MATERIALS OUTPUT` prepares the notices and component index for the app bundle without copying source archives into the app. Both retain the separate legal-review status.

The app builder derives its declared minimum macOS version from all bundled Mach-O deployment commands. SDK versions are not deployment targets; a runtime requiring macOS 26 must not be advertised as a macOS 15 binary. Source compatibility is documented separately.

Default builds omit downloaded provider artwork, including assets present only in a developer’s local directory. `MTV_INCLUDE_LOCAL_PROVIDER_ARTWORK=1` is an explicit local-preview option and does not approve redistribution. The approved TMDB attribution mark is packaged separately.

Notice collection reads verified upstream archives even when a bottle has a top-level license summary. Nested full licenses, SPDX texts and license-bearing README files keep distinct source/member names; original legacy-encoded bytes are preserved. The app includes IJG and FreeType acknowledgements plus the complete collected texts. The current audit collects 343 notices for 43 native components; this replaces the earlier summary-only inventory.

## Rime build-dependency notices

`resources/rime/third-party/SOURCES.json` records the exact dependency commits
from the bundled Rime release, plus Boost 1.89.0 from its frozen macOS workflow.
The builder validates and includes 23 original notice files for six upstream
build dependencies. These also retain notices for upstream tests/tools; this is
not a claim that every listed optional tool is linked into the app. The upstream
release target builds plugins separately; MacTV ships only the core librime
dynamic library and its selected data, not the separate Lua/predict/octagram
libraries. Rime's static code is not covered by the MPV-only 343-notice inventory.

Notices are plain text with original upstream bytes. Markdown notices have an
added `.txt` suffix so repository link checking does not interpret their upstream
relative links as MacTV documentation. The provenance index retains pinned source
URLs and archive identities, without hashing individual notice files. Boost's
full source archive is not collected locally; its upstream URL and checksum are
recorded. This notice inventory does not approve the complete binary release.

The current MPV runtime is rebuilt from its matching frozen 0.41.0 source with upstream CoreAudio fix `3dae21b1ed4793912a8f9de1c5eb3cf32d227bce`. It carries the original source, Homebrew patches, additional fix, Vulkan headers and build recipe under `MPVNativeEngine/source/mpv-local-build`. Its metadata distinguishes the base Homebrew bottle from the rebuilt library; the original 43 dependency inventory and notices are retained. See [source-build instructions](../resources/native-mpv/README.md). Full binary redistribution review remains separate.
