# Lookin — optimized fork

A direct fork of [hughkli/Lookin](https://github.com/hughkli/Lookin), based on
upstream `95e30fd`. The paired runtime is
[JustUser331/LookinServer](https://github.com/JustUser331/LookinServer).

This branch preserves our Full/Hybrid/Interactive resource scheduler, compact
protocol support, native PNG reuse, bounded preview cache, geometry caching,
Hyperion snapshot-window exclusion, Simulator Auto-Connect, and Xcode/USB device
integration. The old third-party MCP implementation, HTTP server, SwiftNIO,
MCP-specific UI and packages are not included. A new agent-facing MCP will be
implemented separately on this base.

## Build

Requirements: macOS 13+, Xcode with Swift 6.1 or newer, Python 3, Git and CocoaPods.
From this checkout:

```sh
python3 Scripts/setup.py
python3 Scripts/build.py --skip-setup
```

Setup obtains the exact server commit in `Dependencies/LookinServer.json` from our
server fork. Both `LookinShared` and the bundled device/Simulator frameworks use
that checkout. The build creates `build/ClientDerivedData/Build/Products/Release/Lookin.app`;
it does not install or replace an application. For an arm64-only macOS build,
pass `--architectures arm64`. The bundled Simulator runtime retains both architectures.

After setup, `Lookin.xcworkspace` can also be built directly in Xcode. The product
has its own bundle identifier (`io.github.JustUser331.Lookin`) and no upstream
automatic update feed. Distribution signing/notarization is a separate release step.

## Use and verify

See [Simulator Auto-Connect](Docs/SimulatorAutoConnect.md) and
[physical devices](Docs/PhysicalDevices.md). Development-signed apps and the
existing device/debugger requirements still apply. These features do not require
adding a dependency to the inspected application's source project.

Run `python3 Scripts/test.py` after a Release build. It exercises the transferred
production scheduling, transport, geometry, image cache and integration code,
plus the pinned server's codecs and capture guards. The server remains compatible
with the upstream protocol through capability negotiation.

See [migration details](Docs/ForkMigration.md) for provenance and scope. Original
copyright and GPL-3.0 licensing are preserved in `LICENSE` and source headers.
