// cgctl — terminal diagnostics for the SMC layer.
//
//   cgctl probe                 detect charge-control strategy + battery sensors
//   cgctl read KEY [KEY...]     print type, size, raw bytes, decoded value
//   cgctl telemetry            decoded BatterySnapshot (IORegistry + SMC)
//   cgctl keys [PREFIX]         list every SMC key (optionally filtered)
//   sudo cgctl write KEY HEX    raw write with read-back verification (root only)
import ChargeCore
import Foundation
import SMCKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ smc: SMCBridge, _ key: SMCKey) -> String {
    do {
        let value = try smc.read(key)
        let decoded = value.doubleValue.map { String(format: "%.2f", $0) } ?? "-"
        let rw = value.info.isWritableHint ? "w" : "-"
        return "\(key)  [\(value.info.type)] size=\(value.info.size) attr=0x\(String(value.info.attributes, radix: 16))(\(rw))  bytes=\(value.bytes.hex)  value=\(decoded)"
    } catch {
        return "\(key)  \(error)"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: cgctl probe | read KEY... | keys [PREFIX] | write KEY HEX")
}
let smc: SMCBridge
do { smc = try SMCBridge() } catch { fail("\(error)") }

switch command {
case "probe":
    let caps = ChargeCapabilities.detect(using: smc)
    print("Architecture     : \(SMCBridge.isAppleSilicon ? "Apple Silicon" : "Intel")")
    print("Running as root  : \(geteuid() == 0)")
    print("Charging control : \(caps.charging.map(String.init(describing:)) ?? (caps.usesNativeChargeLimit ? "macOS native limit only (CHLS/CH0J need Apple's private entitlement)" : "UNSUPPORTED"))")
    print("Adapter control  : \(caps.adapter.map(String.init(describing:)) ?? "UNSUPPORTED")")
    print("Hardware limit   : \(caps.hardwareLimitKey.map { "\($0)" } ?? "none (software limiter)")")
    print("Temperature keys : \(caps.temperatureKeys.map(\.description).joined(separator: " "))")
    print("\nAll candidate keys:")
    for key in SMCKeys.allCandidates { print("  " + describe(smc, key)) }
case "telemetry":
    let snap = BatteryTelemetry(smc: smc).read()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! encoder.encode(snap), as: UTF8.self))
    print("batteryPowerW: \(String(format: "%.2f", snap.batteryPowerW))  healthPercent: \(snap.healthPercent.map { String(format: "%.1f", $0) } ?? "-")")
case "read":
    for name in args.dropFirst() { print(describe(smc, SMCKey(name))) }
case "keys":
    let prefix = args.dropFirst().first ?? ""
    do {
        for key in try smc.allKeys() where key.description.hasPrefix(prefix) {
            print(describe(smc, key))
        }
    } catch { fail("\(error)") }
case "write":
    guard args.count == 3, let bytes = [UInt8](hex: args[2]) else { fail("usage: sudo cgctl write KEY HEX") }
    do {
        try smc.write(SMCKey(args[1]), bytes: bytes)
        print("OK  " + describe(smc, SMCKey(args[1])))
    } catch { fail("write failed: \(error)") }
default:
    fail("unknown command \(command)")
}
