//
//  FlekBuiltInJITSection.swift
//  LiveContainerSwiftUI
//
//  What the JIT page shows while built-in JIT is the selected enabler: its
//  setup, as steps that each tick off once done — the pairing file it connects
//  with, the VPN it connects through, a check that the two work, and the apps
//  to use it for.
//
//  It is meant to be gone through without having read anything: one button on
//  the page is filled at a time, the one to tap next, and the check runs by
//  itself once the two steps before it are done.
//
//  Built-in JIT is StikJIT run by FlekDeck itself. A guest that needs JIT
//  starts a second LiveProcess, which reaches the device's own debug service
//  through a VPN and attaches to the guest — see enableJITWithStikJIT in
//  LCBootstrap. That happens at launch with nothing on screen, so whatever can
//  be set up or found out ahead of it is here.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekBuiltInJITSection: View {
    private enum Readiness: Equatable {
        case unchecked
        /// With the step under way, as shown.
        case checking(String)
        case ready
        case failed(String)
    }

    /// One at a time: a check opens a tunnel to the device and may mount a disk
    /// image, and two of those at once would mount it twice.
    private static let checkQueue = DispatchQueue(label: "com.fs.flekdeck.builtInJIT.check")

    static let localDevVPNURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    @ObservedObject private var vpn = FlekLoopbackVPN.shared

    @StateObject private var devicePairing = FlekDevicePairing()

    @State private var pairingFileFound = FlekBuiltInJIT.hasPairingFile
    /// Made on this device rather than imported. Read as the page comes up,
    /// not here: the view is made anew each time the page is redrawn, and
    /// this reads a file.
    @State private var pairingMadeOnDevice = false
    @State private var isChoosingPairingFile = false
    @State private var pairingSheet: PairingSheet?
    /// Set from the help sheet, which has to be gone before the file importer
    /// can come up.
    @State private var importsAfterSheet = false
    @State private var readiness = Readiness.unchecked
    /// When the check last passed, or zero. Kept, so that the step stays
    /// ticked between visits, until something it checked has changed.
    @AppStorage("FlekJITReadyAt") private var readyAt = 0.0
    @State private var jitAppCount = 0
    /// Setting the VPN up or turning it on, which takes a moment.
    @State private var isVPNBusy = false
    @State private var notice = ""
    @State private var noticeShow = false

    var body: some View {
        Section {
            if let blocker = FlekBuiltInJIT.blocker {
                // In place of the steps, which could only lead to a check that
                // cannot pass.
                Text(blocker)
                    .foregroundStyle(.red)
            } else {
                pairingStep
                vpnStep
                readinessStep
                appsStep
                // Not a step: the setup is whole without it.
                if FlekMobileDataShortcut.isOffered {
                    FlekMobileDataShortcutRow()
                }
            }
            DisclosureGroup("lc.flek.jit.more".loc) {
                if pairingFileFound {
                    Button("lc.flek.jit.pairingFile.remove".loc, role: .destructive) {
                        try? FileManager.default.removeItem(at: LCPath.pairingFilePath)
                        pairingFileFound = false
                        pairingMadeOnDevice = false
                        setupChanged()
                    }
                }
                if vpn.isConfigured {
                    Button("lc.flek.jit.vpn.remove".loc, role: .destructive) {
                        runVPN(then: setupChanged) { try await vpn.remove() }
                    }
                    .disabled(isVPNBusy)
                }
                Button("lc.flek.jit.resetImage".loc) {
                    resetDiskImage()
                }
                .disabled(isChecking)
            }
            // On the one row that is always here, the steps giving way to a
            // blocker, and for the same reason as the modifiers on the first
            // step: on the section it would be presented once per row.
            .alert("lc.flek.jit.name".loc, isPresented: $noticeShow) {
                Button("lc.common.ok".loc) {}
            } message: {
                Text(notice)
            }
        } header: {
            Text("lc.flek.jit.header".loc)
                // A name, to be read as it is written.
                .textCase(nil)
                // On the header, which is there whatever the section shows
                // under it, and is one view: a modifier on the section would
                // be applied to every row, and so run once per row.
                .onAppear {
                    pairingMadeOnDevice = FlekBuiltInJIT.isPairingFileMadeOnDevice
                    if readiness == .unchecked, readyAt > 0, pairingFileFound {
                        readiness = .ready
                    }
                }
                .task {
                    if FlekLoopbackVPN.isAvailable {
                        await vpn.refresh()
                    }
                }
        } footer: {
            Text("lc.flek.jit.footer".loc)
        }
    }

    /// One step of the setup: its number, which becomes a tick once the step is
    /// done, what the step is, a line about it, and the control that does it.
    private func step<Control: View>(_ number: Int, isDone: Bool, title: String, caption: String,
                                     captionColor: Color = .secondary,
                                     @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(isDone ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(captionColor)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 2)
    }

    /// A step's control. Bordered, so that it is the button that is tapped
    /// rather than the whole row; filled where it is the one to go for.
    @ViewBuilder
    private func stepButton(_ title: String, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        if isProminent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }

    /// The step to do next. Its button is the filled one, so that one thing on
    /// the page always stands out as what to tap.
    private var nextStep: Int {
        if !pairingFileFound {
            return 1
        }
        if FlekLoopbackVPN.isAvailable, !vpn.isConfigured {
            return 2
        }
        return isReady ? 4 : 3
    }

    /// The check that passed says nothing about a setup changed since.
    private func setupChanged() {
        readiness = .unchecked
        readyAt = 0
    }

    // MARK: 1. Pairing file

    private enum PairingSheet: Identifiable {
        case create
        /// How a pairing file is made on a computer.
        case importHelp

        var id: Self { self }
    }

    /// Whether the pairing file can be made on this device, or why not.
    private enum OnDevicePairing {
        case available
        case needsNewerSystem
        /// The pairing library is not in this build.
        case missing
    }

    private var onDevicePairing: OnDevicePairing {
        guard #available(iOS 27.0, *) else {
            return .needsNewerSystem
        }
        return LCDevicePairing.isAvailable ? .available : .missing
    }

    @ViewBuilder
    private var pairingStep: some View {
        step(1, isDone: pairingFileFound,
             title: "lc.flek.jit.step1.title".loc,
             caption: pairingCaption) {
            if pairingFileFound {
                Menu("lc.flek.jit.replace".loc) {
                    Button {
                        createPairingFile()
                    } label: {
                        Text("lc.flek.jit.pair.create".loc)
                        Text(onDeviceCaption)
                    }
                    .disabled(!isOnDevicePairingOffered)
                    Button("lc.flek.jit.pair.fromComputer".loc) {
                        pairingSheet = .importHelp
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .sheet(item: $pairingSheet, onDismiss: pairingSheetClosed) { sheet in
            switch sheet {
            case .create:
                FlekDevicePairingView(pairing: devicePairing) {
                    pairingFileFound = true
                    pairingMadeOnDevice = true
                    setupChanged()
                    checkOnceSetUp()
                }
            case .importHelp:
                FlekPairingImportHelpView {
                    importsAfterSheet = true
                }
            }
        }
        // On one row: a modifier on the section would be applied to every row,
        // and so present once per row.
        .betterFileImporter(isPresented: $isChoosingPairingFile, types: Self.pairingFileTypes, multiple: false) { urls in
            importPairingFile(from: urls[0])
        } onDismiss: {
            isChoosingPairingFile = false
        }

        // The two ways to a pairing file, for as long as there is none to use.
        // Making it here comes first wherever the device can do that, and is
        // shown where it cannot, with the reason. The other is a computer's,
        // and opens its guide: what to do there, and the button that brings
        // the file in.
        if !pairingFileFound {
            pairingOption(title: "lc.flek.jit.pair.create".loc, caption: onDeviceCaption,
                          button: "lc.flek.jit.create".loc,
                          isProminent: isOnDevicePairingOffered,
                          isEnabled: isOnDevicePairingOffered) {
                createPairingFile()
            }
            pairingOption(title: "lc.flek.jit.pair.fromComputer".loc,
                          caption: "lc.flek.jit.pair.fromComputer.caption".loc,
                          button: "lc.flek.jit.import".loc,
                          isProminent: !isOnDevicePairingOffered) {
                pairingSheet = .importHelp
            }
        }
    }

    /// One of the ways to a pairing file, set in under the step it belongs to.
    private func pairingOption(title: String, caption: String, button: String, isProminent: Bool,
                               isEnabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            // As wide as a step's number, so the text lines up with the step's.
            Image(systemName: "1.circle")
                .font(.title2)
                .hidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            stepButton(button, isProminent: isProminent, action: action)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 2)
    }

    private var isOnDevicePairingOffered: Bool {
        onDevicePairing == .available
    }

    private var onDeviceCaption: String {
        switch onDevicePairing {
        case .available: return "lc.flek.jit.pair.create.caption".loc
        case .needsNewerSystem: return "lc.flek.jit.pair.create.caption.os".loc
        case .missing: return "lc.flek.jit.pair.create.caption.missing".loc
        }
    }

    private var pairingCaption: String {
        guard pairingFileFound else {
            // What the file is for, over the two ways to get one.
            return "lc.flek.jit.step1.caption".loc
        }
        return (pairingMadeOnDevice ? "lc.flek.jit.step1.done.created" : "lc.flek.jit.step1.done").loc
    }

    private func createPairingFile() {
        devicePairing.begin()
        pairingSheet = .create
    }

    private func pairingSheetClosed() {
        // How Cancel and a swipe down end a pairing under way. Once paired
        // there is nothing left to end.
        if devicePairing.state != .paired {
            devicePairing.cancel()
        }
        if importsAfterSheet {
            importsAfterSheet = false
            isChoosingPairingFile = true
        }
    }

    /// A pairing file is a property list whatever it is called; iloader and
    /// SideStore name theirs .mobiledevicepairing.
    private static let pairingFileTypes: [UTType] = [
        .propertyList,
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data),
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data),
    ].compactMap { $0 }

    private func importPairingFile(from url: URL) {
        do {
            try FlekBuiltInJIT.storePairingFile(try Data(contentsOf: url))
            pairingFileTaken()
        } catch {
            show(error.localizedDescription)
        }
    }

    /// There is a pairing file, or another than there was.
    private func pairingFileTaken() {
        pairingFileFound = true
        // Still one made on this device, if that is what was brought back.
        pairingMadeOnDevice = FlekBuiltInJIT.isPairingFileMadeOnDevice
        setupChanged()
        checkOnceSetUp()
    }

    // MARK: 2. VPN

    /// The VPN the helper connects through: FlekDeck's own where this copy can
    /// provide one, and LocalDevVPN, which FlekDeck has no way to see or to
    /// start, where it cannot.
    @ViewBuilder
    private var vpnStep: some View {
        if FlekLoopbackVPN.isAvailable {
            step(2, isDone: vpn.isConfigured,
                 title: "lc.flek.jit.step2.title".loc,
                 caption: "lc.flek.jit.step2.caption".loc) {
                if vpn.isConfigured {
                    Toggle("lc.flek.jit.step2.title".loc, isOn: vpnSwitch)
                        .labelsHidden()
                        .disabled(isVPNBusy)
                } else if isVPNBusy {
                    ProgressView()
                } else {
                    stepButton("lc.flek.jit.setUp".loc, isProminent: nextStep == 2) {
                        runVPN(then: checkOnceSetUp) {
                            try await vpn.setUp()
                            try await vpn.connect()
                        }
                    }
                }
            }
        } else {
            step(2, isDone: false,
                 title: "lc.flek.jit.step2.external.title".loc,
                 caption: "lc.flek.jit.step2.external.caption".loc) {
                stepButton("lc.flek.jit.get".loc) {
                    UIApplication.shared.open(Self.localDevVPNURL)
                }
            }
        }
    }

    private var vpnSwitch: Binding<Bool> {
        Binding {
            vpn.isOn
        } set: { isOn in
            if isOn {
                runVPN { try await vpn.connect() }
            } else {
                vpn.disconnect()
            }
        }
    }

    /// `then` follows only where the work went through.
    private func runVPN(then: (() -> Void)? = nil, _ work: @escaping () async throws -> Void) {
        isVPNBusy = true
        Task {
            do {
                try await work()
                isVPNBusy = false
                then?()
            } catch {
                isVPNBusy = false
                show(error.localizedDescription)
            }
        }
    }

    // MARK: 3. Readiness

    private var readinessStep: some View {
        step(3, isDone: isReady,
             title: "lc.flek.jit.step3.title".loc,
             caption: readinessCaption,
             captionColor: readinessColor) {
            if isChecking {
                ProgressView()
            } else {
                stepButton("lc.flek.jit.check".loc, isProminent: nextStep == 3) {
                    checkReadiness()
                }
                .disabled(!pairingFileFound || FlekBuiltInJIT.blocker != nil)
            }
        }
    }

    /// Ready, and with the pairing file still there.
    private var isReady: Bool {
        readiness == .ready && pairingFileFound
    }

    /// Runs the check without being asked once the two steps before it are
    /// done, so that finishing the second of them is all it takes. Not where
    /// the VPN is another app's: whether that is connected cannot be told, and
    /// a check that fails for it would only alarm.
    private func checkOnceSetUp() {
        // After whatever called this has had its changes take.
        DispatchQueue.main.async {
            guard pairingFileFound, FlekBuiltInJIT.blocker == nil, !isChecking, !isReady,
                  FlekLoopbackVPN.isAvailable, vpn.isConfigured else {
                return
            }
            checkReadiness()
        }
    }

    private var isChecking: Bool {
        if case .checking = readiness { return true }
        return false
    }

    private var readinessCaption: String {
        switch readiness {
        case .unchecked:
            return "lc.flek.jit.step3.caption".loc
        case .checking(let step):
            return step
        case .ready:
            return "lc.flek.jit.ready".loc
        case .failed(let reason):
            return reason
        }
    }

    private var readinessColor: Color {
        switch readiness {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    /// Does what a guest's helper does first at launch — reach the device and
    /// mount its developer disk image — but here, where it can be watched, and
    /// with the image left mounted for the launches that follow.
    private func checkReadiness() {
        readiness = .checking(Self.stepText(0, -1))
        Task {
            // FlekDeck's own VPN is turned on for the check as it is for a
            // launch. If it does not come up, the check says so in its own way.
            if vpn.isConfigured {
                try? await vpn.connect()
            }
            // Over mobile data the device does not answer however the VPN is,
            // and on no connection at all a VPN that is off cannot start. The
            // check would only say that it timed out and ask about the VPN.
            if !(await FlekBuiltInJIT.isDeviceReachable()), let reason = await connectionReason() {
                readiness = .failed(reason)
                readyAt = 0
                return
            }
            Self.checkQueue.async {
                let error = LCUtils.prepareBuiltInJIT { stage, fraction in
                    let step = Self.stepText(stage, fraction)
                    DispatchQueue.main.async {
                        readiness = .checking(step)
                    }
                }
                DispatchQueue.main.async {
                    if let error = error as NSError? {
                        // Code 1 is StikJITPreflight's "nothing answered", which is
                        // nearly always the VPN that leads back to the device.
                        let hint = error.code == 1 ? "\n" + "lc.flek.jit.unreachableHint".loc : ""
                        readiness = .failed(error.localizedDescription + hint)
                        readyAt = 0
                    } else {
                        readiness = .ready
                        readyAt = Date().timeIntervalSince1970
                    }
                }
            }
        }
    }

    /// Why the device does not answer, where that is down to what it is
    /// connected through, with the one thing to do about it next.
    private func connectionReason() async -> String? {
        switch await FlekBuiltInJIT.connection() {
        case .mobileData:
            // FlekDeck's own VPN has just been turned on, and stays on.
            return (vpn.isConfigured ? "lc.flek.jit.check.mobileData" : "lc.flek.jit.check.mobileData.other").loc
        case .offline where vpn.isConfigured && !vpn.isOn:
            return "lc.flek.jit.check.offline".loc
        default:
            return nil
        }
    }

    /// The stages StikJITPreflight reports, in its numbering.
    private static func stepText(_ stage: Int, _ fraction: Double) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        switch stage {
        case 1: return "lc.flek.jit.step.checkingImage".loc
        case 2: return String(format: "lc.flek.jit.step.downloading %lld".loc, percent)
        case 3: return String(format: "lc.flek.jit.step.mounting %lld".loc, percent)
        case 4, 5: return "lc.flek.jit.step.verifying".loc
        default: return "lc.flek.jit.step.reaching".loc
        }
    }

    private func resetDiskImage() {
        Self.checkQueue.async {
            let error = LCUtils.resetBuiltInJITDiskImage()
            DispatchQueue.main.async {
                setupChanged()
                show(error?.localizedDescription ?? "lc.flek.jit.resetImage.done".loc)
            }
        }
    }

    // MARK: 4. Apps

    /// The setup enables JIT for no app by itself, so the apps to use it for
    /// are chosen here as its last step rather than one by one in their own
    /// settings, which have the same switch.
    private var appsStep: some View {
        NavigationLink {
            FlekJITAppsView()
        } label: {
            step(4, isDone: jitAppCount > 0,
                 title: "lc.flek.jit.step4.title".loc,
                 caption: jitAppCount > 0 ? String(format: "lc.flek.jit.step4.caption.count %lld".loc, jitAppCount)
                                          : "lc.flek.jit.step4.caption".loc) {
                EmptyView()
            }
        }
        // Also on the way back from the list, where the count changes.
        .onAppear {
            jitAppCount = FlekJITAppsView.countUsingJIT
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeShow = true
    }
}

/// The installed apps, each with the switch that has it launch with JIT: the
/// one in an app's own settings, gathered where JIT is set up.
struct FlekJITAppsView: View {
    /// Hidden apps only while they are unlocked, as everywhere else.
    static var apps: [LCAppModel] {
        let model = DataManager.shared.model
        return model.apps + (model.isHiddenAppUnlocked ? model.hiddenApps : [])
    }

    /// How many of them launch with JIT: those switched on here, and the
    /// 32-bit ones, which always do.
    static var countUsingJIT: Int {
        apps.filter { $0.uiIsJITNeeded || $0.uiIs32bit }.count
    }

    @ObservedObject private var model = DataManager.shared.model

    var body: some View {
        Form {
            Section {
                if Self.apps.isEmpty {
                    Text("lc.flek.jit.apps.empty".loc)
                        .foregroundStyle(.secondary)
                }
                ForEach(Self.apps, id: \.self) { app in
                    Row(app: app)
                }
            } footer: {
                Text("lc.flek.jit.apps.footer".loc)
            }
        }
        .navigationTitle("lc.flek.jit.apps.title".loc)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Row: View {
        @ObservedObject var app: LCAppModel
        @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

        var body: some View {
            // A 32-bit app runs with JIT whatever is chosen, which is how its
            // own settings show it too.
            Toggle(isOn: app.uiIs32bit ? .constant(true) : $app.uiIsJITNeeded) {
                HStack(spacing: 12) {
                    IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                        .frame(width: 32, height: 32)
                    Text(app.appInfo.displayName() ?? "")
                }
            }
            .disabled(app.uiIs32bit)
        }
    }
}

/// The way to a pairing file that goes by a computer: how the file is made
/// there, and the button that brings it in once it is here.
///
/// iloader and idevice_pair both make the file. Neither can hand it over to
/// FlekDeck, so it is carried over by hand, with AirDrop for example, and
/// picked from Files by Import, the one button that stands out.
struct FlekPairingImportHelpView: View {
    private static let iloaderURL = URL(string: "https://github.com/nab138/iloader/releases/latest")!
    private static let idevicePairURL = URL(string: "https://github.com/jkcoxson/idevice_pair/releases/latest")!

    /// Called when a file is to be picked. The sheet is still up at that
    /// point, so the importer has to wait for it to go.
    var onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Label("lc.flek.jit.importHelp.step1".loc, systemImage: "1.circle")
                    Label("lc.flek.jit.importHelp.step2".loc, systemImage: "2.circle")
                    Label("lc.flek.jit.importHelp.step3".loc, systemImage: "3.circle")
                }
                Section {
                    Link("iloader", destination: Self.iloaderURL)
                    Link("idevice_pair", destination: Self.idevicePairURL)
                } footer: {
                    Text("lc.flek.jit.importHelp.other.note".loc)
                }
                Section {
                    // Filled and the full width, with no row behind it: the
                    // last step, and the one thing on the page to tap.
                    Button {
                        onImport()
                        dismiss()
                    } label: {
                        Text("lc.flek.jit.importHelp.importManually".loc)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("lc.flek.jit.importHelp.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
            }
        }
    }
}
