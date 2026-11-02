import Foundation
import IOKit
import SMCKit

/// Reads battery state from the `AppleSmartBattery` IORegistry entry, with SMC
/// fallbacks for values newer macOS releases removed from the registry
/// (macOS 27 drops `Temperature` and the `AppleRaw*Capacity` keys).
/// Works without root; safe to call from any thread.
public final class BatteryTelemetry: @unchecked Sendable {
    private let smc: SMCBridge?

    public init(smc: SMCBridge?) {
        self.smc = smc
    }

    public func read() -> BatterySnapshot {
        var s = BatterySnapshot()
        guard let props = Self.batteryProperties() else { return s }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        // On Apple Silicon CurrentCapacity/MaxCapacity are already percentages;
        // on Intel they are mAh.
        let current = int("CurrentCapacity", in: props) ?? 0
        let maxCapacity = int("MaxCapacity", in: props) ?? 100
        s.osPercent = maxCapacity > 100 ? Int((Double(current) * 100 / Double(maxCapacity)).rounded()) : current

        s.isExternalPowerActive = bool("ExternalConnected", in: props) ?? false
        s.isPluggedIn = bool("AppleRawExternalConnected", in: props) ?? s.isExternalPowerActive
        s.isCharging = bool("IsCharging", in: props) ?? false
        s.isFullyCharged = bool("FullyCharged", in: props) ?? false

        s.voltageMV = int("Voltage", in: props) ?? int("AppleRawBatteryVoltage", in: props) ?? 0
        s.amperageMA = int("InstantAmperage", in: props) ?? int("Amperage", in: props) ?? 0
        s.cycleCount = int("CycleCount", in: props) ?? 0

        s.designCapacityMAh = int("DesignCapacity", in: data) ?? int("DesignCapacity", in: props)
        s.fullChargeCapacityMAh = int("FullChargeCapacity", in: data) ?? int("AppleRawMaxCapacity", in: props)
        s.nominalChargeCapacityMAh = int("NominalChargeCapacity", in: data) ?? int("NominalChargeCapacity", in: props)
        s.remainingCapacityMAh = int("RemainingCapacity", in: data) ?? int("AppleRawCurrentCapacity", in: props)
        if let remaining = s.remainingCapacityMAh, let full = s.fullChargeCapacityMAh, full > 0 {
            s.hardwarePercent = min(max(Double(remaining) / Double(full) * 100, 0), 100)
        }

        let minutes = int(s.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty", in: props)
        s.timeRemainingMinutes = minutes.flatMap { $0 == 0 || $0 == 65535 ? nil : $0 }

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            s.adapterRatedWatts = int("Watts", in: adapter)
        }

        // Hundredths of °C where still published (macOS ≤ 26, Intel).
        s.temperatureC = int("Temperature", in: props).map { Double($0) / 100 }
        readSMC(into: &s)
        return s
    }

    private func readSMC(into s: inout BatterySnapshot) {
        guard let smc else { return }
        if s.temperatureC == nil {
            let temps = SMCKeys.batteryTemperatures
                .compactMap { try? smc.read($0).doubleValue }
                .filter { (0...100).contains($0) }
            s.temperatureC = temps.max()
                ?? (try? smc.read("B0AT"))?.integerValue.map { Double($0) / 100 }
        }
        if s.isPluggedIn, let watts = try? smc.read(SMCKeys.adapterPower).doubleValue, watts > 0.5 {
            s.adapterPowerW = watts
        }
    }

    private static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }   // desktop Mac: no battery
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return props?.takeRetainedValue() as? [String: Any]
    }
}

/// IORegistry stores signed values (Amperage) as 64-bit numbers that `ioreg`
/// prints unsigned; `int64Value` recovers the sign.
private func int(_ key: String, in dict: [String: Any]) -> Int? {
    (dict[key] as? NSNumber).map { Int(clamping: $0.int64Value) }
}

private func bool(_ key: String, in dict: [String: Any]) -> Bool? {
    (dict[key] as? NSNumber)?.boolValue
}
