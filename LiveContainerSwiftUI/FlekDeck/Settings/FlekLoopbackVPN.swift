//
//  FlekLoopbackVPN.swift
//  LiveContainerSwiftUI
//
//  The app's side of FlekDeck's own VPN, the one built-in JIT connects through;
//  LoopbackTunnelProvider says what the VPN does and why JIT needs it. Here are
//  the configuration iOS asks the user to allow, and turning the VPN on and off
//  from Settings.
//
//  A guest's launch turns it on without any of this, through
//  LCSharedUtils.startBuiltInVPN, which goes by the flag kept here.
//

@preconcurrency import NetworkExtension

/// What an executable of this app was last signed with.
enum FlekSignature {
    /// Nil where the signature could not be read, which rules nothing out: a
    /// Simulator build keeps its entitlements elsewhere.
    static func entitlements(ofExecutableAt path: String) -> [String: Any]? {
        guard let xml = getExecutableEntitlementXML(path) else {
            return nil
        }
        return try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
    }
}

@MainActor
final class FlekLoopbackVPN: ObservableObject {
    static let shared = FlekLoopbackVPN()

    /// Whether this copy of FlekDeck can provide the VPN at all. It takes the
    /// extension, which some installers leave out, and the Network Extensions
    /// entitlement on both the app and the extension, which is up to whatever
    /// signed this copy. Read once: none of it changes while the app runs.
    static let isAvailable: Bool = {
#if targetEnvironment(simulator)
        return false
#else
        guard let tunnel = extensionBundle?.executablePath, let app = Bundle.main.executablePath else {
            return false
        }
        return [app, tunnel].allSatisfy { executable in
            guard let entitlements = FlekSignature.entitlements(ofExecutableAt: executable) else {
                return true
            }
            let providers = entitlements["com.apple.developer.networking.networkextension"] as? [String]
            return providers?.contains("packet-tunnel-provider") == true
        }
#endif
    }()

    /// Read from the bundle: a re-signed copy has its own bundle IDs.
    private static var extensionBundle: Bundle? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("LoopbackVPN.appex")) }
    }

    /// Whether the user has allowed the VPN configuration.
    @Published private(set) var isConfigured = false
    @Published private(set) var status = NEVPNStatus.invalid

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// On, or on its way there.
    var isOn: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    /// Finds the configuration again: it is kept by iOS, not by the app.
    func refresh() async {
        // An app is only ever given its own configurations, and FlekDeck has
        // the one.
        adopt((try? await NETunnelProviderManager.loadAllFromPreferences())?.first)
    }

    /// Adds the configuration, which is when iOS asks the user to allow it.
    func setUp() async throws {
        guard let provider = Self.extensionBundle?.bundleIdentifier else {
            throw "lc.flek.jit.vpn.didNotStart".loc
        }
        let manager = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = provider
        // Shown in Settings where another VPN names its server.
        tunnel.serverAddress = "lc.flek.jit.vpn.server".loc
        manager.protocolConfiguration = tunnel
        // The name it goes by in the Settings app, among other apps' VPNs.
        manager.localizedDescription = "FlekDeck"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // What was saved cannot be started until it has been read back.
        try await manager.loadFromPreferences()
        adopt(manager)
    }

    /// Turns the VPN on and returns once it is up.
    func connect() async throws {
        guard let manager else {
            throw "lc.flek.jit.vpn.didNotStart".loc
        }
        if !manager.isEnabled {
            // Another VPN has been chosen in Settings since, and iOS only
            // starts the chosen one.
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        if manager.connection.status != .connected {
            try manager.connection.startVPNTunnel()
        }
        // It is up within a second as a rule.
        for _ in 0..<50 where manager.connection.status != .connected {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        status = manager.connection.status
        guard status == .connected else {
            throw "lc.flek.jit.vpn.didNotStart".loc
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    func remove() async throws {
        try await manager?.removeFromPreferences()
        adopt(nil)
    }

    private func adopt(_ manager: NETunnelProviderManager?) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = nil
        self.manager = manager
        isConfigured = manager != nil
        status = manager?.connection.status ?? .invalid
        // What a guest's launch goes by when it turns the VPN on.
        LCUtils.appGroupUserDefault.set(isConfigured, forKey: "LCBuiltInVPNConfigured")
        guard let manager else {
            return
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] notification in
            guard let status = (notification.object as? NEVPNConnection)?.status else {
                return
            }
            Task { @MainActor in
                self?.status = status
            }
        }
    }
}
