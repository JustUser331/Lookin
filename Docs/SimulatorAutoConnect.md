# Simulator auto-connect

Open **Lookin → Simulator Auto-Connect…**, or use the same link on the launch
screen. Check an installed application, or enter its bundle ID. Booted iOS
Simulators contribute installed user apps to this list. Remembered applications
remain listed while uninstalled or while their devices are shut down.

The choice applies to that bundle ID on every iOS Simulator. Open Lookin before
launching the application. Restart an application once if it was already running
when enabled. Reinstallation, new container paths, new processes and renamed
simulators do not require choosing the application again. The desktop checks
booted devices every two seconds; its status shows when devices are prepared.
When exactly one inspectable app is available and remembered, the launch window
opens its hierarchy automatically. Multiple available apps remain selectable.

Uncheck an app to stop future loads. Quitting Lookin disables the configuration
and removes this instance's loader from booted devices. A framework already loaded
into an application remains until that application's process exits.

## Implementation

`LKSimulatorAutoConnect` stores only bundle IDs and display names in the
`SimulatorAutoConnectApps` defaults dictionary. It manages the launch environment
of booted iOS devices through `xcrun simctl`, using argument arrays without a
shell. Existing `DYLD_INSERT_LIBRARIES` entries are preserved. Only the exact path
owned by this desktop installation is removed during cleanup. Startup also
reconciles stale entries from a previous session. No LaunchAgent or background
helper is installed.

The build compiles `LookinSimulatorLoader.c` for arm64 and x86_64 Simulator.
Its only linked dependency is libSystem; CoreFoundation is resolved dynamically
after the user-app and desktop-lifetime checks. Device preparation waits for
`simctl bootstatus` before altering a newly booted device's environment.
The desktop copies this small library into its Application Support directory,
next to an atomic configuration file and a lifetime lock. The loader considers
only the main executable of a user `.app` in a Simulator application container,
reads the current bundle's Info.plist, and loads the packaged LookinServer only
for selected IDs. It skips extensions, system processes and apps that already
contain Lookin. It does not depend on a remembered installation path.

An exclusive `flock` belongs to the desktop process. Its descriptor is closed on
exec, so temporary simctl children cannot keep the feature alive. The loader
requires the lock to be held, and an enabled configuration. Kernel release of the
lock on desktop termination also handles crashes or forced quits. A stale
environment entry can therefore load only the small inert bootstrap after a
crash. The bootstrap file is intentionally retained so that such an entry never
points to a deleted library. The next desktop launch reconciles the environment.

The server reports its Simulator UDID in the existing versioned app-info archive.
Desktop reconnection uses bundle ID + UDID when available, avoiding confusion
between identically named apps/devices. Older peers remain supported through
their existing fields; ambiguous old/new identities are not silently equated.

This mode prepares future application launches; it does not attach LLDB or
restart running applications. App launching can race the first device-preparation
pass after boot: wait for the ready status, or restart the app once. Physical iOS
devices and non-iOS Simulator runtimes are outside this feature.

## Verification

Run `python3 Tests/simulator_autoconnect_regressions.py` from the client checkout.
It compiles the production manager against a deterministic simulator runner and
executes the production loader in isolated native fixtures. It covers environment
ownership, newly booted devices, competing desktop instances, persisted selection,
bundle filtering, reinstalled paths, system/extension exclusion and lifetime gating.

The server checkout's `Tests/simulator_app_identity_regressions.py` tests archive
roundtripping and stable identity against the built Shared framework. Supply
`--framework-dir` when using a separate DerivedData directory.

`Tests/simulator_autoconnect_live.py` creates two disposable iOS 18.6 devices and
runs the production manager with discovery restricted to those devices. It tests
real launch/relaunch, uninstall/reinstall, a second Simulator, device reboot,
normal desktop shutdown, desktop restart and forced process termination. It also
fetches hierarchy, attributes and images through the production Lookin protocol.
The fixture is an independent UIKit app which writes its loaded-class/PID state;
it has no Lookin dependency. All created devices are deleted in a finally block.
Build it with `python3 Tests/build_simulator_autoconnect_fixture.py --output /tmp/LookinResearch.app`
and supply that path to the live suite's `--fixture` argument. The suite also takes
`--client` (packaged desktop .app), `--server` (Simulator framework executable),
and `--output` (evidence directory).
