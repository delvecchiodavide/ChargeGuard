import AppKit
import ChargeCore
import Foundation
import Security

struct AppRelease: Equatable {
    let version: String
    let pageURL: URL
    let dmgURL: URL?
    let notes: String
}

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// The downloaded app must carry the same designated requirement the helper
/// enforces (our bundle ID, signed by our team), so a tampered DMG or a
/// compromised release asset can't replace the app with someone else's code.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, downloading, installing, failed(String)
    }

    @Published private(set) var available: AppRelease?
    @Published private(set) var phase: Phase = .idle
    /// Set after a check the user asked for that found nothing, to confirm it ran.
    @Published private(set) var lastCheckFoundNothing = false

    static let repository = "delvecchiodavide/ChargeGuard"
    private static let skippedKey = "SkippedUpdateVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?

    var isBusy: Bool { [.checking, .downloading, .installing].contains(phase) }

    func start() {
        Task {
            // Don't compete with helper connection and the first telemetry read.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(userInitiated: false) }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        phase = .checking
        lastCheckFoundNothing = false
        Task {
            do {
                let release = try await fetchLatest()
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                let wanted = Self.isNewer(release.version, than: currentVersion)
                    && (userInitiated || release.version != skipped)
                available = wanted ? release : nil
                lastCheckFoundNothing = userInitiated && available == nil
                phase = .idle
            } catch {
                appLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    private func fetchLatest() async throws -> AppRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChargeGuard/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        var version = release.tagName
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        return AppRelease(version: version,
                          pageURL: release.htmlUrl,
                          dmgURL: release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadUrl,
                          notes: release.body ?? "")
    }

    func skip() {
        guard let available else { return }
        UserDefaults.standard.set(available.version, forKey: Self.skippedKey)
        self.available = nil
    }

    func openReleasePage() {
        if let url = available?.pageURL { NSWorkspace.shared.open(url) }
    }

    // MARK: Install

    func install() {
        guard let release = available, let dmg = release.dmgURL else { return openReleasePage() }
        guard !isBusy else { return }
        Task {
            do {
                try await performInstall(release, dmg: dmg)
            } catch {
                appLog.error("Update failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func performInstall(_ release: AppRelease, dmg: URL) async throws {
        let fm = FileManager.default
        let currentApp = Bundle.main.bundleURL
        let folder = currentApp.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw UpdateError("ChargeGuard's folder isn't writable; download the update from the release page.")
        }

        phase = .downloading
        let (downloaded, response) = try await URLSession.shared.download(from: dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("ChargeGuard-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let image = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: downloaded, to: image)

        phase = .installing
        let plist = try await Self.run("/usr/bin/hdiutil",
                                       ["attach", "-nobrowse", "-noautoopen", "-readonly", "-plist", image.path])
        guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entities = info["system-entities"] as? [[String: Any]],
              let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateError("Couldn't mount the downloaded disk image.") }

        do {
            let newApp = URL(fileURLWithPath: mountPoint).appendingPathComponent("ChargeGuard.app")
            guard fm.fileExists(atPath: newApp.path) else {
                throw UpdateError("The disk image doesn't contain ChargeGuard.app.")
            }
            try Self.verifySignature(of: newApp)
            let newVersion = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard newVersion == release.version else {
                throw UpdateError("The downloaded app is version \(newVersion ?? "unknown"), expected \(release.version).")
            }

            // Stage next to the current app (same volume), then swap atomically.
            let staged = folder.appendingPathComponent(".ChargeGuard-update.app")
            try? fm.removeItem(at: staged)
            _ = try await Self.run("/usr/bin/ditto", [newApp.path, staged.path])
            _ = try fm.replaceItemAt(currentApp, withItemAt: staged)
        } catch {
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint])
            throw error
        }
        _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint])

        // Relaunch once this process is gone. Quitting restores default charging via the
        // helper; the new app re-registers the helper because its version changed.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c",
                              "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              currentApp.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private static func verifySignature(of app: URL) throws {
        guard let requirementText = CodeSigning.requirement(forPeer: HelperConstants.appBundleID) else {
            throw UpdateError("This build isn't team-signed, so updates can't be verified.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { throw UpdateError("Couldn't read the downloaded app's signature.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("The downloaded app failed signature verification (OSStatus \(status)).")
        }
    }

    // MARK: Helpers

    static func isNewer(_ a: String, than b: String) -> Bool {
        var lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        var rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        return rhs.lexicographicallyPrecedes(lhs)
    }

    /// Runs a command-line tool off the main actor and returns its stdout.
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: UpdateError(
                        "\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }
    let tagName: String
    let htmlUrl: URL
    let body: String?
    let assets: [Asset]
}
