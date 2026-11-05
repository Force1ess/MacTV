# Developing content plugins

[简体中文](PLUGIN-DEVELOPMENT.zh-CN.md)

Plugins provide content and playback descriptions. MacTV supplies the native
interface, focus and playback. A plugin does not need a SwiftUI page or a change
to the app's Swift source. Gallery and Steam UI are independent API 2
examples in [MacTV-Plugins](https://github.com/Force1ess/MacTV-Plugins/tree/main).
Clone that repository and develop Gallery or Steam UI independently.
The API 2 SDK can also build, test and pack without Xcode or the main repository.

Photo sources are host resources, not plugins. Use `host.library('photos', input)`
for the declared photo port. See [the architecture](PLUGGABLE-ARCHITECTURE.md)
and [native contracts](OPTIONAL-MODULES.md) before adding another resource.

## Start in the plugin repository

```sh
git clone git@github.com:Force1ess/MacTV-Plugins.git
cd MacTV-Plugins/gallery
npm ci
npm test
npm run build
```

Create your plugin in its own repository, using an API 2 example and SDK. Add
its Git source in MacTV to install it. No main-app checkout or Swift build is
required. For local host builds, `MACTV_PLUGINS_DIR` can select your plugin
repository checkout instead of the automatically fetched official `main`.

The [src/plugin-api/mtv.d.ts](../src/plugin-api/mtv.d.ts) declarations and
[src/plugin-api/example.ts](../src/plugin-api/example.ts) describe legacy API 1. Built-in Bilibili,
Quark and Music adapters live in `src/integrations`; they are not independently
installable plugin packages. The host-test demo lives in test fixtures and is
never shipped with the app.

```js
/** @type {MTVPlugin} */
const plugin = {
  handle(action, input) {
    if (action !== 'browse') throw Error('Unsupported action');
    return {items: []};
  }
};
```

API 1 handlers are synchronous. `browse` returns `items` and optional `next`.
That cursor is platform data, not an execution argument. Give video items stable
references and resolve a fresh playback address when requested. Expiring URLs
must not become watch-history identities.

## Manifest and capabilities

| Field | Meaning |
| --- | --- |
| id / version / apiVersion | Unique identity, package version and API version (1 or 2). |
| entry | Fixed `plugin.js` entry. |
| domains | Allowed HTTPS request domains. |
| capabilities | Declared actions, including browse, search, resolve, login, folders, history, lookup, watchlist and continuation; native examples also declare library or launch. |
| playbackDomains / artworkDomains | Allowed video and artwork domains. |
| authentication | QR/session endpoints, cookie names and success-state declaration. |
| postEndpoints | Exact allowed POST host/path pairs. |
| requestUserAgent | Optional fixed header, at most 512 bytes and no control characters; reviewed with the manifest, not injected by scripts per request. |
| presentation | Symbol, tint, summary, homepage visibility and developer settings. |
| nativeLibraries / applicationLaunch | Native resource or fixed application-launch declarations, displayed during installation review. |
| localizedNames | Application names by language. |

`mtv.` belongs to built-in modules; `local` is reserved for the media library.
External plugins need their own unique namespace. Validate unknown response
status and structure before producing native data. Never place credentials in
references, URLs, artwork or errors.

## Network, login and playback

Use `host.fetchJSON`. Non-200 replies expose HTTP status and optional numeric
provider error codes, not arbitrary error bodies, login links or credentials.
A fixed User-Agent supports protocol compatibility without changing account
entitlements or domain restrictions.

QR polling, ticket exchange and cookies stay in native code.
`host.sessionAvailable` reports whether a session exists; allowed endpoints can
explicitly request authenticated access. JavaScript never receives the cookie
string. Playback headers accept validated User-Agent and fixed Referer only,
not Cookie, Authorization or Host. The native player/session broker handles
approved media families. Independent audio may use `audioURL`; `indexed-fmp4`
is restricted to compatible clear, indexed AVC/AAC tracks.

## API 2 and lifecycle

Declare `apiVersion: 2`. `host.library` and `host.fetchJSON` return Promises;
handlers can return a Promise or an ordinary result. At most four native calls
run concurrently, with a budget of 64 calls per invocation. Await all native
work before returning. Closing or disabling an experience cancels the entire
invocation. API 1 remains compatible but does not provide a second permission
path around API 2.

Launchers can declare `matched-window-closes`, `windowTitles` and
`preferredPresentation`. Window rules belong to the plugin; the host provides
the generic observer.

## Install and test

App management supports local-folder installation and Git-backed sources,
capability review, updates, disable and removal. Source settings use system Git
clone/fetch and immutable commits; they do not copy SSH keys or store an extra
GitHub token. The default official source is MacTV-Plugins.

Use owned response fixtures for parsing, pagination, permissions and playback
descriptions. Real login, subscription quality and provider refusal require
separate live checks. Offline success is not platform acceptance. Do not install
untrusted code merely because it has a compatible manifest.
