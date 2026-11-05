# Text state, events and local control

[简体中文](LOCAL-CONTROL.zh-CN.md)

Prefer MacTV's own state, events and operation results over screenshots, pointer
coordinates or screen sharing. Commands operate the same AppModel,
LoginController and player used by the interface, not a simulated implementation.

## Enable

```sh
bash tools/build/build-app.sh
bash tools/build/install-preview.sh --windowed --enable-control
/Applications/MacTV.app/Contents/MacOS/mtvctl status
/Applications/MacTV.app/Contents/MacOS/mtvctl modules
/Applications/MacTV.app/Contents/MacOS/mtvctl navigate settings
/Applications/MacTV.app/Contents/MacOS/mtvctl key backspace
```

Normal launch leaves control disabled. A running same-user endpoint is never
replaced; quit the old instance first. Quitting MacTV stops listening. There is
no persistent service or TCP/HTTP listener. The source-built client is
`.build/release/mtvctl`. Remote use means SSH into the same account on that Mac
and invoke its installed CLI; do not expose a network control port.

Below, `mtvctl` abbreviates the installed absolute path. Use that full path in
noninteractive SSH commands.

## State and events

`status` reports the current PID, build/revision, foreground state, focus,
overlays, library refresh, module/login state and player clock. Media entries
exclude resolved video and artwork URLs. Configured login and platform
verification in this run are separate fields; a fixture is not real login.
`login.buttonDisplayTitles` and `login.displayMessage` match localized interface
copy; legacy `buttons`/`message` remain compatible. Profile names stay verbatim.

Enabled control saves protected files under
`~/Library/Application Support/MTV/Control`:

| File | Content |
| --- | --- |
| state.json | Snapshot with update time and PID. |
| events.jsonl | Latest 512 structured events, including run ID, PID, sequence, time, command acceptance/rejection and state summary. |
| control.sock | Same-user Unix socket. |

Directories use mode 700, files/socket mode 600; both peers verify the same
system user. Cookies, tokens, passwords, QR tickets and signed media addresses
are excluded. Events retain validated keys/section/setting identifiers rather
than raw command arguments. Password length is also excluded. Titles/source
names can still be private: do not publish these logs unprocessed.

A saved file may belong to an earlier process. Live evidence must match `status`,
PID and `controlRunID`; a new process restarts its sequence numbers.

```sh
mtvctl events
mtvctl events 20
```

Pages contain at most 64 events. `nextAfter`, `hasMore` and `oldestAvailable`
make overwritten history explicit.

## Commands

```sh
mtvctl call '{"command":"settings.open","arguments":{"id":"appearance"}}'
```

Argument values are strings. Rejection returns `ok=false`, a stable code and exit
1. A successful read or accepted action exits 0.

