import CSMC
import Foundation
import IOKit

// MARK: - Errors

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case serviceNotFound
    case openFailed(kern_return_t)
    case notPrivileged                       // write without root, or entitlement-protected key
    case ioKit(kern_return_t)                // IOConnectCallStructMethod failed
    case firmware(key: String, code: UInt8)  // SMCParamStruct.result != 0
    case keyNotFound(String)
    case sizeMismatch(key: String, expected: Int, got: Int)
    case verificationFailed(key: String, wrote: [UInt8], readBack: [UInt8])

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return "IOServiceOpen failed: \(SMCError.describe(kr))"
        case .notPrivileged: return "Not privileged (kIOReturnNotPrivileged): writes need root; some keys also need Apple's private entitlement com.apple.private.applesmc.user-access"
        case .ioKit(let kr): return "IOKit call failed: \(SMCError.describe(kr))"
        case let .firmware(key, code): return "SMC firmware error 0x\(String(code, radix: 16)) on \(key)"
        case .keyNotFound(let key): return "SMC key \(key) not present on this machine"
        case let .sizeMismatch(key, expected, got): return "\(key): expected \(expected) bytes, got \(got)"
        case let .verificationFailed(key, wrote, back):
            return "\(key): wrote \(wrote.hex) but read back \(back.hex) (firmware ignored the write)"
        }
    }

    static func describe(_ kr: kern_return_t) -> String {
        if let s = mach_error_string(kr) { return "\(String(cString: s)) (0x\(String(UInt32(bitPattern: kr), radix: 16)))" }
        return "0x\(String(UInt32(bitPattern: kr), radix: 16))"
    }
}

// MARK: - Key / value types

/// A four-character SMC key such as `CH0B`, stored as a big-endian FourCharCode.
public struct SMCKey: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let code: UInt32

    public init(_ string: String) {
        precondition(string.utf8.count == 4, "SMC keys are exactly 4 ASCII chars: \(string)")
        code = string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
    public init(stringLiteral value: String) { self.init(value) }
    public init(code: UInt32) { self.code = code }

    public var description: String { fourCC(code) }
}

public struct SMCKeyInfo: Sendable, Equatable {
    public let size: Int
    public let type: String         // e.g. "ui8 ", "flt ", "hex_"
    public let attributes: UInt8

    /// Attribute bit 0x40 marks a key writable from the host (best-effort hint;
    /// some firmware still rejects the write, so callers verify by read-back).
    public var isWritableHint: Bool { attributes & 0x40 != 0 }
}

public struct SMCValue: Sendable, Equatable {
    public let key: SMCKey
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    /// Decodes numeric SMC types. Apple Silicon stores `flt ` and integer types
    /// little-endian; Intel stores integers and fixed-point big-endian.
    public var doubleValue: Double? {
        let b = bytes
        switch info.type {
        case "flt ":
            guard b.count == 4 else { return nil }
            return Double(Float(bitPattern: UInt32(littleEndianBytes: b)))
        case "sp78": // signed 8.8 fixed point, big-endian (Intel temperatures)
            guard b.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2": // unsigned 14.2 fixed point, big-endian (Intel fan RPM)
            guard b.count == 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 ", "si8 ", "flag", "hex_", "ui16", "ui32", "ui64", "si16", "si32", "si64":
            guard let raw = integerValue else { return nil }
            return Double(raw)
        default:
            return nil
        }
    }

    /// Integer interpretation honoring the machine's SMC byte order.
    public var integerValue: Int64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        let unsigned = SMCBridge.isAppleSilicon
            ? UInt64(littleEndianBytes: bytes)
            : bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        if info.type.hasPrefix("si") {
            let shift = UInt64(64 - bytes.count * 8)
            return Int64(bitPattern: unsigned << shift) >> Int64(shift)
        }
        return Int64(bitPattern: unsigned)
    }
}

// MARK: - Bridge

