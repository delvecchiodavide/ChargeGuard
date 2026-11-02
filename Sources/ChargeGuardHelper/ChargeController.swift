import ChargeCore
import Foundation
import SMCKit

/// The only code that writes to the SMC. Runs as root inside the daemon.
/// Not thread-safe by itself: `HelperService` calls it from one serial queue.
final class ChargeController {
    let smc: SMCBridge
    let capabilities: ChargeCapabilities

    private(set) var chargingEnabled = true
    private(set) var adapterEnabled = true
    private(set) var hardwareLimit = 100

    var isAtDefaults: Bool { chargingEnabled && adapterEnabled && hardwareLimit == 100 }

    init() throws {
        smc = try SMCBridge()
        capabilities = ChargeCapabilities.detect(using: smc)
        log.info("Capabilities: charging=\(String(describing: self.capabilities.charging), privacy: .public) adapter=\(String(describing: self.capabilities.adapter), privacy: .public) limit=\(self.capabilities.hardwareLimitKey ?? "none", privacy: .public)")
    }

    func setCharging(enabled: Bool) throws {
        guard let strategy = capabilities.charging else {
            throw HelperErrorCode.unsupported.error(
                "This Mac's SMC firmware exposes no known charge-inhibit key (CH0B/CH0C/CHTE). Run `sudo cgctl keys CH` to inspect it.")
        }
        let bytes = strategy.bytes(chargingEnabled: enabled)
        for key in strategy.keys {
            try write(key, bytes)
        }
        chargingEnabled = enabled
    }

    func setAdapter(enabled: Bool) throws {
        guard let strategy = capabilities.adapter else {
            throw HelperErrorCode.unsupported.error("This Mac's SMC firmware exposes no adapter-disable key (CH0I/CHIE).")
        }
        try write(strategy.key, strategy.bytes(adapterEnabled: enabled))
        adapterEnabled = enabled
    }

    func setHardwareLimit(_ percent: Int) throws {
        guard capabilities.hardwareLimitKey != nil else {
            throw HelperErrorCode.unsupported.error("BCLM is only available on Intel Macs.")
        }
        guard ChargeSettings.limitRange.contains(percent) else {
            throw HelperErrorCode.invalidArgument.error("Limit must be within 20...100, got \(percent).")
        }
        try write(SMCKeys.batteryChargeLevelMax, [UInt8(percent)])
        // MagSafe LED threshold follows BCLM where the key exists; failure is cosmetic.
        try? smc.write(SMCKeys.batteryFullChargeLED, bytes: [UInt8(percent)])
        hardwareLimit = percent
    }

    /// Best effort: tries every switch even if one fails, so the Mac always ends up charging normally.
    @discardableResult
    func restoreDefaults() -> [Error] {
        var errors: [Error] = []
        if capabilities.adapter != nil {
            do { try setAdapter(enabled: true) } catch { errors.append(error) }
        }
        if capabilities.charging != nil {
            do { try setCharging(enabled: true) } catch { errors.append(error) }
        }
        if capabilities.hardwareLimitKey != nil {
            do { try setHardwareLimit(100) } catch { errors.append(error) }
        }
        return errors
    }

    private func write(_ key: SMCKey, _ bytes: [UInt8]) throws {
        do {
            try smc.write(key, bytes: bytes, verify: true)
            log.debug("SMC \(key.description, privacy: .public) <- \(bytes.hex, privacy: .public)")
        } catch {
            log.error("SMC write \(key.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw HelperErrorCode.smcFailure.error("\(error)")
        }
    }
}
