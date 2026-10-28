//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    // Registration runs on whichever queue the extension request completes on,
    // while unregistration and the queries run on the main thread. Mutating a
    // Swift array from two threads at once corrupts it, so every access to the
    // list goes through this lock.
    static private let lock = NSLock()

    @objc class func registerMultitaskContainer(container: String) {
        lock.lock()
        defer { lock.unlock() }
        usingMultitaskContainers.append(container)
    }

    @objc class func unregisterMultitaskContainer(container: String) {
        lock.lock()
        defer { lock.unlock() }
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
    }

    @objc class func isUsing(container: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }

    @objc class func isMultitasking() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingMultitaskContainers.count > 0
    }

    static private var flushObservers: [NSObjectProtocol] = []

    /// Tells the windows' guests to write out their preferences and cookies
    /// whenever FlekDeck leaves the foreground. From there iOS may end FlekDeck
    /// without warning — swiped away, or its memory reclaimed — and the windows'
    /// processes die with it, taking whatever they had not yet written. Leaving
    /// the foreground comes first every time, so it is the last sure moment.
    /// Posted whether or not a window is known to be open: it costs nothing when
    /// no guest is listening, and a guest missing from the list would lose out.
    @objc class func beginFlushingGuestsWhenBackgrounded() {
        guard flushObservers.isEmpty else { return }
        let names = [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification]
        flushObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                LCSharedUtils.requestGuestFlush()
            }
        }
    }
}
