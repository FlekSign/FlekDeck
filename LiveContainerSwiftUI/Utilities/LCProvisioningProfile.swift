//
//  LCProvisioningProfile.swift
//  LiveContainerSwiftUI
//
//  What FlekDeck reads out of a .mobileprovision file: enough to check a
//  profile against the certificate imported with it. FlekDeck signs apps with
//  the certificate alone and never embeds a profile, so nothing else is kept.
//

import Foundation

struct LCProvisioningProfile {
    let name: String
    let teamID: String
    let expirationDate: Date?
    /// Whether this is a development profile. `get-task-allow` lets a debugger
    /// attach, which development profiles grant and distribution ones never do.
    let isDevelopment: Bool

    init?(data: Data) {
        // A profile is an XML plist inside a CMS signature. The plist is stored
        // unencrypted, so it can be cut out between its own markers — iOS has
        // no public API for opening the envelope itself.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let teamID = (plist["TeamIdentifier"] as? [String])?.first
        else { return nil }
        self.name = plist["Name"] as? String ?? ""
        self.teamID = teamID
        self.expirationDate = plist["ExpirationDate"] as? Date
        let entitlements = plist["Entitlements"] as? [String: Any]
        self.isDevelopment = entitlements?["get-task-allow"] as? Bool ?? false
    }

    var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }
}

extension LCProvisioningProfile {
    /// The profile this FlekDeck was installed with. iOS installs a sideloaded
    /// app only when its embedded profile covers the certificate that signed
    /// it, so the profile's kind is the certificate's. Nil for an install that
    /// has none, such as one through TrollStore.
    static let embedded: LCProvisioningProfile? = Bundle.main
        .url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { LCProvisioningProfile(data: $0) }

    /// Whether this FlekDeck is signed with a Development certificate, the only
    /// kind an imported certificate can launch apps under. Read from the
    /// embedded profile, or without one from the app's own get-task-allow,
    /// which only Development signing grants. The simulator checks no
    /// signatures at all, so it counts as Development.
    static let isAppDevelopmentSigned: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        if let embedded {
            return embedded.isDevelopment
        }
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil) else {
            return false
        }
        return (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false
        #endif
    }()
}
