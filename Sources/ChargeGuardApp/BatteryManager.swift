import ChargeCore
import Combine
import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import SMCKit

/// Drives the whole app: reads telemetry, runs `ChargePolicy`, and pushes the
/// resulting decision to the privileged helper whenever it changes.
@MainActor
final class BatteryManager: ObservableObject {
    @Published private(set) var snapshot = BatterySnapshot()
    @Published var settings: ChargeSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.normalize()
            persist()
            evaluate()
        }
    }
    @Published private(set) var policy: PolicyState
    @Published private(set) var state: ChargeState = .onBattery
    @Published private(set) var helperStatus: HelperStatus = .connecting
    @Published private(set) var canLimitCharge = false
    @Published private(set) var canForceDischarge = false
    /// macOS 27+ Apple Silicon: charging is limited by macOS itself (System Settings › Battery).
    @Published private(set) var usesNativeChargeLimit = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?

    private let helper = HelperClient()
    private let telemetry = BatteryTelemetry(smc: try? SMCBridge())
    private var capabilities: ChargeCapabilities?
    /// Last decision successfully applied; nil forces a re-apply (e.g. after reconnect or wake).
    private var applied: (charging: Bool?, adapter: Bool?, limit: Int?) = (nil, nil, nil)
    private var applyTask: Task<Void, Never>?
    /// One re-registration per launch when the helper can't be reached.
    private var didReregisterHelper = false

    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    private var powerSourceLoop: CFRunLoopSource?
    private var sleepPort: IONotificationPortRef?
    private var sleepNotifier: io_object_t = 0
    fileprivate var rootPowerDomain: io_connect_t = 0

    private static let settingsKey = "ChargeSettings"
    private static let policyKey = "PolicyState"
    private static let pollInterval: TimeInterval = 10
    private static let launchAtLoginOfferedKey = "LaunchAtLoginOffered"

    init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ChargeSettings.self, from: $0) } ?? ChargeSettings()
        // Calibration and top-up survive an app relaunch.
        policy = defaults.data(forKey: Self.policyKey)
            .flatMap { try? JSONDecoder().decode(PolicyState.self, from: $0) } ?? PolicyState()

        helper.onSafetyOverride = { [weak self] reason in
            self?.lastError = reason
            self?.applied = (nil, nil, nil)
            self?.evaluate()
        }
    }

    // MARK: Lifecycle

    func start() {
        // A limiter that isn't running protects nothing: start at login by default,
        // once. The user can turn it off from the popover.
        if !UserDefaults.standard.bool(forKey: Self.launchAtLoginOfferedKey) {
            UserDefaults.standard.set(true, forKey: Self.launchAtLoginOfferedKey)
            setLaunchAtLogin(true)
        }
        observePowerSources()
        observeSleep()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: HelperConstants.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.helperStatus.isReady {
                    try? await self.helper.heartbeat()
                } else {
                    // Picks up the approval given in System Settings without a relaunch.
                    await self.connectHelper()
                }
            }
        }
        evaluate()
        Task { await connectHelper() }
    }

    /// Quitting the app hands control back to macOS: normal charging resumes.
    func shutdown() {
        guard helperStatus.isReady else { return }
        helper.restoreDefaultsBlocking()
    }

    // MARK: User actions

    func toggleDischarge() {
        policy.dischargeRequested.toggle()
        if policy.dischargeRequested { policy.topUpActive = false }
        evaluate()
    }

    func toggleTopUp() {
        policy.topUpActive.toggle()
        if policy.topUpActive { policy.dischargeRequested = false }
        evaluate()
    }

    func startCalibration() {
        policy.dischargeRequested = false
        policy.topUpActive = false
        policy.calibration = .chargeToFull
        evaluate()
    }

    func cancelCalibration() {
        policy.calibration = nil
        evaluate()
    }

    func installHelper() {
        do {
            try helper.register()
            lastError = nil
        } catch where helper.registrationStatus == .requiresApproval {
            // Expected on first install: register() throws EPERM ("Operation not permitted")
            // until the user allows the daemon. The notification doesn't always appear,
            // so take the user straight to the switch.
            lastError = nil
            helper.openLoginItemsSettings()
        } catch {
            lastError = "Helper registration failed: \(error.localizedDescription)"
        }
        Task { await connectHelper() }
    }

    func openLoginItemsSettings() {
        helper.openLoginItemsSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helper connection

    private func connectHelper() async {
        switch helper.registrationStatus {
        case .notRegistered, .notFound:
            helperStatus = .notInstalled
            return
        case .requiresApproval:
            helperStatus = .requiresApproval
            return
        case .enabled:
            break
        @unknown default:
            break
        }

        helperStatus = .connecting
        do {
            let version = try await helper.version()
            if version != HelperConstants.helperVersion {
                // An older daemon from a previous app version: re-register to pick up the new binary.
                appLog.notice("Helper \(version, privacy: .public) outdated, re-registering")
                try await helper.unregister()
                try helper.register()
                return await connectHelper()
            }
            let caps = try await helper.capabilities()
            capabilities = caps
            canLimitCharge = caps.canLimitCharge
            canForceDischarge = caps.canForceDischarge
            usesNativeChargeLimit = caps.usesNativeChargeLimit
            if usesNativeChargeLimit {
                // These need charge inhibit, which only powerd can do on this firmware.
                policy.topUpActive = false
            }
            helperStatus = .ready(version: version)
            applied = (nil, nil, nil)
            evaluate()
        } catch {
            // Typically a daemon still running the binary of a previous app version: the
            // file on disk changed, so its code signature no longer validates. Re-registering
            // makes launchd stop it and start the new binary.
            if !didReregisterHelper {
                didReregisterHelper = true
                appLog.notice("Helper unreachable (\(error.localizedDescription, privacy: .public)), re-registering")
                try? await helper.unregister()
                // May throw EPERM if macOS asks for approval again; connectHelper()
                // then reports .requiresApproval from the registration status.
                try? helper.register()
                return await connectHelper()
            }
            helperStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: Control loop

    func evaluate() {
        snapshot = telemetry.read()
        var newPolicy = policy
        let decision = ChargePolicy.evaluate(snapshot: snapshot, settings: settings, state: &newPolicy)
        if newPolicy != policy {
            policy = newPolicy
            UserDefaults.standard.set(try? JSONEncoder().encode(policy), forKey: Self.policyKey)
        }
        state = usesNativeChargeLimit ? observedState(decision.state) : decision.state
        apply(decision)
    }

    private func apply(_ decision: ChargeDecision) {
        guard helperStatus.isReady, let caps = capabilities else { return }

        // Intel without CH0B/CH0C: fall back to the firmware limit (BCLM).
        let wantsLimit: Int? = caps.charging == nil && caps.hardwareLimitKey != nil
            ? (settings.limitEnabled && !policy.topUpActive && policy.calibration == nil ? settings.chargeLimit : 100)
            : nil
        let wantsCharging = caps.charging != nil ? decision.chargingEnabled : nil
        let wantsAdapter = caps.adapter != nil ? decision.adapterEnabled : nil

        guard wantsCharging != applied.charging || wantsAdapter != applied.adapter || wantsLimit != applied.limit
        else { return }

        applyTask?.cancel()
        applyTask = Task {
            do {
                // Order matters: re-enable the adapter before allowing/stopping charge,
                // and inhibit charging before disabling the adapter.
                if let wantsAdapter, wantsAdapter { try await helper.setAdapter(true) }
                if let wantsCharging { try await helper.setCharging(wantsCharging) }
                if let wantsLimit { try await helper.setHardwareLimit(wantsLimit) }
                if let wantsAdapter, !wantsAdapter { try await helper.setAdapter(false) }
                guard !Task.isCancelled else { return }
                applied = (wantsCharging, wantsAdapter, wantsLimit)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                applied = (nil, nil, nil)
            }
        }
    }

    /// With the native limit, macOS decides when to charge: report what the hardware does
    /// instead of what our (inactive) limiter would want. Our own modes still win.
    private func observedState(_ policyState: ChargeState) -> ChargeState {
        switch policyState {
        case .discharging, .calibrating: return policyState
        default: break
        }
        guard snapshot.isPluggedIn else { return .onBattery }
        if snapshot.isCharging { return .charging }
        return snapshot.isFullyCharged ? .full : .limitReached
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }

    // MARK: Power source notifications (IOPS)

    /// IOPSNotificationCreateRunLoopSource fires on plug/unplug and percentage changes,
    /// so the policy reacts within milliseconds instead of waiting for the poll timer.
    private func observePowerSources() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { manager.evaluate() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceLoop = source
    }

    // MARK: Sleep / wake (IORegisterForSystemPower)

    private func observeSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPowerDomain = IORegisterForSystemPower(context, &sleepPort, { context, _, messageType, argument in
            guard let context else { return }
            let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.handlePowerMessage(messageType, argument: argument)
            }
        }, &sleepNotifier)
        if let sleepPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(sleepPort).takeUnretainedValue(),
                               .defaultMode)
        }
    }

    private func handlePowerMessage(_ type: UInt32, argument: UnsafeMutableRawPointer?) {
        let ack = { [rootPowerDomain] in _ = IOAllowPowerChange(rootPowerDomain, Int(bitPattern: argument)) }
        switch type {
        case kIOMessageCanSystemSleep:
            ack()
        case kIOMessageSystemWillSleep:
            // The app can't run while asleep, so the limit can't be enforced:
            // optionally inhibit charging first. Sleep waits for our ack (max ~30 s).
            let inhibit = settings.stopChargingWhenSleeping && settings.limitEnabled
                && !policy.topUpActive && policy.calibration == nil
                && capabilities?.charging != nil && helperStatus.isReady
            guard inhibit else { return ack() }
            Task {
                try? await helper.setCharging(false)
                applied.charging = false
                ack()
            }
        case kIOMessageSystemHasPoweredOn:
            applied = (nil, nil, nil)
            evaluate()
        default:
            break
        }
    }
}

// IOKit message constants are C macros that Swift can't import:
// iokit_common_msg(code) = sys_iokit (0xE0000000) | sub_iokit_common (0) | code.
// They must stay UInt32: as Int32 they are negative, and UInt32(negative) traps.
private let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
private let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