| Command | Arguments | Behavior |
| --- | --- | --- |
| status | — | Current instance snapshot. |
| window.show | — | Show/request activation of MacTV's window; never unlock the system. |
| visual.viewport | width / height | Change content size with explicit visual export; refuse fullscreen. |
| visual.export | purpose | App-only image export, limited to layout / animation / playback. |
| events | after | Event pagination. |
| modules | — | Module identities/titles. |
| navigate | section | home / library / bilibili / apps / settings. |
| input.key | key | up/down/left/right/select/back/menu/home/escape/backspace. |
| input.text | text | Enter text only into an open nonsecret editor. |
| input.open | — | Open the nonsecret on-screen keyboard, without a microphone. |
| input.submit | — | Commit an open nonsecret editor; never passwords or account tokens. |
| input.diagnostics | — | Native client, insertion focus and dictation command readiness; refuse secrets, do not start recording. |
| settings.list | — | Groups, stable IDs and descriptions. |
| settings.open | id | Open a setting; `information` opens About MacTV. |
| library.list | offset / limit | Current library page, at most 100 entries. |
| library.refresh | full | Start the current source scan; full is true/false. |
| library.inventory | — | Organizing summary from the app model, without another CLI scan. |
| module.open | plugin | Open the selected module. |
| module.list | offset / limit | Current module page, at most 100 entries. |
| module.next | — | Normal provider pagination; no fabricated page number. |
| item.activate | id | Normal folder opening or playback. |
| item.describe | id | Current item details without playback; truncated previews are marked. |
| account.open | plugin | Platform login panel. |
| account.importChrome | plugin | Explicit local Chrome import, separately gated. |
| account.chromeAccess | — | Read-only Chrome key-item/keychain metadata, no key bytes or grant changes. |
| account.selectProfile | plugin / name | Select only a currently listed profile. |
| account.close | — | Close login. |
| account.revokeMediaSession | plugin | Revoke native media scopes and stop that module's current playback. |
| account.sessionStatus | plugin | Read-only session status, without credentials. |
| playback.toggle / playback.stop | — | Pause/resume or exit playback. |
| playback.rate | rate | A speed supported by the actual player. |
| playback.seek | seconds | Seek the actual backend clock. |
| playback.diagnostics | — | Structured player/transport diagnostics, no credentials or media addresses. |
| application.status / application.inspect | — | Launcher state or scoped selected-application window metadata. |
| gallery.status | — | Photo-read and decode counters. |
| gallery.preview | id | Decode a photo on the current Gallery page; return dimensions, never pixels/URLs. |

Unknown commands and extra arguments are rejected. Requests have IDs, expiry,
connection/frame/read limits. `accepted=true` means an operation started, not
completed: wait for the matching scan, platform verification or actual player
clock. `library.list` and `module.list` require the corresponding page.

A scan returns `result.job`; `libraryScan` exposes that job's running / completed /
limited / failed / timeout / cancelled phase, counts and error domain/code.
Match the job ID, not an old nonzero file count. About state exposes the current
page, selection, notice count, document length and logo presence without needing
a screenshot. `nativeMedia` reports photo/music dimensions, progress and errors,
not file addresses or credentials.

## Real Chrome-import acceptance

```sh
bash tools/build/install-preview.sh --launch-current --windowed --enable-control --allow-account-import
mtvctl import-chrome mtv.quark
mtvctl status
```

The command reuses the app's local profile discovery, platform cookie validation
and live platform verification. It does not read browser databases in SSH.
API decryption is noninteractive by default. The normal UI also tries without a
prompt; only Authorize and Import permits a system confirmation.

The flag grants no macOS permission. `login.chromeImportDiagnostic` separates
profile discovery, cookie reading, platform verification and completion using
stage/domain/code/requiresSystemAuthorization. It excludes session contents.
Same-user isolation does not protect a user account already controlled by malware.

The separate helper controls its own legacy Keychain interaction policy, rather
than changing the keychain lock state or other apps. A noninteractive helper has
a ten-second limit; interactive reads have five minutes, with a twenty-second
noninteractive UI fallback deadline. Close/cancel/timeout terminates that owned
helper and invalidates late replies. Parent exit does not leave it waiting.
Chrome-key reads are single-flight across both platforms/retries; another request
cannot accumulate a second authorization window while the first is outstanding.

A fixed self-signed certificate alone does not preserve every Keychain grant:
Apple's identity handling can use CDHash for code outside a recognized developer
team. The reader is independent of UI/MTVCore, so main-app edits do not inherently
change its code. Installation reports main-app signature requirements and reader
code identity separately. Updating the reader can still require explicit consent;
MacTV does not broaden Chrome's existing key access list.

Implementation references: [Apple process identity](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)
and [Chromium interaction policy](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc).
This is not an authorization bypass: missing access produces an in-app grant page.

The import flag also gates generic navigation: `input.key` cannot bypass it by
selecting Import. Only while someone is handling normal system consent should
`--allow-account-interaction` be added together with `--allow-account-import`.
`accountInteractionEnabled` records this choice. It permits waiting for consent,
not clicking system settings or replacing system authorization.

`account.chromeAccess` asks for item references and lock metadata, not passwords.
`unlocked`, an allow-list count or an existing MacTV path does not prove key-read
permission or live login. Do not combine observations from different security
sessions. `reader=stable-native-helper-v1`, `interactive=false` and successful
platform verification together establish a noninteractive helper import this run.

