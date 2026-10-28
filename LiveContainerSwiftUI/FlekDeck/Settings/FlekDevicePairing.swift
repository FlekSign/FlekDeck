//
//  FlekDevicePairing.swift
//  LiveContainerSwiftUI
//
//  The first step of the JIT setup done without a computer: FlekDeck makes the
//  pairing file itself, see LCDevicePairing.
//
//  The user's part of it is in the Settings app — picking FlekDeck under
//  Developer Mode and typing the code FlekDeck shows — so FlekDeck has to go on
//  running behind Settings, and to get the code in front of the user there.
//  Neither is to be had from one thing alone. A continued-processing task, as
//  installs use, keeps the app going and shows the code in its Live Activity,
//  but the system need not take it, and a Live Activity folded into the
//  Dynamic Island shows no text. So silence is played as well, which keeps an
//  app with the audio background mode running for as long as it plays, and the
//  code is also sent as a notification, which comes down over Settings.
//
//  What happens along the way is kept, a line each, and shown under Details in
//  the sheet: when this goes wrong it is on a device with no debugger attached.
//

import AVFoundation
import BackgroundTasks
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class FlekDevicePairing: ObservableObject {
    enum State: Equatable {
        case idle
        /// Advertised, and waiting for the user to pick FlekDeck in Settings.
        case waiting
        /// The device has connected and asks for this code.
        case askingForCode(String)
        case paired
        case failed(String)
    }

    /// A device only pairs with a host on its network from iOS 27, and the
    /// library that does the pairing is in device builds only.
    static var isSupported: Bool {
        if #available(iOS 27.0, *) {
            return LCDevicePairing.isAvailable
        }
        return false
    }

    @Published private(set) var state = State.idle
    /// Set once a try has failed, while the next one is awaited.
    @Published private(set) var hasFailedAttempt = false
    /// What has happened since the sheet came up, a line each with its time.
    @Published private(set) var events: [String] = []
    /// What FlekDeck goes by in Settings, where the user looks for it.
    static let hostName = "FlekDeck"
    /// Whether the code on show is on the clipboard as well, to be pasted
    /// where Settings asks for it.
    @Published private(set) var isCodeCopied = false

    private var pairing: LCDevicePairing?
    /// Counts the starts, so that what a pairing reports can be told from what
    /// one before it still had on its way.
    private var attempt = 0
    /// A `FlekPairingKeepAlive`, which only exists from iOS 26.
    private var keepAlive: AnyObject?
    private var watches = Set<AnyCancellable>()
    private var backgroundTime = UIBackgroundTaskIdentifier.invalid
    private var silence: AVAudioPlayer?
    /// What the audio session was set to before the silence, to put back.
    private var audioBefore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    /// Starts with nothing kept from before, for a sheet that has just come up.
    /// The pairing is started by whoever brings the sheet up and cancelled as
    /// the sheet is dismissed, not as its view appears and disappears, which a
    /// view may do more than once.
    func begin() {
        events.removeAll()
        start()
    }

    func start() {
        cancel()
        hasFailedAttempt = false
        state = .waiting

        let pairing = LCDevicePairing()
        self.pairing = pairing
        attempt += 1
        let attempt = attempt
        // A developer switch, for finding out whether a device pairs without
        // asking for a code.
        let withoutCode = UserDefaults.standard.bool(forKey: "FlekPairWithoutCode")
        note("Started on iOS \(UIDevice.current.systemVersion)" + (withoutCode ? ", without a code" : ""))
        // The blocks are called on the main queue, which the compiler has no
        // way to know, hence the hop onto the main actor in each. By the time
        // one gets there the pairing may have been cancelled, or replaced.
        pairing.start(withName: Self.hostName, withoutCode: withoutCode) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isCurrent(attempt) else {
                    return
                }
                self.note(event)
            }
        } onPIN: { [weak self] code in
            Task { @MainActor in
                guard let self, self.isCurrent(attempt) else {
                    return
                }
                // Whatever went wrong before is behind this try.
                self.hasFailedAttempt = false
                self.isCodeCopied = self.copy(code: code)
                self.note(self.isCodeCopied ? "Code shown, and copied" : "Code shown, not copied")
                self.state = .askingForCode(code)
                self.showBehindSettings(String(format: "lc.flek.jit.pair.activity.code %@".loc, code))
                self.notify(code: code)
            }
        } onAttemptFailed: { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(attempt) else {
                    return
                }
                self.hasFailedAttempt = true
                self.state = .waiting
                self.showBehindSettings("lc.flek.jit.pair.retry".loc)
                self.withdrawNotification()
            }
        } completion: { [weak self] file, error in
            Task { @MainActor in
                guard let self, self.isCurrent(attempt) else {
                    return
                }
                self.finish(file: file, error: error)
            }
        }
        keepRunningBehindSettings()
    }

    private func isCurrent(_ attempt: Int) -> Bool {
        attempt == self.attempt && pairing != nil
    }

    func cancel() {
        pairing?.cancel()
        pairing = nil
        endKeepAlive(success: false)
        state = .idle
    }

    private func finish(file: Data?, error: Error?) {
        pairing = nil
        guard let file else {
            note("Ended: " + (error?.localizedDescription ?? "no reason given"))
            state = .failed(Self.describe(error))
            endKeepAlive(success: false)
            return
        }
        do {
            let destination = LCPath.pairingFilePath
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.markedAsMadeOnDevice(file).write(to: destination, options: .atomic)
            note("Pairing file saved")
            state = .paired
            endKeepAlive(success: true)
        } catch {
            note("Pairing file not saved: " + error.localizedDescription)
            state = .failed(error.localizedDescription)
            endKeepAlive(success: false)
        }
    }

    /// Adds a line to what Details shows.
    func note(_ event: String) {
        events.append(Self.clock.string(from: Date()) + "  " + event)
        if events.count > 80 {
            events.removeFirst(events.count - 80)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The record with a note that it was made here, which is how a file made
    /// on the device is told from an imported one. What reads the record takes
    /// no notice of an entry it does not know.
    private static func markedAsMadeOnDevice(_ file: Data) throws -> Data {
        guard var record = try PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        record[FlekBuiltInJIT.madeOnDeviceKey] = true
        return try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
    }

    private static func describe(_ error: Error?) -> String {
        if let error = error as? LCDevicePairingError, error.code == .localNetworkDenied {
            return "lc.flek.jit.pair.localNetwork".loc
        }
        return error?.localizedDescription ?? ""
    }

    // MARK: Behind Settings

    private func keepRunningBehindSettings() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.wentBehind()
                }
            }
            .store(in: &watches)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.note("Back in front")
                }
            }
            .store(in: &watches)
        playSilence()
        askToNotify()
        guard #available(iOS 26.0, *) else {
            return
        }
        let (keepAlive, outcome) = FlekPairingKeepAlive.make(title: "lc.flek.jit.pair.activity.title".loc,
                                                             subtitle: "lc.flek.jit.pair.activity.waiting".loc)
        note("Background task: " + outcome)
        keepAlive?.onStarted = { [weak self] in
            self?.note("Background task: running")
        }
        // The system took the time back, or the user tapped Cancel in the Live
        // Activity. The pairing goes on for as long as the app does: it is the
        // sheet that ends it, and a try under way may yet go through.
        keepAlive?.onExpired = { [weak self] in
            self?.note("Background task: ended by the system")
            self?.keepAlive = nil
        }
        self.keepAlive = keepAlive
    }

    private func wentBehind() {
        // The half minute any app is given on leaving the foreground, asked for
        // each time FlekDeck leaves it: the least there is to go on.
        askForBackgroundTime()
        let allowed = UIApplication.shared.backgroundTimeRemaining
        note("Behind another app, " + (allowed < 3600 ? "\(Int(allowed)) s allowed" : "no limit given"))
    }

    private func showBehindSettings(_ text: String) {
        if #available(iOS 26.0, *) {
            (keepAlive as? FlekPairingKeepAlive)?.show(text)
        }
    }

    private func endKeepAlive(success: Bool) {
        watches.removeAll()
        giveBackBackgroundTime()
        stopSilence()
        withdrawNotification()
        if #available(iOS 26.0, *) {
            (keepAlive as? FlekPairingKeepAlive)?.end(success: success)
        }
        keepAlive = nil
    }

    private func askForBackgroundTime() {
        guard pairing != nil, backgroundTime == .invalid else {
            return
        }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Pairing") { [weak self] in
            // Out of time. The pairing stays as it is, and goes on from there
            // if the user comes back to FlekDeck.
            Task { @MainActor in
                self?.giveBackBackgroundTime()
            }
        }
    }

    private func giveBackBackgroundTime() {
        guard backgroundTime != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    // MARK: Silence

    /// An app that is playing audio is not suspended, which holds whether or
    /// not the system takes the task. What plays is silence, mixed in with
    /// whatever else is playing so that nothing is interrupted by it.
    private func playSilence() {
        guard silence == nil else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        let before = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentSound)
            player.numberOfLoops = -1
            player.volume = 0
            guard player.play() else {
                throw "would not play"
            }
            silence = player
            audioBefore = before
            note("Silence: playing")
        } catch {
            note("Silence: " + error.localizedDescription)
        }
    }

    private func stopSilence() {
        guard let silence else {
            return
        }
        silence.stop()
        self.silence = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let (category, mode, options) = audioBefore {
            try? session.setCategory(category, mode: mode, options: options)
        }
        audioBefore = nil
    }

    /// A second of nothing as a sound file: a header, then zeroes.
    private static let silentSound: Data = {
        let rate: UInt32 = 8000
        let samples = Data(count: Int(rate) * 2)
        var sound = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { sound.append(contentsOf: $0) }
        }
        sound.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        sound.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))          // The format chunk's length,
        append(UInt16(1))           // plain samples,
        append(UInt16(1))           // one channel,
        append(rate)
        append(rate * 2)            // bytes a second,
        append(UInt16(2))           // bytes a sample,
        append(UInt16(16))          // bits a sample.
        sound.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        sound.append(samples)
        return sound
    }()

    // MARK: Notification

    private static let codeNotification = "FlekPairingCode"

    /// Asks only where it has never been asked. Without it there is still the
    /// Live Activity, and the sheet.
    private func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The code on the clipboard, for pasting where Settings asks for it:
    /// there is no having it offered above the keyboard the way a code from a
    /// message is, which the system does for messages and mail only. Kept to
    /// this device and for a few minutes, as it is of no use after. Whether it
    /// took is told by the clipboard's count of changes, since an app behind
    /// another cannot read the clipboard back.
    private func copy(code: String) -> Bool {
        let clipboard = UIPasteboard.general
        let changes = clipboard.changeCount
        clipboard.setItems([[UTType.utf8PlainText.identifier: code]],
                           options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        return clipboard.changeCount != changes
    }

    /// The code, over whatever app is in front. Not while that is FlekDeck,
    /// where the sheet shows it and a notification would not. Worded the way
    /// a verification code is in a message.
    private func notify(code: String) {
        guard UIApplication.shared.applicationState != .active else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "lc.flek.jit.pair.notification".loc
        content.body = String(format: (isCodeCopied ? "lc.flek.jit.pair.notification.copied %@"
                                                    : "lc.flek.jit.pair.notification.body %@").loc, code)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.codeNotification,
                                                                     content: content, trigger: nil))
    }

    private func withdrawNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.codeNotification])
        center.removePendingNotificationRequests(withIdentifiers: [Self.codeNotification])
    }
}

