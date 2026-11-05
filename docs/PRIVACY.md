# Privacy and permissions

[简体中文](PRIVACY.zh-CN.md)

MacTV requires no MacTV account. Accounts in the app belong to the individual
content platforms you choose to connect.

## Local data

`~/Library/Application Support/MTV` keeps source settings, indexes, metadata,
artwork, watch history and platform sessions. The legacy directory name preserves
upgrade compatibility.

New credentials use local files with mode 600 in directories with mode 700,
not the Apple Keychain. These files are not an encrypted vault and do not protect
against malicious processes running as the same user. A controlled migration
exists for older MacTV-owned Keychain records; the app does not scan arbitrary
records belonging to other applications.

## Media sources

Scanning and playback read the sources you choose without changing the original
media or NFO files. macOS may request access to folders, external drives or
network volumes. Source-folder access and Full Disk Access have different scopes;
ordinary playback needs only the selected source. Chrome import may require the
broader grant described in the setup guide.

## Chrome import

A platform import reads only that platform's cookies from the selected local
Chrome profile, after you choose Import. System prompts are disabled by default.
If access is missing, MacTV explains it first; Authorize and Import permits the
first system confirmation.

A separate versioned `MTVChromeBridge` component reads Chrome Safe Storage.
It has no MTVCore or UI dependency. Main-app updates do not inherently change
its code, and the installer reports whether the reader identity is preserved.
It accepts only a valid MacTV parent signed by the same certificate. The parent
also verifies the helper identifier, signature and certificate. Arbitrary apps,
plugins and browser extensions cannot directly invoke this reader mode.

The reader accesses one existing key, without changing its access list, creating
credentials or using the network. Its reply travels through an anonymous pipe
to the native parent, not through plugins, logs or files. MacTV does not cache
the Chrome decryption key. The helper exits after reading; closing login cancels
its read, and parent exit terminates it to avoid abandoned authorization windows.

Failed reads display a reason or offer QR/extension import. MacTV does not switch
to SSH, copy another computer's database or widen the platform scope to bypass
system restrictions. Imported sessions must pass platform verification before
being saved as MacTV's own local session.

## Network and diagnostics

Requests go to selected media sources, manifest-declared platform endpoints,
configured metadata services and artwork sources. TVmaze needs no token; TMDB
credentials are sent only to the TMDB service. Approved Quark media requests
keep credentials in the native broker, outside plugin code and diagnostic text.

The opt-in `--enable-control` interface is same-user local control, off by
default. It installs no persistent service and opens no network port. Protected
Control snapshots/events may include media titles and sources. Account import
needs a separate gate and defaults to noninteractive reads; control cannot grant
system permissions or export credentials.

Tests may retain media titles, source paths or screenshots locally. Do not push
those artifacts to public repositories. Share only summaries without account
data, cookies, tokens, credential-bearing media URLs or private screenshots.
