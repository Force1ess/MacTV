> Historical development snapshot. These build numbers describe past validation, not the current app version.

# v100 acceptance

[简体中文](ACCEPTANCE.zh-CN.md)

The project remains a **build-99 development preview**, targeting v100. Build,
software checks and physical television acceptance are separate. This is not a
stable release announcement. Structured evidence is in
[docs/history/v100.json](v100.json).

## Current playback latency

| Actual path | Trials / successes | Decoded dimensions | Observed P99 | Maximum | Current budget |
| --- | --- | --- | --- | --- | --- |
| Bilibili, stored session | 100 / 100 | 1920×1080 | 1.01 s | 1.24 s | 3 s |
| Quark original MKV | 100 / 100 | 3840×2160 | 2.30 s | 2.71 s | 7 s |
| Quark real MP4 folder card, pooled transport | 100 / 100 | 1920×1038 | 2.62 s | 2.73 s | 7 s |

All cohorts verified HDMI activity, a visible fullscreen playback window on the
active Space, actual decoded pixels and muted tests. No rebuffer was recorded
in the three-second observation after each frame. Each cohort is one content
item, one first-in-process trial and 99 repeats, not independent cold starts,
all-content coverage or hours of continuous playback.

**Quark's 7-second limit is a user-requested acceptance change, not a speedup.**
The MP4 baseline missed the original 3-second limit four times. Original rows,
summaries and failure results remain unchanged; a derived review evaluates the
same measurements against the new policy. The previous 4K limit was 6 seconds.
New Quark records carry `quark-p99-7s-v1`; unmarked legacy data retain their
original interpretation.

AVPlayer's display-ready notification is separate from the verified-frame clock,
which includes decoded image capture and window visibility. Earlier records
without dimensions or using notification-only timing are not current complete
frame acceptance. Normal Quark-path measurements use actual provider folder
cards so filename-dependent routing is preserved. Different routes, presentation
modes and observer definitions are not controlled comparisons.

## Current software evidence

- **Source and interfaces:** latest complete local run has 308 tests in 86 suites;
  two runtime-dependent converter cases retain separate Mini verification.
  Source, credential and failure-retention guards remain intact.
- **Modern playback:** 132 checks passed for owned codec fixtures, tracks,
  subtitles, seeking, speed, back layers, readable licenses and ordinary-test muting.
- **HDMI software output:** 11 checks passed for actual AVPlayer/MPV HDMI use,
  audio clock and format. MacTV selects the television; system defaults are unchanged.
- **Native runtime:** the macOS 27 AudioUnit failure in MPV 0.41 is fixed with
  upstream backport `3dae21b1ed4793912a8f9de1c5eb3cf32d227bce`. Matching source,
  patches, headers and build instructions accompany the retained dependencies.
- **Library:** 387 files, 30 root cards, no unavailable files or missing posters.
  Contextual episode matching was repaired without renaming or changing media.
- **Language/input:** native input passed 23 checks in each language; the earlier
  full English UI cohort passed 176. User/provider content and device names remain verbatim.
- **Chrome sign-in:** the unchanged standalone reader reused consent after two
  host rebuilds. MacTV sessions remain in protected files, not Keychain. Reader
  changes or revoked OS grants may require consent again.
- **Independent plugins:** Gallery/Steam UI are API 2 packages in MacTV-Plugins,
  with lifecycle and same-process update checks. Photo sources are host resources.

## Transport validation

The original MP4 loader creates a network session per playback and buffers whole
responses. Progressive delivery passed delayed-tail, version, truncation,
cancellation and exact-seek checks, but small live cohorts did not show stable
latency improvement and it was not adopted.

The pooled-connection candidate passed 19 owned checks including actual connection
reuse and cancellation isolation. Its 100-trial real MP4 observation had P99
2.62 seconds and maximum 2.73 seconds; continuous playback passed 300 seconds with an advancing clock and verified HDMI/fullscreen output. After a separate 300-second observation (no rebuffer/error), 19 post-activation owned checks and a three-trial real regression, pooled atomic delivery is the normal default. Progressive delivery remains opt-in. Small sequential cohorts
are not controlled network comparisons or causal performance evidence.

## Open requirements

| Area | Missing evidence |
| --- | --- |
| Physical television | Audible speakers and actual color/HDR output; decoding/activity are insufficient. |
| Remote/voice | Four physical arrow directions were observed. Return/menu/voice, physical microphone and a connected Codex call remain unverified; repetitive manual menu exercises are not required. |
| Steam game handoff | Cold/warm Big Picture, fullscreen and window-close return passed. The user confirms Steam is not logged in; window checks do not prove game handoff. |
| Dictation | Actual transcription is preserved. The owned phrase matched once and later mismatched its opening word; strict failures remain. |
| Hosted CI | Latest jobs could not start because of GitHub account payment/spending limits, with zero steps. Local success is not hosted success. |
| Distribution | Private candidate installer transferred and verified at both ends. Full public binary review, signing and notarization remain open. |

`--require-v100` still requires mandatory checks, real game/voice evidence,
`verified` status and build 100. It does not pass today. Netflix, Apple TV and
ddys are deferred by the user; the repositories remain private.

Development rollback copies have bounded retention and historical generated
bundles were archived. Source, account/signing material, original media and test
evidence remain intact. Private media, cookies, tokens, raw screenshots and
service logs are excluded from published source.
