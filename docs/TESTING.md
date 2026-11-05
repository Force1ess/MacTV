# Development and testing

[简体中文](TESTING.zh-CN.md)

Build with Xcode 26 / the macOS 26 SDK or later. Hosted source CI selects Xcode
26.3 on `macos-15-intel` and records the compiler/SDK versions. ARM hosted jobs
previously expired before runner allocation; Intel source checks do not replace
Apple Silicon runtime or television verification.

## Automated checks

```sh
npm --prefix tools ci
npm --prefix tools run check:integrations
npm --prefix tools run test:integrations
bash tools/check/test.sh
ruby tools/check/check-source-release.rb
```

`test.sh` supplies the Swift Testing framework paths for standalone Command Line
Tools. Append a filter such as `--filter MetadataTokenStoreTests` for a targeted
run. Machine error identifiers use the separate `MTVError.code` case and are not
localized. User messages use the locale catalog; parameterized errors retain
paths/names as data. Metadata throttling uses a typed rate-limit result, not
matching translated words. Keep assertions and permission checks; do not skip app compilation to hide
an SDK mismatch. Hosted CI explicitly uses `--no-parallel` for the full suite
to keep unrelated filesystem fixtures from starving deadline-bound socket tests
on its small runner. Concurrency and cancellation tests still run their own
concurrent operations; no tests or production deadlines are removed.

## Preview build storage

Repeated development builds keep rollback bundles in `dist/previous` and
`backups`. For long-running development, configure a mounted external archive:

```sh
ruby tools/build/preview-artifacts.rb --configure \
  --archive-root /Volumes/ArchiveDisk/.MacTV-Development/preview-archives --keep 3
ruby tools/build/preview-artifacts.rb --apply \
  --archive-root /Volumes/ArchiveDisk/.MacTV-Development/preview-archives --keep 3 --limit 2000
```

Replace ArchiveDisk with your mounted volume. Configuration stays in ignored
`.build/preview-artifact-archive.json`, not Git. Builds and actual installs then
archive older generated bundles in bounded batches, retaining recent rollback
copies in each directory. Test-mode relaunch does not make another backup.
No configuration means no automatic archive. `--disable` removes only the local
configuration and preserves archives.

The tool accepts generated preview names and the preview bundle identifier only;
it excludes running bundles and arbitrary backup folders. Copy completion,
metadata shape and an unchanged source are checked before removing the source.
It refuses existing destinations, linked paths and an absent external volume.
The installed app, signing keys, sessions, source and media are outside its scope.
A hidden archive inside a media drive is excluded by normal hidden-folder scanning.
`tools/check/test-preview-artifacts.rb` exercises these guards on owned fixtures.

## Installed-app tests

Prefer structured [local control](LOCAL-CONTROL.md) state/events for text,
options, navigation and workflow state. Export the app's own images to a local
temporary directory only when layout, animation or picture output needs visual
review. Do not use desktop screen scraping for ordinary state checks.

Use the supervised entry point for `/Applications/MacTV.app`:

```sh
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed --modern-playback-only
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed --system-text-input-only
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed --source-management-only
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed --chrome-login-only
ruby tools/check/run-interactive-test.rb --ui-smoke --owned-regression --developer-mode --tv-layout
```

Run one instance at a time. The normal app must be foreground and idle for five
minutes, without playback or overlays. Direct installed test launches are refused
before stopping the normal app. Tests use an isolated preference domain and save
a PID, run directory and results under TestResults. A native guardian exits on
new user input or supervisor loss and restores normal MacTV when the test ends.
Do not add diagnostic flags to the user's visible playback session.

Modern playback covers real owned media, tracks, subtitles, playback menus,
Escape/Backspace mapping, credits and native license scrolling. Chrome fixtures
do not establish real-account import. `--owned-regression` explicitly selects
owned starting media; it is never a fallback when a real NAS fails. Normal and
unscoped full tests still initialize the selected real source. Native input
requires an interactive desktop; background/locked-screen failures are failures.

### Actual system dictation