/// Keeps the app running, and one line of text on show, while it is behind
/// another app.
@available(iOS 26.0, *)
@MainActor
private final class FlekPairingKeepAlive {
    /// The one in use. The scheduler's launch handler outlives it, as a
    /// registration cannot be taken back, so the handler finds it here by
    /// identifier rather than holding on to it.
    private static weak var current: FlekPairingKeepAlive?

    private let identifier: String
    private let title: String
    private var subtitle: String
    private var task: BGContinuedProcessingTask?
    private var ticker: Timer?
    private var isOver = false
    /// The system has started the task, which is when its Live Activity shows.
    var onStarted: (() -> Void)?
    var onExpired: (() -> Void)?

    /// The keep-alive, or nil where the system would not take the task, and
    /// either way how asking for it went.
    static func make(title: String, subtitle: String) -> (FlekPairingKeepAlive?, String) {
        guard let prefix = LCInstallBackgroundTask.taskIdentifierPrefix() else {
            return (nil, "no identifier permitted")
        }
        // Never reused: registering one identifier twice ends the app.
        let identifier = prefix + "pairing-" + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                FlekPairingKeepAlive.adopt(task, identifier: identifier)
            }
        }
        guard registered else {
            return (nil, "registration refused")
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Queued where it cannot start at once, as installs ask for theirs,
        // rather than refused: a task that starts late is still of use while
        // the wait for the user goes on.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            let error = error as NSError
            return (nil, "refused, \(error.domain) \(error.code)")
        }
        let keepAlive = FlekPairingKeepAlive(identifier: identifier, title: title, subtitle: subtitle)
        current = keepAlive
        return (keepAlive, "asked for")
    }

    private init(identifier: String, title: String, subtitle: String) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
    }

    private static func adopt(_ task: BGContinuedProcessingTask, identifier: String) {
        guard let keepAlive = current, keepAlive.identifier == identifier, !keepAlive.isOver else {
            task.setTaskCompleted(success: true)
            return
        }
        keepAlive.task = task
        task.expirationHandler = {
            Task { @MainActor in
                guard let keepAlive = FlekPairingKeepAlive.current, keepAlive.identifier == identifier else {
                    return
                }
                keepAlive.end(success: false)
                keepAlive.onExpired?()
            }
        }
        task.updateTitle(keepAlive.title, subtitle: keepAlive.subtitle)
        keepAlive.onStarted?()
        // There is nothing to measure while waiting for the user, but a bar
        // that stands still reads as stalled, and stalled tasks are the first
        // the system takes back. It creeps towards full without getting there.
        task.progress.totalUnitCount = 1000
        keepAlive.ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                FlekPairingKeepAlive.current?.tick()
            }
        }
    }

    private func tick() {
        guard let progress = task?.progress else {
            return
        }
        progress.completedUnitCount += max(1, (progress.totalUnitCount - progress.completedUnitCount) / 60)
    }

    func show(_ subtitle: String) {
        self.subtitle = subtitle
        task?.updateTitle(title, subtitle: subtitle)
    }

    func end(success: Bool) {
        guard !isOver else {
            return
        }
        isOver = true
        ticker?.invalidate()
        ticker = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
    }
}

