//
//  FlekMobileDataShortcut.swift
//  LiveContainerSwiftUI
//
//  JIT cannot be started while the device is on mobile data, and can once
//  Mobile Data is switched off, with the VPN left on: found on a device with
//  iOS 27. FlekDeck turns its own VPN on, so away from Wi-Fi all that is
//  missing is Mobile Data off for the moment JIT takes to come on. iOS lets no
//  app switch that. The Shortcuts app can, so the user adds a shortcut,
//  "FlekJIT", which FlekDeck runs: with "off" as an app set to launch with JIT
//  is started over mobile data, and with "on" once JIT is on.
//
//  An app can run a shortcut only by opening the Shortcuts app, which comes to
//  the front for a moment and hands back through a link of FlekDeck's own.
//
//  "On" is run by whatever is in front when JIT comes on: here where the app
//  runs in a window, and by the launched app itself where it takes FlekDeck's
//  place (LCTurnMobileDataBackOn in LCBootstrap). That Mobile Data is off is
//  noted in the shared settings from before the shortcut runs, so that a
//  launch that ends before JIT is on leaves it to be switched back on the next
//  time FlekDeck opens.
//

import Darwin
import SwiftUI
import notify

@MainActor
final class FlekMobileDataShortcut: ObservableObject {
    static let shared = FlekMobileDataShortcut()

    /// The shortcut's name, which it is run by. The Shortcuts app names a
    /// shortcut after the file it is added from, so this is that file's name
    /// as well.
    static let name = "FlekJIT"

    /// Where the Shortcuts app opens straight at Add Shortcut, which it does
    /// only for an iCloud link, and that lives only while the shortcut stays
    /// in its owner's library. None is set, so the shortcut is added from
    /// FlekDeck's own copy, through the share sheet. One set here has to be of
    /// the same shortcut as that copy.
    static let iCloudLink: URL? = nil

    /// What the shortcut's link back to FlekDeck is addressed to.
    static let linkHost = "jit-mobile-data"

    /// Where it is noted that the user has been through adding the shortcut,
    /// which the page's switch waits for.
    nonisolated static let wasAddedKey = "FlekJITMobileDataShortcutAdded"

    /// The words the shortcut goes by. Any other does nothing, which is how
    /// it is tried out.
    private enum Word {
        static let off = "off"
        static let on = "on"
        static let nothing = "check"
    }

    private enum Key {
        static let isOn = "FlekJITMobileDataShortcut"
        /// When the shortcut switched Mobile Data off, until it is back on.
        /// LCBootstrap reads it too.
        static let switchedOff = "FlekJITMobileDataOff"
    }

    /// What the helper posts once it is done with its connection, JIT on or
    /// not (StikJITHeadless).
    private static let helperOver = "com.flekdeck.jit.over"

    enum Outcome {
        /// The shortcut ran to its end.
        case done
        /// It did not, or did not say: it is missing, was stopped, or the
        /// user came back without it.
        case failed
    }

    /// Whether there is anything to offer: FlekDeck has to have the VPN, to
    /// turn it on ahead of Mobile Data going off, and the device mobile data.
    static let isOffered = FlekLoopbackVPN.isAvailable && hasMobileData