`--system-text-input-only` checks native input and voice-key routing, without
starting a microphone. Actual transcription needs the explicit scope below:

```sh
say -v Tingting -r 130 -o /tmp/mactv-owned-speech.aiff \
  '[[slnc 1000]]这是语音输入测试[[slnc 1000]]'
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed --system-dictation-only \
  --dictation-fixture /tmp/mactv-owned-speech.aiff \
  --dictation-virtual-input MiRemoteV2ch_UID --dictation-audio-start input-ready
```

Only an explicitly selected default virtual input (`MiRemoteV2ch_UID` or
`BlackHole2ch_UID`) is accepted, with at most ten seconds of owned audio. There
is no fallback to a physical microphone/television or change to default devices.
The test starts the actual system command through the native insertion point,
sends owned speech to the selected virtual output and waits for real text and
search confirmation. Native Enter is the default; `--dictation-start-method direct`
is a separate command-dispatch diagnostic. Audio-start modes keep microphone
startup and speech timing observable. Received text is preserved verbatim; a
strict phrase mismatch is not repaired by substituting the expected phrase.
The fixture uses slower speech and one-second boundary silence. Native marked-text
delivery is valid and is checked alongside insertions; Done must still commit the
actual text, and the original exact phrase assertions remain required.

### HDMI audio output

With an HDMI display connected and the owned AudioTimeline fixture prepared,
run the explicit quiet hardware scope:

```sh
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed \
  --audio-output-only --test-audible-output
```

This is the only UI-test scope that unmutes AVPlayer and MPV, at no more than
10% application volume. Other UI tests stay muted. It uses the owned fixture,
not a NAS fallback, and never changes the system default device or system volume.
MPV's requested `audio-device` is only configuration: the check separately reads
its actual CoreAudio output driver, advancing audio clock and format, and this
process's running-output device list through CoreAudio. No tap or capture is used.
The HDMI fixture exposed the bundled MPV 0.41 CoreAudio driver misusing the
AudioUnit channel-map API on macOS 27. The explicit stereo experiment failed too;
its records are retained and the ineffective channel override was removed. The
native runtime needs upstream fix `3dae21b1ed4793912a8f9de1c5eb3cf32d227bce`.
The report still marks television speaker audibility unverified; passing software
routing does not establish the television's volume, speakers or picture quality.

### Timeline and title layout

`--player-timeline-only` checks the current system and MPV paths, preview,
confirm/cancel, actual backend clocks and native pointer dragging. Legacy VLC is
not bundled and its historical suite is not counted as this scope. Fields such
as `requestedScopeFullyVerified` and `nativePointerDragVerified` retain separate
results; passing some checks does not imply native drag was observed.

```sh
ruby tools/check/test-bilibili-focus-layout.rb 18
```

On an idle controlled app, this reads the real homepage and follows directional
navigation across cards. It binds to the PID/run ID, waits for title geometry to
stay stable for 500 ms and checks expanded titles against the viewport. Reports
include sample count, expanded-title count and maximum height, without reading
images or Chrome. Failed pagination is not replaced by generated content. The
sample does not represent every title; zero expanded titles remains explicitly
zero. Layout settling is not part of the playback first-frame clock.

`test-quark-native-playback.rb --export-controls-layout` captures only the paused
app content through separately enabled visual export. Reports retain the file
location. The test does not interpret pixels; movie frames, sound and HDR output
remain separate checks.

## Library interfaces

```sh
swift build --product MTVLibraryProbe
.build/debug/MTVLibraryProbe --inspect-selected --check --require-posters
.build/debug/MTVLibraryProbe --inspect /path/to/media --check
```

Cached inspection and fresh scans are distinct. Structural errors, missing
posters and failed operations return nonzero. CLI disk access does not establish
GUI-app permissions. `MTVMetadataProbe --audit-selected` inspects unmatched
content; only `--use-saved-tmdb` reads a saved token. Quit MacTV and back up the
match file before `--apply-automatic`; it does not modify media or NFO files.

## Playback latency

