import Foundation

/// SMC keys relevant to battery charge control and battery telemetry.
///
/// Apple does not document these keys. The values below come from the
/// open-source community (bclm, batt, battery) and
/// were cross-checked with `cgctl probe`. Firmware differs across machines
/// and macOS releases, so nothing is hard-coded per model: the helper probes
/// which keys exist (`ChargeCapabilities.detect`) and verifies every write by
/// reading it back.
public enum SMCKeys {
    // MARK: Charge inhibit (adapter stays on, battery stops charging)

    /// Intel T2 and Apple Silicon up to the macOS 15.x firmware.
    /// `hex_`/`ui8`, 1 byte each: 0x00 = charging allowed, 0x02 = inhibited.
    /// Both keys must be written together.
    public static let chargeInhibitA: SMCKey = "CH0B"
    public static let chargeInhibitB: SMCKey = "CH0C"

    /// Apple Silicon with the macOS 26 (Tahoe) firmware, where CH0B/CH0C were removed.
    /// `ui32`, 4 bytes little-endian: 0 = charging allowed, 1 = inhibited.
    public static let chargeInhibitTahoe: SMCKey = "CHTE"

    // MARK: Adapter disable (forces the Mac to run from battery while plugged in)

    /// Intel and Apple Silicon up to macOS 15.x firmware. 1 byte: 0x00 = adapter in use, 0x01 = disabled.
    public static let adapterDisable: SMCKey = "CH0I"
    /// Apple Silicon with the macOS 26 firmware. 1 byte: 0x00 = adapter in use, 0x08 = disabled.
    public static let adapterDisableTahoe: SMCKey = "CHIE"

    // MARK: Hardware charge limit

    /// Intel only: Battery Charge Level Max, `ui8`, 20...100.
    /// The firmware itself stops at the value, even while the Mac sleeps.
    public static let batteryChargeLevelMax: SMCKey = "BCLM"
    /// Intel MagSafe LED threshold that pairs with BCLM (`ui8`, same value as BCLM).
    public static let batteryFullChargeLED: SMCKey = "BFCL"
    /// Apple Silicon on macOS 12 firmware only: 1 = stop at 80%. Gone on macOS 13+.
    public static let chargeWattAt80: SMCKey = "CHWA"

    // MARK: MagSafe LED (Apple Silicon MagSafe 3 and Intel MagSafe)

    /// `ui8`: 0x00 = system controls, 0x01 = off, 0x03 = green, 0x04 = orange.
    public static let magSafeLED: SMCKey = "ACLC"

    // MARK: Telemetry (read-only, any user)

    /// Battery temperature sensors. Intel: `sp78`, Apple Silicon: `flt `.
    public static let batteryTemperatures: [SMCKey] = ["TB0T", "TB1T", "TB2T", "TB3T"]
    /// Battery current in mA, signed (`si16`); negative while discharging.
    public static let batteryCurrent: SMCKey = "B0AC"
    /// Battery voltage in mV (`ui16`).
    public static let batteryVoltage: SMCKey = "B0AV"
    /// Battery charge/discharge power in W (Apple Silicon, `flt `).
    public static let batteryPower: SMCKey = "PPBR"
    /// Total power drawn from the adapter in W (Apple Silicon, `flt `).
    public static let adapterPower: SMCKey = "PDTR"
    /// Total system power in W (`flt `).
    public static let systemPower: SMCKey = "PSTR"

    public static let allCandidates: [SMCKey] = [
        chargeInhibitA, chargeInhibitB, chargeInhibitTahoe,
        adapterDisable, adapterDisableTahoe,
        batteryChargeLevelMax, batteryFullChargeLED, chargeWattAt80, magSafeLED,
        batteryCurrent, batteryVoltage, batteryPower, adapterPower, systemPower,
    ] + batteryTemperatures
}

// MARK: - Strategies

/// How this machine's firmware lets us stop charging.
public enum ChargingStrategy: String, Codable, Sendable, CustomStringConvertible {
    case ch0bc   // CH0B + CH0C
    case chte    // CHTE