    /// An iPad without mobile data has no interface for it.
    private static let hasMobileData: Bool = {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return true }
        defer { freeifaddrs(list) }
        var entry = list
        while let interface = entry {
            if String(cString: interface.pointee.ifa_name).hasPrefix("pdp_ip") {
                return true
            }
            entry = interface.pointee.ifa_next
        }
        return false
    }()

    private nonisolated static var defaults: UserDefaults { LCUtils.appGroupUserDefault }

    /// Whether launches use the shortcut.
    @Published var isOn = FlekMobileDataShortcut.defaults.bool(forKey: Key.isOn) {
        didSet {
            Self.defaults.set(isOn, forKey: Key.isOn)
        }
    }

    /// The run under way is answered through this.
    private var waiting: ((Outcome) -> Void)?
    /// Counts the runs, for telling a timer that belongs to an earlier one.
    private var runCount = 0
    /// FlekDeck has gone behind the Shortcuts app for the run under way.
    private var hasLeft = false
    /// Mobile Data is to go back on as soon as FlekDeck is in front.
    private var turnsOnWhenActive = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.waiting != nil else { return }
                self.hasLeft = true
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cameToFront() }
        }
        // An app in a window has FlekDeck in front, and its helper says when
        // it is done.
        var token: Int32 = 0
        notify_register_dispatch(Self.helperOver, &token, .main) { [weak self] _ in
            Task { @MainActor in
                // Once the app in the window has seen that Mobile Data is
                // being seen to, and so says nothing of it itself.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.turnMobileDataBackOn()
            }
        }
    }

    // MARK: Mobile Data

    /// Switches Mobile Data off for a launch. `completion` is called once
    /// FlekDeck is back in front, and whether it worked shows in what the
    /// device is then connected through rather than in what the shortcut said.
    func turnMobileDataOff(completion: @escaping (Outcome) -> Void) {
        // From before it runs: one that ends halfway may have switched it.
        Self.defaults.set(Date().timeIntervalSince1970, forKey: Key.switchedOff)
        run(Word.off, completion: completion)
    }

    /// Mobile Data turned out to be on still, so there is none to switch back.
    func forget() {
        Self.defaults.removeObject(forKey: Key.switchedOff)
    }

    /// Switches Mobile Data back on where the shortcut switched it off and it
    /// has not been yet: JIT is on, or the launch it was for has come to
    /// nothing. Asked once, so that a shortcut that has gone missing is not
    /// asked for every time.
    func turnMobileDataBackOn() {
        guard Self.defaults.double(forKey: Key.switchedOff) > 0 else {
            return
        }
        // Another app cannot be opened from behind.
        guard UIApplication.shared.applicationState == .active else {
            turnsOnWhenActive = true
            return
        }
        forget()
        run(Word.on) { _ in }
    }

    /// Runs the shortcut with nothing for it to do, which shows whether it is
    /// there and finds its way back.
    func tryOut(completion: @escaping (Outcome) -> Void) {
        run(Word.nothing, completion: completion)
    }

    // MARK: Running

    private func run(_ word: String, completion: @escaping (Outcome) -> Void) {
        // One at a time: an earlier one is not answered by this one's link.
        finish(.failed)
        let back = "\(LCUtils.appUrlScheme() ?? "flekdeck")://\(Self.linkHost)"
        var link = URLComponents()
        link.scheme = "shortcuts"
        link.host = "x-callback-url"
        link.path = "/run-shortcut"
        link.queryItems = [
            URLQueryItem(name: "name", value: Self.name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: word),
            URLQueryItem(name: "x-success", value: "\(back)/success"),
            URLQueryItem(name: "x-cancel", value: "\(back)/cancel"),
            URLQueryItem(name: "x-error", value: "\(back)/error"),
        ]
        guard let url = link.url else {
            completion(.failed)
            return
        }
        runCount += 1
        let run = runCount
        waiting = completion
        hasLeft = false
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.finish(.failed, run: run) }
        }
        // A shortcut that waits on a question nobody answers.
        finish(.failed, run: run, after: 60)
    }

    /// The shortcut's link back: `…://jit-mobile-data/success`, `/cancel` or
    /// `/error`. False for any other link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.host?.lowercased() == Self.linkHost else {
            return false
        }
        finish(url.path == "/success" ? .done : .failed)
        return true
    }

    private func cameToFront() {
        if turnsOnWhenActive {
            turnsOnWhenActive = false
            turnMobileDataBackOn()
        }
        // Back from the Shortcuts app, and perhaps without its link: the user
        // came back by hand, or it had nothing by that name to run. The link
        // can follow FlekDeck to the front, so it is given a moment.
        guard waiting != nil, hasLeft else {
            return
        }
        hasLeft = false
        finish(.failed, run: runCount, after: 2)
    }

    /// Answers the run numbered `run` in so many seconds, unless it has been
    /// answered by then.
    private func finish(_ outcome: Outcome, run: Int, after seconds: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            self?.finish(outcome, run: run)
        }
    }

    /// Answers the run under way, or only the one numbered `run`.
    private func finish(_ outcome: Outcome, run: Int? = nil) {
        if let run, run != runCount {
            return
        }
        guard let waiting else {
            return
        }
        self.waiting = nil
        hasLeft = false
        waiting(outcome)
    }

    // MARK: Adding

    /// FlekDeck's own copy of the shortcut, under the name it has to be added
    /// by, for the share sheet to hand to the Shortcuts app. It is kept in the
    /// asset catalog, which needs no place in the project of its own.
    static func fileToAdd() -> URL? {
        guard let shortcut = NSDataAsset(name: "FlekJITShortcut")?.data else {
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FlekJITShortcut", isDirectory: true)
        let file = folder.appendingPathComponent("\(name).shortcut")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try shortcut.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return file
    }
}

