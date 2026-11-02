import ChargeCore
import Foundation
import SMCKit
import os
import ServiceManagement

let appLog = Logger(subsystem: HelperConstants.appBundleID, category: "app")

enum HelperStatus: Equatable {
    case notInstalled
    case requiresApproval
    case connecting
    case ready(version: String)
    case failed(String)

    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// Registers the daemon with SMAppService and talks to it over a privileged,
/// signature-checked NSXPCConnection. All calls are exposed as async/throws.
final class HelperClient: NSObject, BatteryHelperClientProtocol, @unchecked Sendable {
    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// Called on the main queue when the helper overrides hardware state on its own.
    var onSafetyOverride: ((String) -> Void)?

    // MARK: Registration (SMAppService, macOS 13+)

    var registrationStatus: SMAppService.Status { service.status }

    /// Registers the LaunchDaemon embedded in Contents/Library/LaunchDaemons.
    /// The first time, macOS asks the user to approve it in
    /// System Settings › General › Login Items & Extensions; until then the
    /// status is `.requiresApproval` and the Mach service can't be reached.
    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        invalidate()
        try await service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    // MARK: Typed calls

    func version() async throws -> String {
        try await call { proxy, done in proxy.helperVersion { done(.success($0)) } }
    }

    func capabilities() async throws -> ChargeCapabilities {
        let data: Data = try await call { proxy, done in
            proxy.capabilities { data, error in
                if let error { return done(.failure(error)) }
                done(data.map(Result.success) ?? .failure(HelperErrorCode.smcFailure.error("Empty capabilities")))
            }
        }
        return try JSONDecoder().decode(ChargeCapabilities.self, from: data)
    }

    func setCharging(_ enabled: Bool) async throws {
        try await call { proxy, done in proxy.setChargingEnabled(enabled) { done(Self.result($0)) } }
    }

    func setAdapter(_ enabled: Bool) async throws {
        try await call { proxy, done in proxy.setAdapterEnabled(enabled) { done(Self.result($0)) } }
    }

    func setHardwareLimit(_ percent: Int) async throws {
        try await call { proxy, done in proxy.setHardwareChargeLimit(percent) { done(Self.result($0)) } }
    }

    func heartbeat() async throws {
        try await call { proxy, done in proxy.heartbeat { done(.success(())) } }
    }

    func restoreDefaults() async throws {
        try await call { proxy, done in proxy.restoreDefaults { done(Self.result($0)) } }
    }

    /// Synchronous variant for applicationWillTerminate, bounded by `timeout`.
    func restoreDefaultsBlocking(timeout: TimeInterval = 2) {
        let semaphore = DispatchSemaphore(value: 0)
        let proxy = currentConnection().remoteObjectProxyWithErrorHandler { _ in semaphore.signal() }
        (proxy as? BatteryHelperProtocol)?.restoreDefaults { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    // MARK: BatteryHelperClientProtocol (helper -> app)

    func helperDidApplySafetyOverride(_ reason: String) {
        DispatchQueue.main.async { self.onSafetyOverride?(reason) }
    }

    // MARK: Private

    private static func result(_ error: NSError?) -> Result<Void, Error> {
        error.map { .failure($0) } ?? .success(())
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }

        // .privileged: look the service up in the system (root) launchd domain.
        let new = NSXPCConnection(machServiceName: HelperConstants.helperLabel, options: .privileged)
        new.remoteObjectInterface = .batteryHelper
        new.exportedInterface = .batteryHelperClient
        new.exportedObject = self

        // Validate the daemon too: we only talk to our own team-signed helper.
        if let requirement = CodeSigning.requirement(forPeer: HelperConstants.helperLabel) {
            new.setCodeSigningRequirement(requirement)
        }

        new.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.connection === new { self.connection = nil }
            self.lock.unlock()
        }
        new.interruptionHandler = { appLog.notice("Helper connection interrupted; launchd will relaunch it on the next call") }
        new.resume()
        connection = new
        return new
    }

    /// Bridges one XPC request to async/await, resuming exactly once whether the
    /// reply block or the connection error handler fires.
    private func call<T>(_ body: @escaping (BatteryHelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
            }
            guard let helper = proxy as? BatteryHelperProtocol else {
                return once.resume(.failure(HelperErrorCode.smcFailure.error("Bad XPC proxy")))
            }
            body(helper) { once.resume($0) }
        }
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
