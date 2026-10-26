# Physical devices without an app dependency

## Normal Xcode workflow

1. Quit Xcode once, then choose **Lookin → Xcode Integration… → Enable**.
2. Reopen Xcode and use **Run** on a physical iOS device or iOS Simulator as usual.
3. Choose **Lookin → Connect Last Xcode App**, or select the app normally. Its hierarchy is available through the
   GUI; Xcode remains attached for breakpoints and debugging.

There is no app chooser, build phase, package dependency or per-project setting.
Keep **Debug executable** and Xcode breakpoints enabled: integration uses an auto-continuing **user** symbolic
breakpoint named `LookinXcodeAutoConnect` at `UIApplicationMain`. The brief startup
stop signs/copies the server and continues automatically. Other user breakpoints,
including the older disabled `LookinIntegration`, are preserved and backed up.
Initial setup refuses to edit breakpoint settings while Xcode is running, avoiding its
in-memory settings overwriting the change. Disable can take effect immediately for
future runs even with Xcode open; a server already loaded lives until app exit.
Once enabled, opening Lookin updates the installed helper and both runtimes without
editing the global breakpoint or requiring Xcode to quit. Opening the integration
dialog also performs this refresh. Simulator payloads use immutable versioned paths.

The helper is copied to `~/Library/Application Support/LookinMCP/XcodeIntegration`
so moving the macOS app does not break the installed command. It resolves the local
build from Xcode's current target, uses that build's available signing identity,
and transfers the signed runtime through LLDB memory/file operations. It never
launches, stops, continues or detaches the current debug process. Xcode owns that
lifecycle. No second debugger or device-selection argument is needed. Diagnostics
are written to `last-session.json` in the integration directory. Only development
device builds with a locally available signing identity can load the signed server.
For Simulator targets, the helper loads the bundled arm64/x86_64 Simulator runtime
directly from the Mac. No signing key, upload, or `.app` selection is needed.
Simulator loading uses `SBProcess.LoadImage`, allowing LLDB to manage dyld image
notifications instead of invoking `dlopen` through a user expression. A valid image
token can be zero. Existing embedded/injected servers are reused.

This path uses the current Xcode debugger rather than the legacy `ios-deploy`
transport. Validation covers iPhone X / iOS 16.2 and `com.taxsee.Taxsee` on
iPhone 16 Pro / iOS 26.5.2. Simulator Xcode Run uses this same integration because
Xcode can replace `DYLD_INSERT_LIBRARIES` instead of inheriting the Simulator's
Auto-Connect loader. Other target platforms are ignored.

The Xcode loader checks `CFBundleIdentifier` through the bundle's information
dictionary: the direct `bundleIdentifier` selector can fail during LLDB expression
evaluation in a real app. Directory creation uses POSIX calls within the app's
container. File functions are resolved from loaded LLDB symbols with explicit
signatures, so the app need not expose their declarations to the expression parser.
Existing directories are checked; missing parents are created from the destination
upward without trying to list sandbox-protected ancestors such as `/var`.

## Standalone connection (advanced)

Choose **Lookin → Connect Physical Device…**, select a USB device and the already
installed app's signed `Debug-iphoneos/*.app` on this Mac. The app must have
`get-task-allow` enabled and its signing certificate/private key must be available
in the local keychain. Unlock the device, trust the Mac, and enable Developer Mode
where iOS requires it. Xcode and its device support must be installed.

**Launch app and connect** starts a stopped application. **Attach to running app**
requires the application to be open in the foreground. Stop its existing Xcode
LLDB session before connecting: two debuggers cannot own the same process. Lookin
does not terminate, install, re-sign or replace the inspected app. Reconnect after
quitting/relaunching it; the injected server only lives in that process.

The current helper supports the legacy USB debugger transport used by iOS 14–16.
Validation is on iPhone X / iOS 16.2. Newer versions are shown as unsupported;
iOS 17+ needs a CoreDevice debugger transport implementation. App Store/TestFlight
builds without debugging entitlement cannot use this workflow.

## Standalone implementation

`DeviceSupport/device_connect.py` validates the bundle signature and development
entitlements, extracts the signing certificate fingerprint and requires its local
private key. It signs a temporary copy of the bundled **iPhoneOS arm64** server,
then uses House Arrest to upload it under `Documents/.lookin-mcp/<session>/`.
The source `.app`, Xcode project, dependencies and user breakpoints stay unchanged.
Uploaded files are debug artifacts in the app's data container; the app's data is
not deleted. A new path avoids overwriting a binary already mapped by a process.

`device_lldb.py` coordinates stop events explicitly, checks the actual process
bundle ID, loads the library on the main thread, and detaches. It activates only
Lookin's connection manager when attaching after app launch. An existing server
loaded by this helper is reused. The server archives an opaque session token;
the client matches both token and bundle ID, preventing selection of an identically
named app on a different device. Legacy peers have no token and cannot claim it.

The bundled `ios-deploy` sources are pinned by `Vendor/ios-deploy/REVISION`.
The only local change is `--no-lldbinit` so this helper cannot execute unrelated
user debugger initialization. Its license and revision accompany the packaged
binary. Apple MobileDevice frameworks are linked from the Mac, never redistributed.

`Scripts/build_device_support.py` runs from the client build phase and builds the
helper and device server from local sources. It needs the existing workspace's
`build/ServerBuilder/Pods/Pods.xcodeproj` (prepared by the repository build setup).
The device payload lives in `Contents/Resources/DeviceSupport`; the existing
Simulator payload remains at its original path.

## Verification

Run `python3 -B Tests/device_connection_regressions.py` in the client checkout.
Run the server identity regression against the newly built LookinShared framework
for copy/archive and cross-device/session isolation. Physical-device checks must
use an isolated development app without an embedded framework or load command,
then test launch, fresh-process attach, reconnection and GUI/protocol image and attribute reads.

Run `python3 -B Tests/xcode_integration_regressions.py` for global-breakpoint
preservation, idempotent installation, disable behavior, and preservation of an
already attached debugger. A live Xcode Run/relaunch check is also required.
