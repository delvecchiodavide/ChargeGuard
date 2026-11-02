# ChargeGuard

An open-source battery manager for macOS. Features: charge limiter, forced discharge, sailing mode, heat protection, top-up, calibration and live telemetry. Supports MacBooks with Apple Silicon or Intel, macOS 13+.

## Architecture

```
┌──────────────── ChargeGuard.app (user, no sandbox, Hardened Runtime) ──────────────────┐
│ MenuBarExtra (SwiftUI)                                                                 │
│   MenuBarView ── MenuBarIcon                                                           │
│        │ @Published                                                                    │
│   BatteryManager (@MainActor)                                                          │
│     ├─ BatteryTelemetry  ── IORegistry AppleSmartBattery + SMC (read-only)             │
│     ├─ ChargePolicy      ── pure function: snapshot + settings + latches → decision    │
│     ├─ IOPSNotificationCreateRunLoopSource (plug/unplug, percentage changes)           │
│     ├─ IORegisterForSystemPower (sleep/wake, deferred ack)                             │
│     └─ HelperClient ── SMAppService.daemon + NSXPCConnection(.privileged)              │
└──────────────────────────────────┬─────────────────────────────────────────────────────┘
          Bidirectional XPC, code signature verified in both directions
          (setCodeSigningRequirement / setConnectionCodeSigningRequirement)
┌──────────────────────────────────┴───── ChargeGuardHelper (root, launchd) ─────────────┐
│ HelperService: NSXPCListener(machServiceName:) + serial queue + watchdog               │
│ ChargeController: the only code that WRITES to the SMC, with read-back verification    │
│ SMCBridge (SMCKit) ── IOServiceOpen(AppleSMC) ── IOConnectCallStructMethod(sel. 2)     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

Design principles:

- **The app decides, the helper executes.** All logic (limit, sailing, heat, top-up, calibration) lives in `ChargePolicy`, a pure, unit-tested function. The root helper only exposes minimal primitives: `setChargingEnabled`, `setAdapterEnabled`, `setHardwareChargeLimit` and `restoreDefaults`. A small privileged surface is easier to secure.
- **Reads don't need root.** The app reads the SMC and IORegistry itself. Only writes go through the helper.
- **Fail-safe.** The helper restores normal charging in three cases:
  - the app sends no heartbeat for 5 minutes (measured on the uptime clock, which stops during sleep);
  - it receives SIGTERM (uninstall or shutdown);
  - the battery drops to 5 % with the adapter disabled.

  Quitting the app also restores normal charging.
- **Capability detection, no per-model tables.** At startup the helper probes which SMC keys exist (`ChargeCapabilities.detect`). It verifies every write by reading the key back, and if the firmware ignores a write, the error surfaces in the UI.

## Layout

```
ChargeGuard/
├─ Package.swift                 command-line build + local package for Xcode
├─ project.yml                   Xcode project (XcodeGen)
├─ Sources/
│  ├─ CSMC/include/CSMC.h        exact C layout of SMCParamStruct (80 bytes)
│  ├─ SMCKit/
│  │  ├─ SMCBridge.swift         AppleSMC connection: read/write/keyInfo/enumeration
│  │  └─ SMCKeys.swift           keys, control strategies, capability detection
│  ├─ ChargeCore/
│  │  ├─ Models.swift            snapshot, settings, states, latches
│  │  ├─ ChargePolicy.swift      state machine (pure)
│  │  ├─ BatteryTelemetry.swift  IORegistry + SMC → BatterySnapshot
│  │  └─ HelperProtocol.swift    XPC protocols, constants, signing requirements
│  ├─ ChargeGuardHelper/         root daemon: main, HelperService, ChargeController
│  ├─ ChargeGuardApp/            app: entry point, BatteryManager, HelperClient, UI/
│  └─ cgctl/                     SMC diagnostics CLI
├─ Resources/
│  ├─ App/        Info.plist (LSUIElement), entitlements, Assets.xcassets (app icon)
│  └─ Helper/     Info.plist (embedded in the binary), launchd plist, entitlements
├─ Scripts/
│  ├─ render-icon.swift          draws the app icon at every macOS size
│  └─ make-dmg.sh                Release build + signed drag-to-install DMG
└─ Tests/ChargeCoreTests/        policy tests (swift test)
```

## Install

Download the DMG from the [latest release](https://github.com/delvecchiodavide/ChargeGuard/releases/latest), open it and drag **ChargeGuard** into **Applications**. Launch it, press **Install Helper** in the menu bar popover, and enable ChargeGuard in **System Settings › General › Login Items & Extensions**.

The release builds are signed with an Apple Development certificate and are not notarized. On first launch macOS reports that it can't verify the developer: right-click the app › **Open**, or go to System Settings › Privacy & Security › **Open Anyway**.

To build the DMG yourself: `Scripts/make-dmg.sh` (output in `dist/`). With a Developer ID certificate, `NOTARY_PROFILE=<keychain profile> Scripts/make-dmg.sh` also notarizes and staples it.

## Xcode setup

1. Install XcodeGen and generate the project:
   ```sh
   brew install xcodegen
   cd ChargeGuard && xcodegen generate && open ChargeGuard.xcodeproj
   ```
2. In `project.yml`, set `DEVELOPMENT_TEAM` to your Team ID and regenerate the project. To change the `com.example.chargeguard` prefix, edit it in five places: `HelperConstants`, both `Info.plist` files, the launchd plist and `project.yml`. **All five must match.**
3. Signing (*Signing & Capabilities*):
   - Sign the app and the helper with **the same team**. Each process reads its own Team ID from its signature (`CodeSigning.currentTeamID`) and requires the peer to carry the same one, so the code hard-codes no Team ID.
   - Enable **Hardened Runtime** on both targets.
   - Turn **App Sandbox** off (`com.apple.security.app-sandbox = false`). The sandbox blocks `IOServiceOpen` on AppleSMC and privileged Mach service lookups. As a result the app ships with Developer ID and notarization, not through the Mac App Store.
4. Bundle packaging (already configured in `project.yml`):
   - `ChargeGuardHelper` → `ChargeGuard.app/Contents/MacOS/ChargeGuardHelper` (Copy Files, destination *Executables*, Code Sign On Copy).
   - `com.example.chargeguard.helper.plist` → `ChargeGuard.app/Contents/Library/LaunchDaemons/` (Copy Files, destination *Wrapper*, subpath `Contents/Library/LaunchDaemons`).
   - The helper has `CREATE_INFOPLIST_SECTION_IN_BINARY = YES`, so `codesign` gives it the `com.example.chargeguard.helper` identifier that the app verifies.
5. First launch: the app calls `SMAppService.daemon(plistName:).register()`.
   - The first call throws *"Operation not permitted"* and the status becomes `.requiresApproval`. This is expected: the daemon is registered but not yet allowed.
   - The *"Background item added"* notification doesn't always appear. The app therefore opens **System Settings › General › Login Items & Extensions** directly, where the user enables ChargeGuard under *Allow in the Background*.
   - The app re-checks the helper every minute, so it connects without a relaunch. From then on, launchd runs the helper as root.
   - The registration is tied to the app's path: if you move the app, install the helper again from the new location.
   - On MDM-managed Macs, an organization policy can hide or lock the toggle.
6. Before distributing: Archive → Developer ID → notarization (`xcrun notarytool submit --wait`) → `xcrun stapler staple`.

### Why there is no SMJobBless fallback

The deployment target is macOS 13, where `SMAppService` is always available, so an `SMJobBless` branch would never run. It would also need different packaging: `Contents/Library/LaunchServices`, the `SMPrivilegedExecutables`/`SMAuthorizedClients` keys, and a launchd plist embedded in the `__launchd_plist` section. On top of that, it has been deprecated since macOS 13. You only need it if you lower the target to macOS 12 or earlier.

### Debugging the helper

```sh
# launchd registration state
sudo launchctl print system/com.example.chargeguard.helper
# live logs from app and helper (use /usr/bin/log: in zsh, `log` is a builtin)
/usr/bin/log stream --level debug --predicate 'subsystem BEGINSWITH "com.example.chargeguard"'
# full registration reset (if the state is inconsistent)
sfltool resetbtm      # requires a reboot
```

With `swift build`, binaries are ad-hoc signed and carry no Team ID. In that case the helper accepts any client in DEBUG builds only, and refuses to start in RELEASE builds.

## SMC keys and compatibility

Low-level access lives in `SMCBridge`:
1. `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))`
2. `IOServiceOpen` with type 0
3. `IOConnectCallStructMethod` on selector 2 (`kSMCHandleYPCEvent`), passing an 80-byte `SMCParamStruct`

The sub-command goes in `data8`: `9` key info, `5` read, `6` write, `8` key by index. The struct is declared in C because Swift does not guarantee the padding of `keyInfo`, which must take 12 bytes. `kSMCUserClientOpen` (selector 0) is a historical leftover and is not needed on modern macOS.

| Function | Intel (T2) | Apple Silicon, firmware ≤ macOS 15 | Apple Silicon, macOS 26 | Apple Silicon, macOS 27 (verified) |
|---|---|---|---|---|
| Charge inhibit | `CH0B`+`CH0C` = `02` / `00` | `CH0B`+`CH0C` = `02` / `00` | `CHTE` (ui32) = `01000000` / `00000000` | `CHLS`/`CH0J`, reserved to powerd → native macOS limit |
| Adapter disable | `CH0I` = `01` / `00` | `CH0I` = `01` / `00` | `CHIE` = `08` / `00` | `CHIE` (hex_, 1 byte) present |
| Firmware limit | `BCLM` (ui8 20–100) + `BFCL` | — (`CHWA` on macOS 12 only) | — | — |
| Temperature | `TB0T`…`TB2T` (`sp78`, BE) | `TB0T`…`TB2T` (`flt `, LE) | same | same; also `B0AT` (ui16, hundredths of °C) |
| Power | — | `PPBR` battery, `PDTR` adapter, `PSTR` system (`flt `) | same | same |

Notes:

- On **Apple Silicon**, integers and `flt ` are **little-endian**. On Intel, integers and `sp78`/`fpe2` are **big-endian**. `SMCValue` handles both.
- **Apple Silicon on macOS 27 (verified):** the `CH0B`, `CH0C` and `CHTE` keys no longer exist. Their replacements, `CHLS` and `CH0J`, return `kIOReturnNotPrivileged` **even as root**. They are gated by the private entitlement `com.apple.private.applesmc.user-access`, which `powerd` holds (`codesign -d --entitlements - /System/Library/CoreServices/powerd.bundle/powerd`). AMFI rejects that entitlement on any binary not signed by Apple. The strings `ChargeLimit`, `socLimit` and `DeviceSupports80ChargeLimit` in `powerd`/`PowerUIAgent` indicate that macOS manages the charge limit itself.
  In this case ChargeGuard switches to **native-limit mode** (`ChargeCapabilities.usesNativeChargeLimit`):
  - you set the limit in System Settings › Battery › Charging; the "Battery Settings…" button opens that page;
  - the slider becomes the forced-discharge target (`CHIE` stays writable);
  - sailing, top-up and heat protection are disabled, because they require inhibiting the charge;
  - the displayed state reflects what the hardware is actually doing.

  The code never writes guessed values to undocumented keys. If future firmware reopens access, add a new `case` to `ChargingStrategy` and one line to `ChargeCapabilities.detect`.
- On Intel Macs without `CH0B`, the limiter falls back to `BCLM`. It is less flexible (no sailing), but the firmware enforces it even while the Mac sleeps.
- Apple Silicon has no firmware limit. The inhibit written to the SMC persists during sleep, but the app can't react when the battery reaches the limit. That is why the "Stop charging when sleeping" option inhibits charging in the `kIOMessageSystemWillSleep` callback before acknowledging sleep.
- Turn off **Optimized Battery Charging** in System Settings › Battery: it interferes with the limiter.

### Checking from the terminal

```sh
swift build
BIN=$(swift build --show-bin-path)
$BIN/cgctl probe                       # detected strategy + every candidate key
$BIN/cgctl telemetry                   # decoded battery snapshot
$BIN/cgctl keys CH                     # every charging key on this firmware
$BIN/cgctl read TB0T B0AV B0AC PPBR    # raw telemetry
sudo $BIN/cgctl keys CH                # includes protected keys (CH0J, CHLS…)
sudo $BIN/cgctl write CH0C 02          # manual write test (with read-back)
sudo $BIN/cgctl write CH0C 00          # restore
ioreg -rn AppleSmartBattery | less     # IORegistry source of the telemetry
```

Reading errors:

| Error | Meaning |
|---|---|
| `kIOReturnNotPrivileged` (`0xe00002c1`) | write without root; if it also appears with `sudo`, the key is gated by a private Apple entitlement |
| firmware `0x84` | the key doesn't exist on this model or firmware |
| firmware `0x85` / `0x86` | the key is not readable / not writable |
| `verificationFailed` | the firmware accepted the call but ignored the value: wrong key for this generation |

## Telemetry

`BatteryTelemetry` reads `AppleSmartBattery` and falls back between two registry layouts. On macOS 27, `Temperature`, `AppleRawCurrentCapacity` and `AppleRawMaxCapacity` are gone from the top level. The capacities now live in the `BatteryData` dictionary (`RemainingCapacity`, `FullChargeCapacity`, `NominalChargeCapacity`, `DesignCapacity`), and the temperature comes from the SMC.

- **Hardware %** = `RemainingCapacity / FullChargeCapacity`. **macOS %** is `CurrentCapacity`.
- **Power** = `Voltage × InstantAmperage`. Read `Amperage` as a signed Int64: `ioreg` prints it unsigned, so `18446744073709550206` = −1410 mA.
- **Health** = `NominalChargeCapacity / DesignCapacity`.

## State machine

`ChargePolicy.evaluate` applies these rules in order, highest priority first:

1. **5 % safety floor**: the adapter is always on.
2. **Calibration**: charge to 100 % → hold for N minutes → forced discharge to 10 % → recharge to 100 % → back to the limit.
3. **Forced discharge**: adapter off until the limit, then the Mac holds at the limit on adapter power.
4. **Heat protection**: charging pauses above `heatLimitC` and resumes below `heatLimitC − 3 °C`.
5. **Top-up**: one-shot charge to 100 %, then automatically back to the limit.
6. **Limiter + sailing**: stop at the limit; resume at `limit − 1` or at the sailing lower bound.

The latches (`PolicyState`) are persisted, so a calibration survives an app relaunch.

## Known limitations

- Apple doesn't document the SMC keys, and they change between firmware versions: see the table above and the macOS 27 column.
- During sleep on Apple Silicon, the only way to enforce the limit is to inhibit charging before the Mac falls asleep. As a result, a Mac that sleeps below the limit does not charge.
- There are no system notifications: the helper's safety overrides appear as a message in the popover.

## License

MIT — see [LICENSE](LICENSE).

ChargeGuard writes to undocumented SMC keys. Use it at your own risk: the software is provided without warranty of any kind.
