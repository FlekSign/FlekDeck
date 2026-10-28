//
//  FlekJITSetup.swift
//  LiveContainerSwiftUI
//
//  Whether JIT can be enabled as things stand, asked before an app set to
//  launch with JIT is started. A guest enables JIT for itself as it launches,
//  so one started without a working setup fails there, and all the user gets
//  is an error the next time FlekDeck opens. Asked first, the same thing is a
//  warning that says where JIT is set up, and the app is not started.
//

import Network
import SwiftUI

/// What built-in JIT needs that can be told without trying to enable it.
enum FlekBuiltInJIT {
    /// Why built-in JIT cannot work in this copy of FlekDeck whatever the user
    /// sets up, or nil. Read once: none of it changes while the app runs.
    static let blocker: String? = {
#if targetEnvironment(simulator)
        return "lc.flek.jit.blocker.simulator".loc
#else
        guard #available(iOS 17.4, *) else {
            return "lc.flek.jit.blocker.os".loc
        }
        guard LCUtils.isBuiltInJITLoadable() else {
            return "lc.flek.jit.blocker.unavailable".loc
        }
        // A debugger only attaches to a process signed with get-task-allow, and
        // the signature is whatever this copy was last signed with. A guest
        // runs in LiveProcess when in a window, in the app itself otherwise.
        let liveProcess = Bundle.main.builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex/LiveProcess").path
        for executable in [Bundle.main.executablePath, liveProcess] {
            if let executable, let entitlements = FlekSignature.entitlements(ofExecutableAt: executable),
               entitlements["get-task-allow"] as? Bool != true {
                return "lc.flek.jit.blocker.entitlement".loc
            }
        }
        return nil
#endif
    }()

    /// Starts a copy that has never had an enabler chosen on built-in JIT, the
    /// one enabler that needs nothing outside FlekDeck. What it would start on
    /// otherwise, upstream's default, wants a server on a computer, and its
    /// address and a UDID are the first thing the JIT page then asks for.
    /// A copy with such an address filled in is left as it is.
    static func adoptWhereNothingIsChosen() {
        let defaults = LCUtils.appGroupUserDefault
        guard defaults.object(forKey: "LCJITEnablerType") == nil,
              (defaults.string(forKey: "LCSideJITServerAddress") ?? "").isEmpty,
              #available(iOS 17.4, *),
              // By its file rather than by loading it, which this is too early for.
              let frameworks = Bundle.main.privateFrameworksURL,
              FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("StikJITHeadless.framework/StikJITHeadless").path) else {
            return
        }
        defaults.set(JITEnablerType.StikJITHeadless.rawValue, forKey: "LCJITEnablerType")
    }

    static var hasPairingFile: Bool {
        (try? LCPath.pairingFilePath.checkResourceIsReachable()) ?? false
    }

    /// Whether a pairing file, read as a property list, holds a RemotePairing
    /// record, which is the one StikJIT connects with. A pairing file made by
    /// an older tool holds only a lockdown record.
    static func isUsablePairingFile(_ file: [String: Any]) -> Bool {
        file["public_key"] is Data && file["private_key"] is Data && file["identifier"] is String
    }

    /// Keeps `data` as the pairing file, if it is one built-in JIT can use.
    /// One that is not would otherwise fail much later, at an app's launch,
    /// with an error that says nothing about the file.
    static func storePairingFile(_ data: Data) throws {
        guard let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              isUsablePairingFile(file) else {
            throw "lc.flek.jit.pairingFile.wrongKind".loc
        }
        let destination = LCPath.pairingFilePath
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// What a pairing file made on this device carries besides its record.
    static let madeOnDeviceKey = "created_on_device"

    /// Whether the pairing file was made on this device rather than imported,
    /// for saying which. The file says so itself: a note of it kept anywhere
    /// else would be lost, or left behind, the moment the file is copied out
    /// and imported again.
    static var isPairingFileMadeOnDevice: Bool {
        guard let data = try? Data(contentsOf: LCPath.pairingFilePath),
              let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return record[madeOnDeviceKey] as? Bool == true
    }

    /// Whether anything answers at the address a VPN gives this device, which
    /// is the only way to tell that LocalDevVPN is connected: another app's VPN
    /// cannot be asked about.
    static func isDeviceReachable(within timeout: TimeInterval = 0.7) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "10.7.0.1", port: 49152, using: .tcp)
            let answer = OneAnswer<Bool> { isReachable in
                connection.cancel()
                continuation.resume(returning: isReachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: answer.give(true)
                case .failed, .cancelled: answer.give(false)
                default: break
                }
            }
            let queue = DispatchQueue.global(qos: .userInitiated)
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                answer.give(false)
            }
        }
    }

    /// What the device is connected through, which decides whether JIT can be
    /// started. iOS takes the connection built-in JIT makes through the VPN
    /// while the device is on Wi-Fi or on nothing at all, as in Airplane Mode
    /// or with Mobile Data switched off, and never while it is on mobile
    /// data, which it takes the VPN to be part of. And a VPN cannot start on
    /// nothing, though one that is on stays on. So away from Wi-Fi the order
    /// is: the VPN on, then Airplane Mode on or Mobile Data off. Found on a
    /// device with iOS 27, and what StikJIT's guide says of Airplane Mode.
    enum Connection {
        case wifi
        case mobileData
        /// No connection at all, as in Airplane Mode.
        case offline
    }

    /// Asked only to explain a device that does not answer through the VPN.
    /// Nil where it cannot be told.
    static func connection() async -> Connection? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answer = OneAnswer<Connection?> { connection in
                monitor.cancel()
                continuation.resume(returning: connection)
            }
            monitor.pathUpdateHandler = { path in
                if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                    answer.give(.wifi)
                } else if path.usesInterfaceType(.cellular) {
                    answer.give(.mobileData)
                } else if path.status == .satisfied {
                    answer.give(nil)
                } else {
                    answer.give(.offline)
                }
            }
            let queue = DispatchQueue.global(qos: .userInitiated)
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.5) {
                answer.give(nil)
            }
        }
    }

    /// Passes on the first answer it is given and drops the rest: the
    /// connection and the timeout both give one.
    private final class OneAnswer<Answer>: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((Answer) -> Void)?

        init(_ handler: @escaping (Answer) -> Void) {
            self.handler = handler
        }

        func give(_ answer: Answer) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(answer)
        }
    }
}