    public var description: String {
        switch self {
        case .ch0bc: return "CH0B/CH0C (legacy firmware)"
        case .chte: return "CHTE (macOS 26 firmware)"
        }
    }

    public func bytes(chargingEnabled: Bool) -> [UInt8] {
        switch self {
        case .ch0bc: return [chargingEnabled ? 0x00 : 0x02]
        case .chte: return chargingEnabled ? [0, 0, 0, 0] : [1, 0, 0, 0]
        }
    }

    public var keys: [SMCKey] {
        switch self {
        case .ch0bc: return [SMCKeys.chargeInhibitA, SMCKeys.chargeInhibitB]
        case .chte: return [SMCKeys.chargeInhibitTahoe]
        }
    }
}

/// How this machine's firmware lets us run on battery while plugged in.
public enum AdapterStrategy: String, Codable, Sendable, CustomStringConvertible {
    case ch0i
    case chie

    public var description: String {
        switch self {
        case .ch0i: return "CH0I (legacy firmware)"
        case .chie: return "CHIE (macOS 26+ firmware)"
        }
    }

    public var key: SMCKey { self == .ch0i ? SMCKeys.adapterDisable : SMCKeys.adapterDisableTahoe }

    public func bytes(adapterEnabled: Bool) -> [UInt8] {
        switch self {
        case .ch0i: return [adapterEnabled ? 0x00 : 0x01]
        case .chie: return [adapterEnabled ? 0x00 : 0x08]
        }
    }
}

/// What the current machine supports, detected at runtime from key presence.
public struct ChargeCapabilities: Codable, Sendable, Equatable {
    public var charging: ChargingStrategy?
    public var adapter: AdapterStrategy?
    public var hardwareLimitKey: String?          // "BCLM" on Intel
    public var temperatureKeys: [SMCKey]

    public var canLimitCharge: Bool { charging != nil || hardwareLimitKey != nil }
    public var canForceDischarge: Bool { adapter != nil }
    /// Apple Silicon on macOS 27+: the charge-inhibit keys (CHLS, CH0J) are gated by
    /// Apple's private entitlement `com.apple.private.applesmc.user-access`, so only
    /// powerd can limit charging. Users set the limit in System Settings › Battery.
    public var usesNativeChargeLimit: Bool {
        charging == nil && hardwareLimitKey == nil && SMCBridge.isAppleSilicon
    }

    public init(charging: ChargingStrategy?, adapter: AdapterStrategy?,
                hardwareLimitKey: String?, temperatureKeys: [SMCKey]) {
        self.charging = charging
        self.adapter = adapter
        self.hardwareLimitKey = hardwareLimitKey
        self.temperatureKeys = temperatureKeys
    }

    /// Probes key presence and sizes. Newer keys win when both generations exist,
    /// because transitional firmware may keep the old keys as no-ops.
    public static func detect(using smc: SMCBridge) -> ChargeCapabilities {
        func has(_ key: SMCKey, size: Int) -> Bool { smc.keyInfoIfPresent(key)?.size == size }

        let charging: ChargingStrategy? =
            has(SMCKeys.chargeInhibitTahoe, size: 4) ? .chte :
            (has(SMCKeys.chargeInhibitA, size: 1) && has(SMCKeys.chargeInhibitB, size: 1)) ? .ch0bc : nil

        let adapter: AdapterStrategy? =
            has(SMCKeys.adapterDisableTahoe, size: 1) ? .chie :
            has(SMCKeys.adapterDisable, size: 1) ? .ch0i : nil

        let limitKey = !SMCBridge.isAppleSilicon && has(SMCKeys.batteryChargeLevelMax, size: 1)
            ? SMCKeys.batteryChargeLevelMax.description : nil

        let temps = SMCKeys.batteryTemperatures.filter { smc.keyInfoIfPresent($0) != nil }

        return ChargeCapabilities(charging: charging, adapter: adapter,
                                  hardwareLimitKey: limitKey, temperatureKeys: temps)
    }
}

extension SMCKey: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
