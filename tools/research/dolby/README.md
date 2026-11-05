# Dolby compatibility probe

This separate Swift package evaluates the GPL-3 KSPlayer 2.3.4 renderer on a
user-selected local file before considering any production integration. It does
not add a dependency to MacTV's main package. SwiftPM records exact transitive
versions in Package.resolved. Upstream source/license:
https://github.com/kingslay/KSPlayer/tree/2.3.4

Build: `swift build -c release --package-path tools/research/dolby`

Run the resulting executable with `<local-media-path> <result-directory>`.
It plays muted for at most 20 seconds and writes observations and frame captures.
Seeing a frame is insufficient to establish correct Dolby color or TV output:
compare the source's Dolby configuration and actual rendered colors separately.
