# Pluggable MacTV experiences

[简体中文](PLUGGABLE-ARCHITECTURE.zh-CN.md)

**First examples: Gallery and Steam UI. Photo sources are resources, not plugins.**
API 2 now supports asynchronous handlers and multiplexed native calls; API 1 remains supported. The separately packable SDK lives in MacTV-Plugins/sdk. The current lifecycle is request-scoped, not persistent background workers.

## Boundaries

| Part | Responsibility |
| --- | --- |
| Independent plugin core | Feature behavior, data selection, navigation/actions, source presentation and feature tests; no MacTV globals or application imports |
| Thin MacTV adapter | Bind the core to declared host interfaces and contribute its experience |
| Host shell | SwiftUI components, focus/back stack, on-screen input, generic player/viewer and package management |
| Host resource services | Granted photo connections, scoped reads, decoding, credentials, OS application handoff |

A local directory, SMB share or cloud-drive account is a resource connection.
It does not acquire its own plugin package, app card, worker or install lifecycle.
Gallery consumes photo resources. Steam UI is an experience which hands off to
the installed Steam client's Big Picture mode; it does not reimplement Steam.
Bilibili and Quark remain existing applications/adapters, not the first pair of
independent example packages. Music remains a legacy preview in this slice.

A plugin may have its own source tree. Adding/changing its behavior must not
require edits in MacTV's application source. Low-level resource/OS services stay
native; plugin-specific workflow must not migrate back into the shell.

## Independent package layout

```text
MacTV-Plugins/gallery/                 MacTV-Plugins/steam/
  package.json                    package.json
  package-lock.json               package-lock.json
  src/core.ts                     src/core.ts
  src/mactv.ts                    src/mactv.ts
  test/                           test/
  tools/pack.mjs                  tools/pack.mjs
  manifest.json                   manifest.json
  plugin.js                       plugin.js
  README.md, LICENSE              README.md, LICENSE
```

Each directory can be copied to another repository and run with `npm ci` and
`npm test`. No MacTV checkout, Xcode, running app or account is needed. TypeScript
and esbuild are pinned in each package lock. `build/core.mjs` is a portable
library; `plugin.js` is the host bundle; `dist/` is the installable package folder.
The standalone tests inject a photo-resource port or a reviewed application-open
port. They do not emulate the whole MacTV application.

The Gallery adapter awaits `host.library('photos', ...)`. Its core never
recognizes a Quark prefix or account. The native photo port adapts existing
local/cloud connections and returns metadata and opaque references. Source
connections are configuration, not plugin dependencies. Introducing a new
network protocol may need a resource adapter, but configuring another directory
or supported account never requires another plugin.

Steam's installable launch declaration is generated from the same independently
tested core action. MacTV executes the reviewed declaration via its generic
application service; scripts cannot supply arbitrary executable commands.

## Installation and lifecycle

App-shipped example packages live in `Resources/ExamplePlugins`, outside the
permanently bundled catalog. On first use they are copied into the normal
managed package store. Every later activation resolves that installed version.
They appear in the same manager as externally installed packages.

The registry remembers which defaults were already seeded. Disable/removal is
durable across reload and restart. A new app bundle cannot resurrect a deleted
example, re-enable it, or replace an explicitly installed version. Users can
reinstall/update it through ordinary reviewed package installation.

| Action | Behavior in the first slice |
| --- | --- |
| Install/update | Review the immutable package, then install into a new private version directory and refresh contributions live |
| Disable | Cancel plugin work, release its viewer/player state and application-return observation, remove its entry |
| Enable | Refresh the installed catalog and show its entry without an app restart |
| Remove | Cancel and unregister code; preserve original media and unrelated account connections |
| Restart | Restore installed enabled states and removal decisions; never run example code directly from the app bundle |

Updates currently quiesce owned activity before switching. Seamless continuation
of an old active playback instance until a later handoff remains a future v2
feature. The single-bundle format does not support arbitrary asset trees. The independent SDK is distributed as a packable repository artifact; no npm namespace has been published.

