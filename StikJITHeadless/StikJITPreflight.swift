//
//  StikJITPreflight.swift
//  StikJITHeadless
//

import Foundation
import StikJIT

/// What Settings runs to tell whether built-in JIT can work right now. Nothing
/// here attaches to a process, so unlike the JIT session itself it can run in
/// the app rather than in a helper.
@objc(StikJITPreflight) public class StikJITPreflight: NSObject {
    // The codes of the errors `prepareDevice` returns. The app tells them apart
    // by number, since it does not link this framework.
    /// Nothing answered at the device's address.
    private static let unreachableCode = 1
    /// The device answered but is not ready.
    private static let preparationFailedCode = 2

    /// Nil once the device is reachable and its developer disk image is
    /// mounted. `progress` gets a stage (0 reachability, 1 checking the image,
    /// 2 downloading, 3 mounting, 4 verifying, 5 ready) and, where the stage
    /// has one, how far along it is; otherwise a negative fraction.
    @objc(prepareDeviceWithPairingFile:ddiPath:timeout:progress:)
    public static func prepareDevice(pairingFile: URL, ddiPath: URL, timeout: TimeInterval,
                                     progress: @escaping (Int, Double) -> Void) -> NSError? {
        let config = StikJIT.Configuration(connectionTimeout: timeout)
        let readiness = StikJIT.prepareDevice(pairingFile: pairingFile, paths: DDIPaths.default(in: ddiPath),
                                              configuration: config) { stage in
            switch stage {
            case .checkingReachability: progress(0, -1)
            case .checkingDDI: progress(1, -1)
            case .downloadingDDI(let fraction, _): progress(2, fraction)
            case .mountingDDI(let fraction): progress(3, fraction)
            case .verifyingDDI: progress(4, -1)
            case .ready: progress(5, 1)
            @unknown default: break
            }
        }
        switch readiness {
        case .ready:
            return nil
        case .unreachable(let reason):
            return error(code: unreachableCode, reason)
        case .preparationFailed(let reason):
            return error(code: preparationFailedCode, reason)
        @unknown default:
            return error(code: preparationFailedCode, "Unknown state")
        }
    }

    /// Drops the cached developer disk image, so the next preparation downloads
    /// it again.
    @objc(resetCachedDDIAt:)
    public static func resetCachedDDI(at ddiPath: URL) -> NSError? {
        do {
            try StikJIT.resetCachedDDI(at: DDIPaths.default(in: ddiPath))
            return nil
        } catch {
            return self.error(code: preparationFailedCode, error.localizedDescription)
        }
    }

    private static func error(code: Int, _ reason: String) -> NSError {
        NSError(domain: "StikJIT", code: code, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
