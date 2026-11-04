import SwiftUI
import AppKit
import ChargeCore

struct MenuBarView: View {
    @ObservedObject var manager: BatteryManager
    @ObservedObject var updater: UpdateChecker

    @State private var showCalibrationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !manager.helperStatus.isReady {
                helperBanner
            }

            if updater.available != nil || updater.phase != .idle || updater.lastCheckFoundNothing {
                updateBanner
            }

            Divider()
            chargeLimitSection
            Divider()
            modesSection
            Divider()
            heatSection
            Divider()
            diagnosticsSection

            if let error = manager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .padding(14)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(manager.snapshot.osPercent)%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))

                HStack(spacing: 4) {
                    Image(systemName: MenuBarIcon.symbolName(for: manager.state, percent: manager.snapshot.osPercent))
                        .foregroundStyle(headerTint)

                    Text(manager.state.title)
                        .font(.headline)
                        .foregroundStyle(headerTint)
                }
            }

            headerBar
        }
    }

    private var headerTint: Color {
        switch manager.state {
        case .charging, .full, .toppingUp:
            return .green
        case .limitReached, .sailing:
            return .blue
        case .discharging, .calibrating(_):
            return .orange
        case .heatPaused:
            return .red
        case .onBattery:
            return .secondary
        }
    }

    private var headerBar: some View {
        let limit = manager.settings.chargeLimit

        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(manager.snapshot.osPercent) / 100)
                .progressViewStyle(.linear)
                .tint(headerTint)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    // With the native limit our value isn't enforced: don't draw it as if it were.
                    if !manager.usesNativeChargeLimit {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.secondary)
                                .frame(width: 2, height: 10)
                                .offset(x: geo.size.width * CGFloat(limit) / 100 - 1)
                        }
                    }
                }

            HStack(spacing: 4) {
                Text(manager.usesNativeChargeLimit ? "Limit set in System Settings" : "Limit \(limit)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if let hw = manager.snapshot.hardwarePercent {
                    Text(String(format: "Hardware %.1f%%", hw))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helper banner

    private var helperBanner: some View {
        GroupBox {
            HStack(spacing: 8) {
                helperBannerContent
            }
        }
    }

    @ViewBuilder
    private var helperBannerContent: some View {
        switch manager.helperStatus {
        case .notInstalled:
            Text("Helper not installed. Install it to enforce the charge limit.")
            Spacer()
            Button("Install Helper") {
                manager.installHelper()
            }

        case .requiresApproval:
            Text("Helper needs approval in Login Items.")
            Spacer()
            Button("Open Login Items…") {
                manager.openLoginItemsSettings()
            }

        case .connecting:
            Text("Connecting to helper…")
            Spacer()
            ProgressView()
                .controlSize(.small)

        case .ready:
            EmptyView()

        case .failed(let message):
            Text(message)
            Spacer()
            Button("Retry") {
                manager.installHelper()
            }
        }
    }

    // MARK: - Charge limit

    @ViewBuilder
    private var chargeLimitSection: some View {
        if manager.usesNativeChargeLimit {
            nativeLimitSection
        } else {
            customLimitSection
        }
    }

    /// macOS 27+ Apple Silicon: the limit lives in System Settings; the slider only
    /// sets the target for "Discharge to limit".
    private var nativeLimitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Charge limit is managed by macOS")
                Spacer()
                Button("Battery Settings…") { manager.openBatterySettings() }
            }
            Text("On this Mac only Apple's power daemon can stop charging. Set the limit in System Settings › Battery › Charging.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Discharge target")
                    .foregroundStyle(.secondary)
                Slider(value: chargeLimitDouble, in: 20...100, step: 1)
                TextField("", value: binding(\.chargeLimit), formatter: chargeLimitFormatter)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
            }
            .disabled(!manager.canForceDischarge)
        }
    }

    private var customLimitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Limit charging", isOn: binding(\.limitEnabled))
                .disabled(!manager.canLimitCharge)

            HStack(spacing: 8) {
                Slider(value: chargeLimitDouble, in: 20...100, step: 1)

                TextField("", value: binding(\.chargeLimit), formatter: chargeLimitFormatter)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
            }
            .disabled(!manager.canLimitCharge)

            if !manager.canLimitCharge {
                Text("Not supported by this Mac's firmware")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chargeLimitDouble: Binding<Double> {
        Binding(
            get: { Double(self.manager.settings.chargeLimit) },
            set: { self.manager.settings.chargeLimit = Int($0.rounded()) }
        )
    }

    private var chargeLimitFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 20
        formatter.maximum = 100
        return formatter
    }

    // MARK: - Modes

    private var modesSection: some View {
        GroupBox("Modes") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sailing mode", isOn: binding(\.sailingEnabled))
                    .disabled(manager.usesNativeChargeLimit)

                if manager.settings.sailingEnabled && !manager.usesNativeChargeLimit {
                    Stepper(
                        "Resume below \(manager.settings.sailingLowerBound)%",
                        value: sailingLowerBoundBinding,
                        in: 20...sailingUpper,
                        step: 1
                    )
                }

                actionRow(
                    label: "Force discharge",
                    buttonTitle: manager.policy.dischargeRequested ? "Stop discharging" : "Discharge to limit",
                    action: { manager.toggleDischarge() },
                    disabled: !manager.canForceDischarge
                )

                actionRow(
                    label: "Top-up",
                    buttonTitle: manager.policy.topUpActive ? "Cancel top-up" : "Top up to 100 %",
                    action: { manager.toggleTopUp() },
                    disabled: manager.usesNativeChargeLimit
                )

                actionRow(
                    label: "Calibration",
                    buttonTitle: manager.policy.calibration != nil ? "Cancel calibration" : "Calibrate battery…",
                    action: {
                        if manager.policy.calibration == nil {
                            showCalibrationConfirmation = true
                        } else {
                            manager.cancelCalibration()
                        }
                    }
                )
            }
        }
        .confirmationDialog(
            "Calibrate battery?",
            isPresented: $showCalibrationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start calibration") {
                manager.startCalibration()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                "\(manager.usesNativeChargeLimit ? "Turn off the macOS charge limit first, or step 1 never completes. " : "")This will: 1. Charge to 100 %, 2. Hold at 100 % for \(manager.settings.calibrationHoldMinutes) minutes, 3. Discharge to \(manager.settings.calibrationLowTarget) %, 4. Recharge to 100 %."
            )
        }
    }

    private var sailingUpper: Int {
        max(20, manager.settings.chargeLimit - 1)
    }

    private var sailingLowerBoundBinding: Binding<Int> {
        Binding(
            get: {
                let value = self.manager.settings.sailingLowerBound
                return min(max(value, 20), self.sailingUpper)
            },
            set: {
                self.manager.settings.sailingLowerBound = min(max($0, 20), self.sailingUpper)
            }
        )
    }

    private func actionRow(
        label: String,
        buttonTitle: String,
        action: @escaping () -> Void,
        disabled: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)

            Spacer()

            Button(buttonTitle, action: action)
                .controlSize(.small)
                .disabled(disabled)
        }
    }

    // MARK: - Heat protection

    private var heatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Heat protection", isOn: binding(\.heatProtectionEnabled))
                .disabled(manager.usesNativeChargeLimit)

            Stepper(
                "Pause above \(Int(manager.settings.heatLimitC))°C",
                value: binding(\.heatLimitC),
                in: 30...45,
                step: 1
            )
            .disabled(!manager.settings.heatProtectionEnabled || manager.usesNativeChargeLimit)

            if manager.usesNativeChargeLimit {
                Text("Sailing, top-up and heat protection need charge control, which this Mac reserves to macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        DisclosureGroup("Diagnostics") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                diagnosticRow("macOS %", "\(manager.snapshot.osPercent)%")
                diagnosticRow("Hardware %", formattedDouble(manager.snapshot.hardwarePercent, "%.1f%%"))
                diagnosticRow("Temperature", formattedDouble(manager.snapshot.temperatureC, "%.1f °C"))
                diagnosticRow("Voltage", String(format: "%.2f V", Double(manager.snapshot.voltageMV) / 1000))
                diagnosticRow("Current", "\(manager.snapshot.amperageMA) mA")
                diagnosticRow("Battery power", String(format: "%+.1f W", manager.snapshot.batteryPowerW))
                diagnosticRow("Adapter", adapterString)
                diagnosticRow("Cycle count", "\(manager.snapshot.cycleCount)")
                diagnosticRow("Health", formattedDouble(manager.snapshot.healthPercent, "%.1f%%"))
                diagnosticRow("Full charge / Design", fullDesignString)
                diagnosticRow("Time remaining", timeRemainingString)
            }
            .font(.caption)
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)

            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private func formattedDouble(_ value: Double?, _ format: String) -> String {
        guard let value else {
            return "—"
        }
        return String(format: format, value)
    }

    private var adapterString: String {
        if let watts = manager.snapshot.adapterPowerW {
            return String(format: "%.1f W", watts)
        }
        if let rated = manager.snapshot.adapterRatedWatts {
            return "\(rated) W rated"
        }
        return "—"
    }

    private var fullDesignString: String {
        if let full = manager.snapshot.fullChargeCapacityMAh,
           let design = manager.snapshot.designCapacityMAh {
            return "\(full) / \(design) mAh"
        }
        return "—"
    }

    private var timeRemainingString: String {
        guard let minutes = manager.snapshot.timeRemainingMinutes else {
            return "—"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        return String(format: "%d:%02d", hours, remainder)
    }

    // MARK: - Updates

    @ViewBuilder
    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updater.phase {
            case .checking:
                Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
            case .downloading:
                Label("Downloading update…", systemImage: "arrow.down.circle")
            case .installing:
                Label("Installing update…", systemImage: "shippingbox")
            case .failed(let message):
                Label("Update failed", systemImage: "exclamationmark.triangle")
                Text(message).font(.caption).foregroundStyle(.secondary)
                if updater.available != nil {
                    Button("Open release page") { updater.openReleasePage() }
                }
            case .idle:
                if let release = updater.available {
                    Label("ChargeGuard \(release.version) is available", systemImage: "arrow.down.app")
                        .font(.headline)
                    Text("You have \(updater.currentVersion).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Install and relaunch") { updater.install() }
                            .buttonStyle(.borderedProminent)
                        Button("Release notes") { updater.openReleasePage() }
                        Spacer()
                        Button("Skip") { updater.skip() }
                    }
                } else if updater.lastCheckFoundNothing {
                    Label("ChargeGuard \(updater.currentVersion) is up to date", systemImage: "checkmark.circle")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at login", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.setLaunchAtLogin($0) }
                ))
                Toggle("Stop charging when sleeping", isOn: binding(\.stopChargingWhenSleeping))
                    .disabled(manager.usesNativeChargeLimit)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Button("Check for updates") { updater.check(userInitiated: true) }
                    .disabled(updater.isBusy)
                    .help("ChargeGuard \(updater.currentVersion)")
                Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
                .keyboardShortcut("q")
            }
        }
    }

    // MARK: - Settings binding helper

    private func binding<T>(_ keyPath: WritableKeyPath<ChargeSettings, T>) -> Binding<T> {
        Binding(
            get: { self.manager.settings[keyPath: keyPath] },
            set: { self.manager.settings[keyPath: keyPath] = $0 }
        )
    }
}