JavaScript installation does not re-sign MacTV or its stable Chrome helper.
Credential material remains native and account-bound, not in plugin packages,
logs or the Keychain for MacTV-owned sessions. Existing explicit system grants
are preserved. Installation never runs npm or compiles Swift on the user's Mac.

## Test and control interfaces

`npm --prefix tools run test:plugins` copies each example directory into a temporary isolated
fixture, installs only that package's declared build dependencies, type-checks,
builds and tests it, then compares generated host bundles with checked-in ones.
The fixture contains no application source. `npm --prefix tools run build:plugins` prepares
local `dist/` packages; app packaging copies these artifacts without node_modules.

Managed-store tests cover startup seeding, actual installed code locations,
disable/enable, updates, deletion, restart and no resurrection by a newer bundle.
App-level verification must also exercise those operations against a running
process and confirm new code is actually executed after a hot update.

`plugins.list` observes the managed registry. Explicit developer launch flag
`--allow-plugin-management` additionally enables `plugins.review`,
`plugins.approve`, `plugins.enable` and `plugins.remove`. Review returns the exact
manifest and an opaque token; approval uses that reviewed staged copy. These
commands call the same store, quiescence and catalog reload used by the UI.
Ordinary launches keep mutation commands disabled.

## Async SDK 2

The independent SDK supplies TypeScript contracts and optional `definePlugin` helper. API-2 handlers return values or Promises; native library/network methods return Promises. Each request has its own ID, up to four native operations run concurrently, and replies may arrive out of order. An invocation is limited to 64 requests, a 25-second outer deadline and bounded payloads. Scripts must await native work before returning. Navigation/disable/update cancels the invocation and its pending network/resource work. Native blocking reads are kept off Swift's task pool; cancelled reads cannot deliver results into a new view.

Real worker-process tests exercise `Promise.all`, reply reordering, rejection recovery, malformed IDs and cancellation. A held native operation verifies cancellation returns before the underlying read completes. This is a request-scoped SDK: no persistent background workers, arbitrary SwiftUI injection or shell/Git port is exposed to scripts.

Launcher packages may declare `matched-window-closes`, exact `windowTitles`, and a fullscreen presentation preference. A launcher can declare `readyWhen: visible-window` so its fixed action is sent only after application startup produces a usable window; this avoids losing a cold-start URI in an updater/bootstrap process. The native observer uses public Accessibility/window metadata, ignores password/text-field values, and keeps unrelated apps/games in the foreground. Those application-specific selectors belong to the package, not a host Steam-ID branch.

## Git plugin sources

Settings → Plugins → Plugin Sources manages Git repositories. The default is
MacTV-Plugins; other HTTPS, SSH (including SSH-config aliases) and explicitly
selected local `file://` repositories can be added, enabled, disabled or removed.
Branches/tags can be changed. Removing a source preserves installed plugins.

MacTV delegates clone/fetch to installed Git and normal SSH/credential-helper
configuration. It does not copy private keys, create a parallel GitHub login or
store separate access tokens. Git runs without terminal prompts; host-key,
agent/key, branch and repository failures are reported. Missing Git produces an
installation hint rather than opening Apple's Command Line Tools installer.
The current official repository is private; its authentication is not part of the
local fixture acceptance and its visibility is not changed automatically.

The cache is a shallow bare repository. No checkout, submodule recursion, hooks,
smudge filters or npm builds are performed. Catalog schema 2 declares a relative
package `directory` alongside ID/version/API metadata. Catalog and package files
are read from the same commit. Known regular files are size-bounded; links,
submodules, traversal and mismatched manifests are rejected. Installation then
uses the existing immutable review/approval pipeline. Installed provenance
records the source, ref and commit. Source changes invalidate pending reviews.

The UI can explicitly browse the catalog shipped in the app without fetching.
It labels that catalog as bundled and does not imply online freshness. This is a
separate user-selected action, never an automatic fallback after a Git failure.
Normal source activation and updates still require permission review; a source
catalog is not authorization to execute its packages.
