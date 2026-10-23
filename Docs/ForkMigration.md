# Migration to the original repositories

The client is a direct GitHub fork of `hughkli/Lookin`, based on upstream
`95e30fdcc8151092678387c5262bce790a0d9530`. The server is a direct fork of
`QMUI/LookinServer`, based on `ae396132ce6494477457cf450116dc760518d8ad`.
The working branch in both repositories is `optimized`.

## Transferred behavior

- Full/Hybrid/Interactive loading, cancellation, stale response protection,
  priority scheduling, and negotiated compact requests.
- Bounded native PNG/preview cache and cached preview geometry.
- Hyperion snapshot-window exclusion, on-demand details, and complete exports.
- Simulator Auto-Connect and process-lifetime protection.
- Physical-device USB injection on iOS 14–16 and Xcode debugger integration,
  including the loader fixes verified on iOS 26.5.2.
- Production-code regression harnesses and historical benchmark records.

The client implementation was ported from local revision `48ee24d` (optimization
series `b97106b` through `a419e15`). Its old `LookinMCP` package, data provider,
HTTP lifecycle, MCP settings, Copy for AI action, and SwiftNIO/MCP dependencies
were excluded. The rejected background texture-preparation experiment was also
excluded. Client Git ancestry stays rooted directly in upstream, without the
third-party MCP fork's commits.

The server retains nine separate ported optimization commits. Its production
`Src` and `Package.swift` are byte-identical to local revision `66cc2c0`; fork
packaging/docs and portable test paths are additional changes. The wire version
remains 1.2.8 and the optional protocol features are capability-negotiated.

## Reproducible dependency

`Dependencies/LookinServer.json` pins the server fork by full commit SHA.
`Scripts/setup.py` obtains that checkout in `build/Dependencies/LookinServer`.
The client shared models, Simulator runtime and device runtime all use it.
No sibling checkout or previously prepared workspace is required.

The legacy `LookinMCP` cache/support directory names used by injection helpers
are retained for compatibility with installed Xcode user breakpoints. They do
not imply an MCP listener in this product. The new GUI has a separate bundle ID.

A fresh agent-facing MCP implementation is the next, separate stage. This
migration intentionally exposes no MCP endpoint. The already installed older
application is not replaced by building these repositories.

## Verification of this migration

Release macOS arm64 build and both runtime builds passed. All portable client/server
regression suites passed, including 16 Swift tests and production-code native
harnesses. The live Simulator suite passed on two disposable iOS 18.6 devices:
selection, relaunch, reinstall, second device, reboot, normal shutdown, reopen and
crash/lifetime gating, with hierarchy/image protocol reads. Both devices were
removed afterward. See `MigrationVerification.json` for counts and binary hashes.
This migration did not repeat the earlier physical-iPhone checks.
