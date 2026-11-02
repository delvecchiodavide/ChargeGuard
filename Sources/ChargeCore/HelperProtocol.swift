import Foundation
import Security

public enum HelperConstants {
    /// Bundle identifier of the menu bar app — the only client the helper accepts.
    public static let appBundleID = "com.example.chargeguard"
    /// launchd label == Mach service name == helper bundle identifier.
    public static let helperLabel = "com.example.chargeguard.helper"
    /// Name of the plist shipped in ChargeGuard.app/Contents/Library/LaunchDaemons/.
    public static let daemonPlistName = "com.example.chargeguard.helper.plist"
    /// Bump whenever the XPC protocol changes; the app re-registers a mismatched helper.
    public static let helperVersion = "1.0.0"
    /// Without a heartbeat for this long, the helper assumes the app crashed and restores defaults.
    public static let orphanTimeout: TimeInterval = 5 * 60
    public static let heartbeatInterval: TimeInterval = 60
}

/// App -> helper. Runs as root inside the daemon.
///
/// Only XPC-safe types (Bool, Int, String, Data, NSError) cross the boundary;
/// structured values travel as JSON `Data`.
@objc(BatteryHelperProtocol)
public protocol BatteryHelperProtocol {
    func helperVersion(reply: @escaping (String) -> Void)
    /// JSON-encoded `ChargeCapabilities`.
    func capabilities(reply: @escaping (Data?, NSError?) -> Void)
    /// Inhibit or allow battery charging; the adapter keeps powering the Mac.
    func setChargingEnabled(_ enabled: Bool, reply: @escaping (NSError?) -> Void)
    /// Disable the adapter so the Mac runs from battery while plugged in.
    func setAdapterEnabled(_ enabled: Bool, reply: @escaping (NSError?) -> Void)
    /// Intel only (BCLM): firmware-enforced limit that also holds during sleep.
    func setHardwareChargeLimit(_ percent: Int, reply: @escaping (NSError?) -> Void)
    /// Liveness ping; resets the orphan watchdog.
    func heartbeat(reply: @escaping () -> Void)
    /// Re-enable charging and adapter, reset BCLM to 100.
    func restoreDefaults(reply: @escaping (NSError?) -> Void)
}

/// Helper -> app (the bidirectional half of the connection).
@objc(BatteryHelperClientProtocol)
public protocol BatteryHelperClientProtocol {
    /// The helper changed hardware state on its own (safety floor, orphan watchdog).
    func helperDidApplySafetyOverride(_ reason: String)
}

public enum HelperErrorCode: Int {
    case unsupported = 1
    case smcFailure = 2
    case invalidArgument = 3

    public func error(_ message: String) -> NSError {
        NSError(domain: "ChargeGuardHelper", code: rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension NSXPCInterface {
    public static var batteryHelper: NSXPCInterface {
        NSXPCInterface(with: BatteryHelperProtocol.self)
    }
    public static var batteryHelperClient: NSXPCInterface {
        NSXPCInterface(with: BatteryHelperClientProtocol.self)
    }
}

// MARK: - Code signing

public enum CodeSigning {
    /// Team identifier of the running process, read from its own signature.
    /// Both processes are signed by the same team, so neither hard-codes it.
    public static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Designated-requirement string for a peer with `identifier`, signed by our team.
    ///
    /// `anchor apple generic` + `certificate leaf[subject.OU]` pins the peer to
    /// an Apple-issued certificate (Developer ID or Apple Development) of our
    /// team, so a same-named binary signed by anyone else is rejected.
    /// Returns nil when we are not team-signed (ad-hoc `swift build`), in which
    /// case callers must refuse connections in release builds.
    public static func requirement(forPeer identifier: String) -> String? {
        guard let team = currentTeamID() else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