/// Thread-safe connection to the AppleSMC kernel driver.
///
/// Reading works for any user. Writing requires the caller to be root
/// (euid 0); otherwise IOKit returns `kIOReturnNotPrivileged`. That is why all
/// writes live in the privileged helper while the app only reads.
public final class SMCBridge: @unchecked Sendable {
    public static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [SMCKey: SMCKeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        // User-client type 0 is the standard SMC user client.
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: Public API

    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        return try unlockedKeyInfo(key)
    }

    /// Returns `nil` when the key does not exist on this machine.
    public func keyInfoIfPresent(_ key: SMCKey) -> SMCKeyInfo? {
        try? keyInfo(key)
    }

    public func read(_ key: SMCKey) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        let info = try unlockedKeyInfo(key)

        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = UInt8(kSMCReadKey)
        let output = try call(&input, key: key)

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return SMCValue(key: key, info: info, bytes: bytes)
    }

    /// Writes raw bytes. `bytes.count` must equal the key's declared size.
    /// With `verify`, reads the key back and throws if the firmware silently
    /// ignored the write (common on Apple Silicon for unsupported keys).
    public func write(_ key: SMCKey, bytes: [UInt8], verify: Bool = true) throws {
        try {
            lock.lock(); defer { lock.unlock() }
            let info = try unlockedKeyInfo(key)
            guard bytes.count == info.size else {
                throw SMCError.sizeMismatch(key: key.description, expected: info.size, got: bytes.count)
            }

            var input = SMCParamStruct()
            input.key = key.code
            input.keyInfo.dataSize = UInt32(info.size)
            input.data8 = UInt8(kSMCWriteKey)
            withUnsafeMutableBytes(of: &input.bytes) { buffer in
                for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            }
            _ = try call(&input, key: key)
        }()

        if verify {
            let readBack = try read(key).bytes
            guard readBack == bytes else {
                throw SMCError.verificationFailed(key: key.description, wrote: bytes, readBack: readBack)
            }
        }
    }

    /// Total number of keys exposed by the firmware (`#KEY`).
    public func keyCount() throws -> Int {
        let value = try read("#KEY")
        // #KEY is a big-endian ui32 on every platform.
        return Int(value.bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    /// Enumerates every key, useful for discovering what this firmware supports.
    public func allKeys() throws -> [SMCKey] {
        let count = try keyCount()
        lock.lock(); defer { lock.unlock() }
        var keys: [SMCKey] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            var input = SMCParamStruct()
            input.data8 = UInt8(kSMCGetKeyFromIndex)
            input.data32 = UInt32(index)
            if let output = try? call(&input, key: "#KEY") {
                keys.append(SMCKey(code: output.key))
            }
        }
        return keys
    }

    // MARK: Private

    private func unlockedKeyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = UInt8(kSMCGetKeyInfo)
        let output = try call(&input, key: key)
        let info = SMCKeyInfo(size: Int(output.keyInfo.dataSize),
                              type: fourCC(output.keyInfo.dataType),
                              attributes: output.keyInfo.dataAttributes)
        infoCache[key] = info
        return info
    }

    private func call(_ input: inout SMCParamStruct, key: SMCKey) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, UInt32(kSMCHandleYPCEvent),
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outputSize)
        if kr == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard kr == kIOReturnSuccess else { throw SMCError.ioKit(kr) }

        switch Int(output.result) {
        case kSMCSuccess: return output
        case kSMCKeyNotFound: throw SMCError.keyNotFound(key.description)
        default: throw SMCError.firmware(key: key.description, code: output.result)
        }
    }
}

// MARK: - Helpers

func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
    return String(decoding: bytes, as: UTF8.self)
}

extension FixedWidthInteger {
    init(littleEndianBytes bytes: [UInt8]) {
        self = bytes.prefix(MemoryLayout<Self>.size).enumerated()
            .reduce(Self.zero) { $0 | Self($1.element) << ($1.offset * 8) }
    }
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hex: String) {
        let chars = [Character](hex.replacingOccurrences(of: " ", with: ""))
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
        }
        self = out
    }
}
