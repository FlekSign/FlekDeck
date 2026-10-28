//
//  FlekKeepAwake.swift
//  LiveContainerSwiftUI
//
//  Keeps the screen from locking by itself while something in FlekDeck is
//  waiting on the user to watch it: an install, or a payment being
//  confirmed. iOS has one switch for this, the idle timer, so each reason
//  is held here, and the timer is off while any is.
//
//  Only the automatic lock is held off. A press of the side button still
//  locks the phone, and nothing here keeps work running in the background.
//  On the main thread.
//

import UIKit

enum FlekKeepAwake {
    enum Reason: Hashable {
        /// A download or install is under way.
        case installs
    }

    private static var reasons = Set<Reason>()

    static func set(_ isNeeded: Bool, for reason: Reason) {
        if isNeeded {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        let isIdleTimerDisabled = !reasons.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != isIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = isIdleTimerDisabled
        }
    }
}
