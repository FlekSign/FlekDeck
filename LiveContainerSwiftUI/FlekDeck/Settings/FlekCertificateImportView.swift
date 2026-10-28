//
//  FlekCertificateImportView.swift
//  LiveContainerSwiftUI
//
//  The "Import Certificate" page General leads to while no certificate is
//  imported.
//  It takes a .p12 with its password and the .mobileprovision issued with it,
//  checks them against each other and against the FlekDeck they are meant for,
//  and stores the certificate the way every other import does. The profile is
//  only read for those checks: FlekDeck signs with the certificate alone.
//

import SwiftUI

struct FlekCertificateImportView: View {
    /// A file from the picker, read as soon as it is picked: the picker hands
    /// over a copy in a temporary folder the system is free to empty.
    private struct PickedFile {
        let name: String
        let data: Data
    }

    /// Why a pair cannot be imported, as its alert puts it: a short title, then
    /// what is wrong and what to pick instead. Each names the strings
    /// `lc.flek.certImport.error.<case>.title` and `.message`.
    private enum ImportProblem: String {
        case fileUnreadable
        case profileInvalid
        case certUnreadable
        case profileNotDevelopment
        case certNotDevelopment
        case certExpired
        case profileExpired
        case profileMismatch
        case appMismatch

        var title: String { "lc.flek.certImport.error.\(rawValue).title".loc }
        var message: String { "lc.flek.certImport.error.\(rawValue).message".loc }
    }

    @Environment(\.dismiss) private var dismiss

    @State private var profileFile: PickedFile?
    @State private var certificateFile: PickedFile?
    @State private var password = ""
    @State private var profilePickerShown = false
    @State private var certificatePickerShown = false
    @State private var shownProblem: ImportProblem?

    /// The password is not required: a .p12 can be exported without one.
    private var canImport: Bool {
        profileFile != nil && certificateFile != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                warning
                filesCard
                importButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.settings.importCertificate".loc).font(.headline) } }
        .betterFileImporter(isPresented: $profilePickerShown, types: [.mobileProvision], callback: { urls in
            if let file = read(urls.first) { profileFile = file }
        }, onDismiss: {
            profilePickerShown = false
        })
        .betterFileImporter(isPresented: $certificatePickerShown, types: [.p12], callback: { urls in
            if let file = read(urls.first) { certificateFile = file }
        }, onDismiss: {
            certificatePickerShown = false
        })
        .alert(Text(shownProblem?.title ?? ""), isPresented: problemShown, presenting: shownProblem) { _ in
            Button("lc.common.ok".loc) {}
                .keyboardShortcut(.defaultAction)
        } message: { problem in
            Text(problem.message)
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { shownProblem != nil }, set: { if !$0 { shownProblem = nil } })
    }

    // MARK: - Sections