enum FlekJITSetup {
    /// JIT cannot be enabled as things stand, with what to tell the user.
    struct NotReady: LocalizedError {
        var title = "lc.flek.jit.notReady.title".loc
        let message: String
        /// What to say instead where the launch is kept and started once the
        /// connection has changed, which is then all that is missing. Nil
        /// where something else is.
        var messageWhileWaiting: String?
        /// The device is on mobile data with FlekDeck's own VPN on, so that
        /// Mobile Data off is all that is missing, which the FlekJIT shortcut
        /// can see to (FlekMobileDataShortcut).
        var isOverMobileData = false
        var errorDescription: String? { message }
    }

    /// Says when what the device is connected through has changed, for a
    /// launch that waits on it: asked for Wi-Fi or Airplane Mode, the user
    /// changes it in Control Center or in Settings, and the app is to start
    /// when they have.
    final class ConnectionWatch {
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "FlekJITSetup.ConnectionWatch")
        private var hasSeenFirst = false

        init(onChange: @escaping @MainActor () -> Void) {
            monitor.pathUpdateHandler = { [weak self] _ in
                guard let self else { return }
                // The first is the connection as it is, not a change of it.
                guard self.hasSeenFirst else {
                    self.hasSeenFirst = true
                    return
                }
                Task { @MainActor in onChange() }
            }
            monitor.start(queue: queue)
        }

