import Foundation

// MARK: - Telemetry

/// One reading of everything we know about the battery and power source.
public struct BatterySnapshot: Equatable, Sendable, Codable {
    public var timestamp = Date()

    /// Percentage shown by macOS in the menu bar (`CurrentCapacity`).
    public var osPercent = 0
    /// Real state of charge: RemainingCapacity / FullChargeCapacity (mAh).
    public var hardwarePercent: Double?

    /// A charger is physically attached, even if we disabled it (CHIE/CH0I).
    public var isPluggedIn = false
    /// macOS currently draws power from the adapter (false while force-discharging).
    public var isExternalPowerActive = false
    public var isCharging = false
    public var isFullyCharged = false

    public var temperatureC: Double?
    public var voltageMV = 0
    /// Positive while charging, negative while discharging.
    public var amperageMA = 0
    /// Battery power in W, signed like `amperageMA`.
    public var batteryPowerW: Double { Double(voltageMV) * Double(amperageMA) / 1_000_000 }
    /// Power delivered by the adapter, if reported (SMC `PDTR` or IOPS AdapterDetails).
    public var adapterPowerW: Double?
    public var adapterRatedWatts: Int?

    public var cycleCount = 0
    public var designCapacityMAh: Int?
    public var fullChargeCapacityMAh: Int?
    public var nominalChargeCapacityMAh: Int?
    public var remainingCapacityMAh: Int?
    /// Minutes to empty (on battery) or to full (charging); nil while calculating.
    public var timeRemainingMinutes: Int?

    /// "Maximum Capacity": full-charge capacity relative to design capacity.
    public var healthPercent: Double? {
        guard let full = nominalChargeCapacityMAh ?? fullChargeCapacityMAh,
              let design = designCapacityMAh, design > 0 else { return nil }
        return Double(full) / Double(design) * 100
    }

    public init() {}

    public func percent(useHardware: Bool) -> Double {
        if useHardware, let hw = hardwarePercent { return hw }
        return Double(osPercent)
    }
}

// MARK: - Settings

public struct ChargeSettings: Codable, Equatable, Sendable {
    public static let limitRange = 20...100

    public var limitEnabled = true
    /// Stop charging at this percentage.
    public var chargeLimit = 80

    /// Sailing mode: after reaching the limit, only resume charging at/below this value.
    public var sailingEnabled = false
    public var sailingLowerBound = 72

    public var heatProtectionEnabled = true
    public var heatLimitC = 35.0
    /// Resume charging once the battery is this many °C below the limit.
    public var heatHysteresisC = 3.0

    /// Inhibit charging before the Mac sleeps (the app can't enforce the limit while asleep).
    public var stopChargingWhenSleeping = true
    /// Use the real gauge (mAh ratio) instead of the percentage macOS shows.
    public var useHardwarePercentage = false

    /// Calibration: discharge target and hold time at 100 %.
    public var calibrationLowTarget = 10
    public var calibrationHoldMinutes = 60

    public init() {}

    /// Keeps values coherent after UI edits.
    public mutating func normalize() {
        chargeLimit = min(max(chargeLimit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        sailingLowerBound = min(max(sailingLowerBound, Self.limitRange.lowerBound - 5), chargeLimit - 1)
        calibrationLowTarget = min(max(calibrationLowTarget, ChargePolicy.hardFloorPercent), 30)
        heatLimitC = min(max(heatLimitC, 25), 50)
    }
}

// MARK: - State machine

public enum CalibrationPhase: Codable, Equatable, Sendable {
    case chargeToFull
    case holdAtFull(until: Date)
    case dischargeToLow
    case rechargeToFull

    public var title: String {
        switch self {
        case .chargeToFull: return "Charging to 100 %"
        case .holdAtFull: return "Holding at 100 %"
        case .dischargeToLow: return "Discharging"
        case .rechargeToFull: return "Recharging to 100 %"
        }
    }

    public var step: Int {
        switch self {
        case .chargeToFull: return 1
        case .holdAtFull: return 2
        case .dischargeToLow: return 3
        case .rechargeToFull: return 4
        }
    }
}

/// Mutable latches the policy carries between evaluations.
public struct PolicyState: Codable, Equatable, Sendable {
    /// Set when the limit is reached; cleared when the charge drops to the resume threshold.
    public var holdingAtLimit = false
    public var heatPaused = false
    public var dischargeRequested = false
    public var topUpActive = false
    public var calibration: CalibrationPhase?

    public init() {}
}

/// High-level state shown in the UI and used for the menu bar icon.
public enum ChargeState: Equatable, Sendable {
    case onBattery
    case charging
    case full
    case limitReached       // charge inhibited at the limit, running from the adapter
    case sailing            // inside the hysteresis band, charging inhibited
    case discharging        // adapter disabled on purpose
    case heatPaused
    case toppingUp
    case calibrating(CalibrationPhase)

    public var title: String {
        switch self {
        case .onBattery: return "On battery"
        case .charging: return "Charging"
        case .full: return "Fully charged"
        case .limitReached: return "Limit reached — on adapter power"
        case .sailing: return "Sailing"
        case .discharging: return "Discharging (adapter off)"
        case .heatPaused: return "Paused — battery too hot"
        case .toppingUp: return "Top-up to 100 %"
        case .calibrating(let phase): return "Calibration \(phase.step)/4 — \(phase.title)"
        }
    }
}

/// What the hardware should do right now.
public struct ChargeDecision: Equatable, Sendable {
    public var chargingEnabled: Bool
    public var adapterEnabled: Bool
    public var state: ChargeState

    public init(chargingEnabled: Bool, adapterEnabled: Bool, state: ChargeState) {
        self.chargingEnabled = chargingEnabled
        self.adapterEnabled = adapterEnabled
        self.state = state
    }
}