    private var warning: some View {
        (Text(Image(systemName: "exclamationmark.triangle.fill"))
            + Text(verbatim: " ")
            + Text(emphasizing: "lc.flek.certImport.warning".loc))
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var filesCard: some View {
        VStack(spacing: 0) {
            fileRow(systemImage: "doc.badge.gearshape.fill",
                    prompt: "lc.flek.certImport.chooseProfile".loc,
                    file: profileFile,
                    pick: { profilePickerShown = true },
                    clear: { profileFile = nil })
            rowDivider
            fileRow(systemImage: "key.fill",
                    prompt: "lc.flek.certImport.chooseP12".loc,
                    file: certificateFile,
                    pick: { certificatePickerShown = true },
                    clear: { certificateFile = nil })
            rowDivider
            HStack(spacing: 12) {
                rowTile("ellipsis.rectangle.fill")
                SecureField("lc.flek.certImport.password".loc, text: $password)
                    .font(.system(size: 17))
                if !password.isEmpty {
                    clearButton { password = "" }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
        }
        .background(FlekSetupCardBackground())
    }

    private var importButton: some View {
        Button(action: importCertificate) {
            FlekCapsuleLabel(title: "lc.flek.certImport.import".loc)
        }
        .buttonStyle(FlekCardPressStyle())
        .disabled(!canImport)
        // Paler rather than grey until both files are picked, as drawn.
        .opacity(canImport ? 1 : 0.5)
    }

    // MARK: - Pieces

    /// A row that picks a file. Once it has one it names it, with a button to
    /// clear it beside the name, which picks another when tapped. The two are
    /// siblings rather than one inside the other, as a button in a button's
    /// label never gets the tap.
    private func fileRow(systemImage: String, prompt: String, file: PickedFile?,
                         pick: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: pick) {
                HStack(spacing: 12) {
                    rowTile(systemImage)
                    if let file {
                        Text(file.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(prompt)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(FlekCardPressStyle())
            if file != nil {
                clearButton(action: clear)
            }
        }
        .font(.system(size: 17))
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    /// The grey ✕ that empties a row, like a text field's clear button.
    private func clearButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("lc.flek.certImport.clear".loc)
    }

    private func rowTile(_ systemImage: String) -> some View {
        FlekSetupTile(color: .blue, size: 29) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.white)
        }
    }

    /// Inset to where a row's text starts, as a grouped list draws it.
    private var rowDivider: some View {
        Divider().padding(.leading, 14 + 29 + 12)
    }

    // MARK: - Import

    private func read(_ url: URL?) -> PickedFile? {
        guard let url else { return nil }
        do {
            return PickedFile(name: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            shownProblem = .fileUnreadable
            return nil
        }
    }

    private func importCertificate() {
        guard let profileFile, let certificateFile else { return }
        if let problem = problem(profile: profileFile.data, certificate: certificateFile.data) {
            shownProblem = problem
            return
        }
        // Stored where the rest of FlekDeck reads a certificate back from:
        // JIT-less signing, the diagnosis page, and the shared model behind the
        // Settings badge.
        LCUtils.appGroupUserDefault.set(certificateFile.data, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    /// What is wrong with the pair, or nil when it can be imported. The first
    /// problem found is the one shown, in this order. A mismatch caught here
    /// would otherwise only show up later, as apps that will not launch.
    private func problem(profile profileData: Data, certificate: Data) -> ImportProblem? {
        guard let profile = LCProvisioningProfile(data: profileData) else {
            return .profileInvalid
        }
        // Opened by ZSign, as JIT-less signing will open it, so a certificate
        // that passes here is one FlekDeck can actually use. It fails the same
        // way for a wrong password and for a file that is no .p12 at all.
        guard let info = LCUtils.getCertInfo(withKeyData: certificate, password: password),
              let certificateTeamID = info["teamId"] as? String else {
            return .certUnreadable
        }
        if !profile.isDevelopment {
            return .profileNotDevelopment
        }
        if let name = info["commonName"] as? String, !Self.isDevelopmentCertificateName(name) {
            return .certNotDevelopment
        }
        if let expiry = info["notAfter"] as? Date, expiry < Date() {
            return .certExpired
        }
        if profile.isExpired {
            return .profileExpired
        }
        if certificateTeamID != profile.teamID {
            return .profileMismatch
        }
        if let appTeamID = Self.installedTeamID, appTeamID != certificateTeamID {
            return .appMismatch
        }
        return nil
    }

    /// Whether a certificate's common name is a development certificate's.
    /// Apple names its iOS development certificates "Apple Development: …" and
    /// the older ones "iPhone Developer: …"; distribution, enterprise and Mac
    /// certificates all read otherwise.
    private static func isDevelopmentCertificateName(_ commonName: String) -> Bool {
        commonName.hasPrefix("Apple Development:") || commonName.hasPrefix("iPhone Developer:")
    }

    /// The team that signed the FlekDeck running now, from its own
    /// entitlements, as the JIT-Less diagnosis page reads it. Nil when the app
    /// carries none, which leaves that one check out.
    private static var installedTeamID: String? {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }
}

/// The filled capsule the certificate pages use for their main buttons.
struct FlekCapsuleLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(Color.accentColor))
    }
}

extension Text {
    /// A string with **bold** runs, as the designs set their key phrases. The
    /// plain text should the markup ever fail to parse.
    init(emphasizing string: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: string, options: options) {
            self.init(attributed)
        } else {
            self.init(verbatim: string)
        }
    }
}