        deinit {
            monitor.cancel()
        }
    }

    /// Where the setup stands, for showing it outside its own page.
    enum Standing: Equatable {
        case notStarted
        /// Some of its three steps are done, this many.
        case underWay(stepsDone: Int)
        case ready
        /// This copy cannot use built-in JIT, for the reason given.
        case unavailable(String)
        /// Another enabler is chosen, named here. Whether that one is ready
        /// cannot be told from FlekDeck.
        case external(String)
    }

    /// The steps counted here are the built-in section's first three; the
    /// fourth, choosing apps, is use rather than setup.
    @MainActor
    static var standing: Standing {
        let shared = LCUtils.appGroupUserDefault
        let enabler = JITEnablerType(rawValue: shared.integer(forKey: "LCJITEnablerType")) ?? .SideJITServer
        switch enabler {
        case .StikJITHeadless:
            break
        case .SideJITServer:
            // What an older copy starts on, with nothing filled in.
            let address = shared.string(forKey: "LCSideJITServerAddress") ?? ""
            let udid = shared.string(forKey: "LCDeviceUDID") ?? ""
            return address.isEmpty || udid.isEmpty ? .notStarted : .external(enabler.displayName)
        default:
            return .external(enabler.displayName)
        }
        // Another FlekDeck uses the primary one's setup, none of which it can
        // see, so it says nothing of it.
        guard DataManager.shared.model.multiLCStatus == 0 else {
            return .notStarted
        }
        if let blocker = FlekBuiltInJIT.blocker {
            return .unavailable(blocker)
        }
        let hasFile = FlekBuiltInJIT.hasPairingFile
        // As the VPN's model last found it, which it notes for guests.
        let hasVPN = shared.bool(forKey: "LCBuiltInVPNConfigured")
        guard hasFile || hasVPN else {
            return .notStarted
        }
        let steps = [
            hasFile,
            // Another app's VPN where FlekDeck has none, and not to be seen.
            hasVPN || !FlekLoopbackVPN.isAvailable,
            hasFile && UserDefaults.standard.double(forKey: "FlekJITReadyAt") > 0,
        ]
        let done = steps.filter { $0 }.count
        return done == steps.count ? .ready : .underWay(stepsDone: done)
    }

    /// Throws `NotReady` where starting an app with JIT would only fail.
    @MainActor
    static func ensureReady() async throws {
        // Installed with TrollStore, an app has JIT from the start, and no
        // enabler is asked for it whatever is chosen here.
        if access("\(Bundle.main.bundlePath)/../_TrollStore", F_OK) == 0 {
            return
        }
        let defaults = LCUtils.appGroupUserDefault
        guard let enabler = JITEnablerType(rawValue: defaults.integer(forKey: "LCJITEnablerType")) else {
            return
        }
        switch enabler {
        case .StikJITHeadless:
            try await ensureBuiltInReady()
        case .SideJITServer:
            // What a fresh install is set to, with nothing filled in.
            let address = defaults.string(forKey: "LCSideJITServerAddress") ?? ""
            let udid = defaults.string(forKey: "LCDeviceUDID") ?? ""
            if address.isEmpty || udid.isEmpty {
                throw NotReady(message: "lc.flek.jit.notReady.setUp".loc)
            }
        default:
            // Another app enables JIT, and whether it will cannot be told here.
            return
        }
    }

    @MainActor
    private static func ensureBuiltInReady() async throws {
        if let blocker = FlekBuiltInJIT.blocker {
            throw NotReady(message: blocker)
        }
        // Another FlekDeck uses the primary one's pairing file, which it
        // cannot see.
        if DataManager.shared.model.multiLCStatus == 0, !FlekBuiltInJIT.hasPairingFile {
            throw NotReady(message: "lc.flek.jit.notReady.setUp".loc)
        }
        let vpn = FlekLoopbackVPN.shared
        if FlekLoopbackVPN.isAvailable {
            await vpn.refresh()
            if vpn.isConfigured {
                do {
                    try await vpn.connect()
                } catch {
                    // On no connection at all a VPN cannot start, and needs
                    // one for a moment.
                    if await FlekBuiltInJIT.connection() == .offline {
                        throw connectionNotReady("lc.flek.jit.notReady.offline")
                    }
                    throw NotReady(message: "lc.flek.jit.notReady.vpn".loc)
                }
                // With the VPN up the device still does not answer over mobile
                // data, and a launch would end in the helper's timeout, which
                // asks about the VPN. The VPN is left on, so that Airplane
                // Mode is all that is still needed. Not answering for another
                // reason is left to the launch, as it was.
                if !(await FlekBuiltInJIT.isDeviceReachable()), await FlekBuiltInJIT.connection() == .mobileData {
                    var notReady = connectionNotReady("lc.flek.jit.notReady.mobileData")
                    notReady.isOverMobileData = true
                    throw notReady
                }
                return
            }
        }
        // No VPN of FlekDeck's own, which leaves LocalDevVPN.
        if !(await FlekBuiltInJIT.isDeviceReachable()) {
            if FlekLoopbackVPN.isAvailable {
                throw NotReady(message: "lc.flek.jit.notReady.setUp".loc)
            }
            // Whether LocalDevVPN is connected cannot be told, so over mobile
            // data both it and Airplane Mode are asked for, in their order.
            if await FlekBuiltInJIT.connection() == .mobileData {
                throw connectionNotReady("lc.flek.jit.notReady.mobileData.other")
            }
            throw NotReady(message: "lc.flek.jit.notReady.vpn".loc)
        }
    }

    /// Not ready for what the device is connected through, which the user is
    /// about to change: said one way where they are to try again, and another
    /// where the app starts by itself once they have.
    private static func connectionNotReady(_ key: String) -> NotReady {
        NotReady(message: key.loc, messageWhileWaiting: "\(key).waiting".loc)
    }

}