/// The row on the JIT page that the shortcut is added and turned on from, laid
/// out as the setup's steps are and said to be optional: the setup is whole
/// without it. Its (?) says what it is for and how it is set up, and so does
/// Add, as the share sheet that adds it has to be told where to send it.
struct FlekMobileDataShortcutRow: View {
    @ObservedObject private var shortcut = FlekMobileDataShortcut.shared
    /// The user has been through adding it. Whether it is there cannot be
    /// asked, only tried, which turning it on does.
    @AppStorage(FlekMobileDataShortcut.wasAddedKey) private var wasAdded = false
    @State private var helpShown = false
    /// While the shortcut is tried out, with the Shortcuts app in front.
    @State private var isTrying = false
    @State private var missingShown = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle")
                .font(.title2)
                .foregroundStyle(shortcut.isOn ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("lc.flek.jit.mobileData.title".loc)
                    Button {
                        helpShown = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    // A button of its own: the row has others.
                    .buttonStyle(.borderless)
                    .accessibilityLabel("lc.flek.jit.mobileData.help".loc)
                }
                Text("lc.flek.jit.mobileData.caption".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            control
                .alert("lc.flek.jit.mobileData.title".loc, isPresented: $missingShown) {
                    Button("lc.flek.jit.mobileData.addAgain".loc) {
                        // Once the alert has gone, which a sheet cannot come
                        // up over.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            startAdding()
                        }
                    }
                    Button("lc.common.ok".loc, role: .cancel) {}
                } message: {
                    Text("lc.flek.jit.mobileData.missing".loc)
                }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $helpShown) {
            FlekMobileDataShortcutHelpView()
        }
    }

    @ViewBuilder
    private var control: some View {
        if isTrying {
            ProgressView()
        } else if wasAdded || shortcut.isOn {
            Toggle("lc.flek.jit.mobileData.title".loc, isOn: isOn)
                .labelsHidden()
        } else {
            Button("lc.flek.jit.mobileData.add".loc) {
                startAdding()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }

    /// Turned on only once the shortcut has run and come back, so that a
    /// launch on the go does not find it missing.
    private var isOn: Binding<Bool> {
        Binding {
            shortcut.isOn
        } set: { isOn in
            guard isOn else {
                shortcut.isOn = false
                return
            }
            isTrying = true
            shortcut.tryOut { outcome in
                isTrying = false
                if outcome == .done {
                    shortcut.isOn = true
                } else {
                    missingShown = true
                }
            }
        }
    }

    /// From an iCloud link the Shortcuts app needs no telling what to do. From
    /// the share sheet it is one of many places the file could go, so the
    /// steps come first, with the button that adds it.
    private func startAdding() {
        if let link = FlekMobileDataShortcut.iCloudLink {
            UIApplication.shared.open(link) { opened in
                if opened {
                    wasAdded = true
                }
            }
        } else {
            helpShown = true
        }
    }
}

/// What the shortcut is for and how it is set up: whether to bother with it is
/// for whoever opens apps with JIT away from Wi-Fi to decide. Add Shortcut is
/// the button that stands out, and the sheet goes once the shortcut has been
/// handed on, leaving the switch on the page as what is left to do.
struct FlekMobileDataShortcutHelpView: View {
    private struct SharedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage(FlekMobileDataShortcut.wasAddedKey) private var wasAdded = false
    @State private var sharedFile: SharedFile?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("lc.flek.jit.mobileData.help.why".loc)
                } header: {
                    Text("lc.flek.jit.mobileData.help.whyHeader".loc)
                } footer: {
                    Text("lc.flek.jit.mobileData.help.who".loc)
                }
                Section {
                    Label("lc.flek.jit.mobileData.help.step1".loc, systemImage: "1.circle")
                    Label("lc.flek.jit.mobileData.help.step2".loc, systemImage: "2.circle")
                    Label("lc.flek.jit.mobileData.help.step3".loc, systemImage: "3.circle")
                } header: {
                    Text("lc.flek.jit.mobileData.help.setUpHeader".loc)
                }
                Section {
                    // Filled and the full width, with no row behind it, as the
                    // computer guide's Refresh.
                    Button(action: add) {
                        Text("lc.flek.jit.mobileData.help.add".loc)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("lc.flek.jit.mobileData.help.note".loc)
                }
            }
            .navigationTitle("lc.flek.jit.mobileData.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $sharedFile) { file in
            FlekShareSheet(items: [file.url]) { completed in
                sharedFile = nil
                guard completed else { return }
                wasAdded = true
                // Once the share sheet has gone: two going at once is refused.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    dismiss()
                }
            }
        }
    }

    private func add() {
        if let link = FlekMobileDataShortcut.iCloudLink {
            UIApplication.shared.open(link) { opened in
                guard opened else { return }
                wasAdded = true
                dismiss()
            }
            return
        }
        guard let file = FlekMobileDataShortcut.fileToAdd() else {
            return
        }
        sharedFile = SharedFile(url: file)
    }
}

/// The system's share sheet, saying whether anything was done with what it
/// was given.
private struct FlekShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            onDone(completed)
        }
        return sheet
    }

    func updateUIViewController(_ sheet: UIActivityViewController, context: Context) {}
}
