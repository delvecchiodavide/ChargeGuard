import ChargeCore
import Foundation
import os
import SMCKit

let log = Logger(subsystem: HelperConstants.helperLabel, category: "helper")

/// Owns the XPC listener, validates clients, serializes SMC access and runs
/// the safety watchdog.
final class HelperService: NSObject, NSXPCListenerDelegate, BatteryHelperProtocol {
    private let listener = NSXPCListener(machServiceName: HelperConstants.helperLabel)
    private let queue = DispatchQueue(label: "\(HelperConstants.helperLabel).smc")
    private let controller: ChargeController?
    private let controllerError: String?
    private let telemetry = BatteryTelemetry(smc: nil)

    private var connections: [NSXPCConnection] = []
    /// Uptime clock: it stops during system sleep, so a sleeping Mac never looks like a crashed app.
    private var lastHeartbeat = DispatchTime.now()
    private var watchdog: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var binaryWatcher: DispatchSourceFileSystemObject?

    override init() {
        do {
            controller = try ChargeController()
            controllerError = nil
        } catch {
            controller = nil
            controllerError = "\(error)"
            log.fault("Cannot open AppleSMC: \(String(describing: error), privacy: .public)")
        }
        super.init()
    }

    func start() {
        guard geteuid() == 0 else {
            log.fault("Helper must run as root (launched by launchd via SMAppService)")
            exit(EXIT_FAILURE)
        }

        // Kernel-enforced client validation: XPC checks the peer's signature on
        // every message, so a process can't pass the check and then exec() into
        // something else (the classic PID-reuse attack on helper tools).
        if let requirement = CodeSigning.requirement(forPeer: HelperConstants.appBundleID) {
            listener.setConnectionCodeSigningRequirement(requirement)
            log.info("Client requirement: \(requirement, privacy: .public)")
        } else {
            #if DEBUG
            log.error("Helper is not team-signed; accepting any client because this is a DEBUG build")
            #else
            log.fault("Helper is not team-signed; refusing to serve clients")
            exit(EXIT_FAILURE)
            #endif
        }

        listener.delegate = self
        listener.resume()
        startWatchdog()
        installSignalHandlers()
        watchOwnBinary()
        log.info("ChargeGuard helper \(HelperConstants.helperVersion, privacy: .public) listening")
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = .batteryHelper
        connection.exportedObject = self
        connection.remoteObjectInterface = .batteryHelperClient
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.queue.async { self.connections.removeAll { $0 === connection } }
        }
        queue.sync {
            connections.append(connection)
            lastHeartbeat = DispatchTime.now()
        }
        connection.resume()
        log.info("Accepted client pid \(connection.processIdentifier)")
        return true
    }

    // MARK: BatteryHelperProtocol

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    func capabilities(reply: @escaping (Data?, NSError?) -> Void) {
        guard let controller else { return reply(nil, unavailableError()) }
        reply(try? JSONEncoder().encode(controller.capabilities), nil)
    }

    func setChargingEnabled(_ enabled: Bool, reply: @escaping (NSError?) -> Void) {
        perform(reply) { try $0.setCharging(enabled: enabled) }
    }

    func setAdapterEnabled(_ enabled: Bool, reply: @escaping (NSError?) -> Void) {
        perform(reply) { controller in
            if !enabled && self.batteryPercent() <= ChargePolicy.hardFloorPercent {
                throw HelperErrorCode.invalidArgument.error("Battery too low to disable the adapter.")
            }
            try controller.setAdapter(enabled: enabled)
        }
    }

    func setHardwareChargeLimit(_ percent: Int, reply: @escaping (NSError?) -> Void) {
        perform(reply) { try $0.setHardwareLimit(percent) }
    }

    func heartbeat(reply: @escaping () -> Void) {
        queue.async { self.lastHeartbeat = DispatchTime.now() }
        reply()
    }

    func restoreDefaults(reply: @escaping (NSError?) -> Void) {
        perform(reply) { controller in
            if let first = controller.restoreDefaults().first { throw first }
        }
    }

    // MARK: Private

    private func perform(_ reply: @escaping (NSError?) -> Void,
                         _ body: @escaping (ChargeController) throws -> Void) {
        guard let controller else { return reply(unavailableError()) }
        queue.async {
            self.lastHeartbeat = DispatchTime.now()
            do {
                try body(controller)
                reply(nil)
            } catch let error as NSError {
                reply(error)
            }
        }
    }

    private func unavailableError() -> NSError {
        HelperErrorCode.smcFailure.error("AppleSMC unavailable: \(controllerError ?? "unknown")")
    }

    private func batteryPercent() -> Int {
        telemetry.read().osPercent
    }

    /// Every 30 s: protects the battery even if the app has crashed or hung.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    private func watchdogTick() {
        guard let controller, !controller.isAtDefaults else { return }

        if !controller.adapterEnabled && batteryPercent() <= ChargePolicy.hardFloorPercent {
            try? controller.setAdapter(enabled: true)
            notifyClients("Battery reached \(ChargePolicy.hardFloorPercent) %: adapter re-enabled.")
        }

        let silence = Double(DispatchTime.now().uptimeNanoseconds - lastHeartbeat.uptimeNanoseconds) / 1e9
        if silence > HelperConstants.orphanTimeout {
            controller.restoreDefaults()
            notifyClients("No heartbeat from the app: normal charging restored.")
            log.notice("Orphan watchdog restored defaults")
        }
    }

    private func notifyClients(_ reason: String) {
        for connection in connections {
            (connection.remoteObjectProxy as? BatteryHelperClientProtocol)?.helperDidApplySafetyOverride(reason)
        }
    }

    /// launchd sends SIGTERM when the daemon is unregistered or the system shuts down:
    /// never leave the Mac with charging inhibited or the adapter disabled.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                self?.controller?.restoreDefaults()
                log.notice("Signal \(sig): defaults restored, exiting")
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// When the app is updated, our executable on disk is replaced while this process keeps
    /// running the old code. The app validates the helper against the file on disk, so it would
    /// refuse every reply. Exit instead: launchd starts the new binary on the next connection.
    private func watchOwnBinary() {
        let fd = open(Bundle.main.executablePath ?? CommandLine.arguments[0], O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.delete, .rename, .write],
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            self?.controller?.restoreDefaults()
            log.notice("Helper binary replaced on disk: defaults restored, exiting for relaunch")
            exit(EXIT_SUCCESS)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        binaryWatcher = source
    }
}