Record resolve, preparation, actual decoded frame, playing state and failures.
Targets live in `config/playback-benchmarks.json`. Keep account mode, quality,
reference, network/cache condition and observer compatible. Retain failed samples,
not just successful requests. The current Quark budget is observed P99 ≤7 s, explicitly requested by the user.
Bilibili 1080p and other lower-resolution paths retain 3 s; the previous decoded-4K
rule (long edge ≥3840, short edge ≥1600) remains 6 s for other providers.
Each new Quark record carries `startupBudgetPolicy=quark-p99-7s-v1`. Legacy
records without that marker keep their original 3 s / 6 s interpretation; an
explicit derived review may assess unchanged measurements against the new limit.
Fewer than 100 trials are development observations,
not P99 acceptance. One first-in-process trial plus repeats is not independent
cold-start evidence. Measure Bilibili and Quark separately.

```sh
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed \
  --playback-benchmark-only --live-services --benchmark-plugin mtv.quark \
  --benchmark-session stored --benchmark-original-file --benchmark-reference FILE_ID \
  --benchmark-runs 100 --benchmark-variant baseline
```

`--benchmark-session guest|stored` is explicit. Bilibili defaults to a guest
comparison; Quark allows stored only. Missing stored login fails rather than
switching to guest. Every sample records account mode and actual quality.
Bilibili materializes a complete provider card before the click clock to preserve
collection/part identity. Failed synthetic-card trials remain in private history.

The libmpv path checks a native source-frame screenshot against decoded dimensions,
includes capture cost and then deletes the image. AVFoundation and libmpv observer
methods are recorded separately. Failures, buffering, source revision and process
condition stay in the record. Use `--benchmark-observe-seconds 30` for a longer
post-frame window (3–300 s; total observation budget 1400 s).

Original Matroska playback uses progressive ordered delivery with at most three
10 MiB native reads per ordered response stream. The shared original-file client
separately caps active transfer jobs at eight; this is not a 30 MiB whole-player
memory limit. Other nonstreaming reads keep a 1 MiB ceiling.
Benchmark-only range-size/depth, head-first, direct-request and no-initial-buffer
flags allow explicit experiments without changing normal settings. Record the
actual producer parameters. Compare like observation windows; never mix a raw
origin-transfer diagnostic with end-to-end startup performance.

The native bridge continuously consumes libmpv events. Frequent UI reads use its
observed cache. The computed frame estimate is requested asynchronously on clock
changes because libmpv does not periodically publish it. Track/settings
confirmation still queries the actual backend. `nativeStartupTimeline` retains
relative numeric stages, not raw player logs, URLs or filenames.
`--benchmark-log-stages` adds header/demux/decoder classification; that diagnostic
cohort is kept separate from normal performance. `playback.diagnostics` exposes
the same structured timeline.

`MTVQuarkProbe origin-layout FILE_ID --approved-quark-media-session` reads bounded
EBML metadata/seek targets without attachment bodies or titles. `origin-transfer`
compares system-proxy and request-local direct transfer without changing proxy
settings. Data-callback results remain distinct from older byte-iteration tests.

## Plugins and launchers

`npm --prefix tools run test:plugins` tests Gallery and Steam UI in isolated plugin-only
checkouts; `npm --prefix tools run build:plugins` produces their installable `dist` folders.
Neither requires the main app source or Xcode.

On an idle development app with `--enable-control --allow-plugin-management`,
`test-example-lifecycle.rb` installs disposable copies, executes and hot-updates
them, disables/enables/removes them, and checks the same PID and unchanged user
packages. `test-plugin-sources.rb` owns a local Git source and exercises URL input,
clone/fetch, review, updates, source disable/remove, stale-review rejection and
independent installed execution. Both clean their fixtures; relaunch normally.
Local Git tests do not prove private GitHub authentication.

`test-launcher-return.rb` opens the installed Steam plugin, observes its declared
window, confirms fullscreen through scoped Accessibility metadata, closes that
window and checks foreground/key-window return without restarting MacTV. It does
not read text fields, terminate Steam or establish physical remote control. Steam
may exit itself when its last window closes.

