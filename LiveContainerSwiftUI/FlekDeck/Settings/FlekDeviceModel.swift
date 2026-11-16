//
//  FlekDeviceModel.swift
//  LiveContainerSwiftUI
//
//  Which iPhone or iPad this is, by the identifier the system gives for its
//  model, "iPhone16,1": for the iPhone Duo, whose displays and status bar ask
//  for a layout of their own, and for telling an iPad from an iPhone.
//

import UIKit

enum FlekDeviceModel {
    /// The model's identifier, such as "iPhone16,1". In the Simulator, the
    /// one of the device simulated: the system call there names the Mac.
    static let identifier: String = {
#if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
#endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { machine in
            String(decoding: machine.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    static var isPad: Bool {
        identifier.hasPrefix("iPad") || UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Whether this is an iPhone Duo, whose status bar runs down one side of
    /// the display rather than across the top.
    static var isDuo: Bool { identifier == "iPhone19,4" }

    /// The iPhone Duo's two displays: the cover display it has folded, and the
    /// inner one it opens up to.
    enum DuoDisplay {
        case cover, inner
    }

    /// Which of the iPhone Duo's displays `screen` is; nil on any other phone.
    /// Told apart by their size held upright: the cover display is 466 × 678
    /// points, the inner one 669 × 951.
    static func duoDisplay(of screen: UIScreen) -> DuoDisplay? {
        guard isDuo else { return nil }
        let size = screen.fixedCoordinateSpace.bounds.size
        func matches(_ width: CGFloat, _ height: CGFloat) -> Bool {
            abs(size.width - width) < 1 && abs(size.height - height) < 1
        }
        if matches(466, 678) { return .cover }
        if matches(669, 951) { return .inner }
        return nil
    }

    /// Quarter-turns `screen` is mounted at against the phone itself, counted the
    /// way `UIInterfaceOrientation` turns are: a phone held upright with its
    /// interface the right way up to the user reads as this many turns.
    ///
    /// None on any display but the iPhone Duo's inner one, which is mounted on its
    /// side: held upright and open, its interface is `.landscapeLeft` while the
    /// phone itself reads as portrait, and the picture is the right way up all
    /// the same.
    static func displayMountingSteps(of screen: UIScreen) -> Int {
        duoDisplay(of: screen) == .inner ? 1 : 0
    }

    /// What stands in for the multitask bar while it is down, until a choice is
    /// made under Multitask Control in Settings: the bottom swipe, except on an
    /// iPhone Duo, which starts with the floating button.
    static var usesBottomSwipeByDefault: Bool { !isDuo }
}