## Regression checks

```sh
bash tools/check/test.sh --filter LocalControlTests
ruby tools/check/test-app-control.rb /Applications/MacTV.app/Contents/MacOS/mtvctl EXPECTED_PID
ruby tools/check/test-app-control.rb --require-posters /Applications/MacTV.app/Contents/MacOS/mtvctl EXPECTED_PID
ruby tools/check/test-app-control.rb --expect-disabled /Applications/MacTV.app/Contents/MacOS/mtvctl EXPECTED_PID
```

Enabled-app checks require idle playback/overlays. They exercise actual navigation,
both Back keys, settings, fresh-source scans, rejection and events without images,
media modification or real Chrome reads. Action dispatch is separate from physical
remote/native key delivery. Every scan is matched to its job; strict poster mode
fails on missing artwork rather than hiding films. There is no fixed library count
or scheduled task. Disabled mode must use a normally running app without the flag
and reject stale state files. `tools/probes/probe-control-import.rb mtv.quark`
separately tests real import, distinguishing incomplete exit 2 from verified login.

## Observation limits

`--enable-visual-export` is separate from control. Only MacTV's content view is
exported, never the desktop. Login, password, keyboard and SMB panels refuse it.
Protected VisualExports files return a path and pixel dimensions; no image bytes
enter events. Wait for animation/layout to settle, inspect only when needed and
restore a normal launch afterward. Use remote export plus local temporary image
inspection, not CUA to read ordinary text/state.

`input.dictationReadiness` distinguishes absent input, an unready native client,
background window and command availability. `lastDictationRequest` proves only
dispatch. Diagnostics report `microphoneStarted=false` because they do not start
recording. `playback.cursorHideRequested` is an AppKit request, not a pixel-level
observation that the cursor disappeared.

`mediaLayout` exposes actual SwiftUI title bounds, viewport and containment in
content-coordinate points. It is not inferred from title length or a desktop
occlusion test. A stale item's layout is omitted; per-frame geometry changes are
not separate journal events and do not log title text or media addresses.

Cloud thumbnail refusals remain separate from original-image success. A 401,
403, 404 or 410 disables that optional thumbnail for the gallery registration;
the loader may use its already authorized original with the same two-read cap.
Temporary server errors do not silently switch paths. Thumbnail CDNs receive no
account cookies.

## Plugin/source mutation

`plugins.list` is read-only. `--enable-control --allow-plugin-management` separately
enables `plugins.review {directory}`, `plugins.approve {review}`,
`plugins.enable {id,enabled:"true"|"false"}` and `plugins.remove {id}`. Review stages
an exact manifest/package; invalid or missing review tokens cannot install code.
These operations share UI storage, quiescence and reload and grant neither account
import nor shell execution. Restore ordinary launch after developer tests.

`pluginSources.list` excludes keys. The same mutation flag enables add `{url}`,
enable `{id,enabled}` and remove `{id}`. `pluginSources.catalog {id}` fetches an
immutable Git snapshot; `origin:"bundled"` selects the bundled catalog explicitly.
`pluginSources.review {id,plugin}` stages that commit for `plugins.approve`.
Disabled, removed or changed sources invalidate old reviews while already installed
packages remain usable. `pluginManager` state includes loading, source/catalog
identity, revision, review and stable controls; `plugins.ui.activate {id}` uses the
actual native manager.

`application.inspect` is bounded to the selected launcher's application family
and excludes passwords/text fields. `application.closeObservedWindow` requires
the mutation flag and closes only a window matching the reviewed declaration,
without terminating the app.

`audio.status` is read-only: it reports the configured output, current default,
connection availability, configured channel count and this process's output-device
activity. It omits device UIDs and does not start playback or change routing.
`playback.diagnostics` additionally exposes MPV's actual audio driver, format,
audio clock, selected track, mute and volume. These observations do not verify
physical speaker audibility.