## Upgrade and release checks

`test-chrome-reader.rb /Applications/MacTV.app/Contents/MacOS/MTVChromeBridge`
checks protocol, malformed arguments, untrusted-parent rejection and absence of
key output without reading a real account. UI tests separately cover cancellation,
late start rejection, authorization gates and Back navigation.

Real grant-retention evidence records first explicit authorization, noninteractive
imports for both platforms after restart, then imports after main-app rebuild and
install. Compare the existing helper code identity. Do not substitute a saved
platform session for a failed Chrome read.

`check-source-release.rb` checks Git-bound files, links, sensitive material and
excluded artifacts. Historical development measurements are retained under
`docs/history` for reproducing earlier results.
`--qa-volatile-history` isolates watch history only during live playback acceptance,
without changing backend, accounts or network policy. Restore a normal launch.
Physical television sound/HDR/Dolby output and remote audio need separate evidence.

### Explicit benchmark audio route

Use `--benchmark-audio-output tv` for the normal Mini HDMI configuration.
`system` remains the explicit/default legacy comparison; missing HDMI, malformed
or duplicate route arguments fail rather than selecting a different route.
The route is isolated to the supervised benchmark and never changes saved app
or system settings. Playback remains muted. Every sample records the requested
route, the native runtime fix, actual audio driver/format/clock and route evidence.
The HDMI assertion is separate from frame outcomes: original samples, first-frame
clock and failure counts are unchanged; budgets follow the explicit recorded policy. Samples from different
output routes are not accepted as a controlled performance comparison.

For television acceptance, also pass `--benchmark-fullscreen`. The app enters
fullscreen before the first click. Each following click waits until the browser
window has returned, is active/key and fills the display; that separate restore
time is recorded, not added to a click that has not happened. During startup,
the actual playback window must be visible on the active Space and, when
requested, fill the display before the decoded frame is accepted. Observer labels
identify the added visibility check. Presentation, window size and backing scale
are recorded; windowed and fullscreen cohorts are not controlled comparisons.
A failed return keeps partial samples and records the setup failure rather than
falling back to windowed playback. No physical display output is inferred.

AVPlayer HDMI validation checks actual own-process CoreAudio device activity as
well as the requested device. Progressive files use their enabled asset audio
track; HLS uses its currently selected, playable audible media-selection option.
A zero static asset-track count is not treated as no audio for HLS. Both selected
media and native output activity are required. Earlier static-track-only failures
remain in test history; this changes route verification, not frame timing.

AVPlayer records dimensions from the same decoded CGImage already required by
the frame observer. Earlier HLS records without this field keep the 3-second
unknown-dimension budget and are not relabeled as proven 1080p samples.

AVPlayer's display-ready notification is recorded separately as `displayReady`.
The verified frame event `renderReady` is recorded only after the active visible
window and decoded CGImage have both been verified, including capture cost, as
on the native path. The observer label distinguishes this corrected clock from
historical AVPlayer notification timestamps; historical rows are not rewritten.

A normal Quark-path benchmark requires `--benchmark-folder FOLDER_ID`. The
provider's real file card is loaded before the click, with bounded pagination;
missing cards fail instead of inventing a filename. MKV cards retain the normal
original-file policy. `--benchmark-original-file` remains an explicit transport
experiment and does not require a synthetic card to pretend it is normal browsing.
Records distinguish requested original transport from the actually active path,
include the file extension (not filename), and retain the card's provenance.
Earlier synthetic Quark transcoding probes are not normal-path acceptance.

Header-based MP4/MOV playback now uses isolated-owner shared connections by
default after 19 owned checks, a 100-trial fullscreen/HDMI cohort and a separate
300-second continuous observation. Headers, entity versions and cancellation
remain per playback; the shared session has no cookie or credential store.
`--test-isolated-header-session` retains the former transport only inside an
explicit UI-test scope. Progressive delivery remains opt-in and is not the default.