/// The sheet shown while the pairing file is being made: what to do in
/// Settings, and the code to type there once the device asks for it.
///
/// Settings asks for two things that look alike, the device's passcode and
/// then the code from here, and FlekDeck has no code to show until the first
/// is in: the device does not connect before that. The steps say so, since a
/// user who takes the passcode screen for the code's comes back here to find
/// none, and gives up.
struct FlekDevicePairingView: View {
    @ObservedObject var pairing: FlekDevicePairing
    /// Called once the pairing file is in place.
    var onPaired: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Label("lc.flek.jit.pair.step1".loc, systemImage: "1.circle")
                    Label(String(format: "lc.flek.jit.pair.step2 %@".loc, FlekDevicePairing.hostName), systemImage: "2.circle")
                    Label("lc.flek.jit.pair.step3".loc, systemImage: "3.circle")
                    Label("lc.flek.jit.pair.step4".loc, systemImage: "4.circle")
                    code
                } footer: {
                    Text(footer)
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                }
                Section {
                    if isFailure {
                        Button("lc.flek.retry".loc) {
                            pairing.start()
                        }
                    } else {
                        Button("lc.flek.jit.pair.openSettings".loc) {
                            openSettings()
                        }
                    }
                }
                Section {
                    DisclosureGroup("lc.flek.jit.pair.details".loc) {
                        Text(pairing.events.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("lc.common.copy".loc) {
                            UIPasteboard.general.string = pairing.events.joined(separator: "\n")
                        }
                    }
                }
            }
            .navigationTitle("lc.flek.jit.pair.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: pairing.state) { state in
            if state == .paired {
                onPaired()
                dismiss()
            }
        }
    }

    /// Privacy & Security, by the link Settings itself goes there with.
    /// Developer Mode is at the foot of that page.
    private static let privacyPage = URL(string: "settings-navigation://com.apple.Settings.PrivacyAndSecurity")

    /// Opens Settings as near to where the pairing is started as it will go:
    /// on Privacy & Security, or failing that wherever Settings was left. The
    /// links an app may open by itself all lead to its own page in Settings,
    /// two levels down from where everything else is, so that comes last.
    private func openSettings() {
        LCUtils.openSettingsApp(withLink: Self.privacyPage) { route in
            Task { @MainActor in
                switch route {
                case 1:
                    pairing.note("Settings opened, with the link to Privacy & Security")
                case 2:
                    pairing.note("Settings opened, with no link")
                default:
                    pairing.note("Settings opened on FlekDeck's own page")
                    if let ownPage = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(ownPage)
                    }
                }
            }
        }
    }

    /// The code, large enough to be read at a glance on the way back to
    /// Settings; until the device asks for one, that it is being waited for.
    @ViewBuilder
    private var code: some View {
        if case .askingForCode(let code) = pairing.state {
            VStack(spacing: 4) {
                Text(code)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                if pairing.isCodeCopied {
                    Text("lc.flek.jit.pair.copied".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        } else if !isFailure {
            HStack(spacing: 8) {
                ProgressView()
                Text("lc.flek.jit.pair.waiting".loc)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var isFailure: Bool {
        if case .failed = pairing.state { return true }
        return false
    }

    private var footer: String {
        if case .failed(let reason) = pairing.state {
            return reason
        }
        if pairing.hasFailedAttempt {
            return "lc.flek.jit.pair.retry".loc
        }
        return "lc.flek.jit.pair.footer".loc
    }
}
