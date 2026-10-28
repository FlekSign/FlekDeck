//
//  FlekSourcesPopup.swift
//  LiveContainerSwiftUI
//
//  Source management popup for the Installer. Lets the user add a repository
//  (validated by fetching its manifest), pick one (which opens its catalog),
//  and — in edit mode — delete sources (with a confirm before deletion).
//  Every source is user-added, so every one is removable. Persists to the same
//  UserDefaults("savedRepositories") store used elsewhere.
//

import SwiftUI

struct FlekSourcesPopup: View {
    @Binding var repos: [AppRepository]
    var onSelect: (AppRepository) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var newRepoURL = ""
    @State private var isAdding = false
    @State private var editing = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var pendingDelete: AppRepository?

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)
    private static let fieldFill = Color(red: 136/255, green: 136/255, blue: 136/255).opacity(0.15)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    addSourceSection
                    connectedSourcesSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("lc.flek.appSources".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editing ? "lc.common.done".loc : "lc.flek.edit".loc) {
                        withAnimation { editing.toggle() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
            .alert("lc.common.error".loc, isPresented: $showError) {
                Button("lc.common.ok".loc) {}
            } message: { Text(errorMessage) }
            .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })) {
                Button("lc.common.delete".loc, role: .destructive) {
                    if let r = pendingDelete { delete(r) }
                    pendingDelete = nil
                }
                Button("lc.common.cancel".loc, role: .cancel) { pendingDelete = nil }
            } message: {
                Text("lc.flek.confirmDeleteSource".loc)
            }
        }
    }

    // MARK: Add source

    private var addSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lc.flek.addSource".loc).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Image(systemName: "link").font(.system(size: 22)).foregroundStyle(Color(white: 0.45))
                TextField("", text: $newRepoURL)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .overlay(alignment: .leading) {
                        if newRepoURL.isEmpty {
                            Text(verbatim: "https://example.com/repo.json")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                                .allowsHitTesting(false)
                        }
                    }
                if isAdding {
                    ProgressView().frame(width: 33, height: 33)
                } else {
                    Button { Task { await addRepository() } } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Self.flekBlue)
                    }
                    .buttonStyle(.plain)
                    .disabled(newRepoURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(Capsule().fill(Self.fieldFill))
        }
    }

    // MARK: Connected sources

    private var connectedSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lc.flek.connectedSources".loc).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(repos) { repo in
                    sourceRow(repo)
                }
            }
        }
    }

    private func sourceRow(_ repo: AppRepository) -> some View {
        HStack(spacing: 8) {
            if editing {
                Button { pendingDelete = repo } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
            }
            FlekRemoteIcon(url: repo.iconUrl, size: 44, corner: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.name).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text(repo.sourceURL)
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium)).foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color(.separator), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if editing { return }
            select(repo)
            dismiss()
        }
    }

    // MARK: Logic

    private func select(_ repo: AppRepository) {
        repos = repos.map { var r = $0; r.isSelected = (r.id == repo.id); return r }
        save()
        onSelect(repo)
    }

    private func delete(_ repo: AppRepository) {
        repos.removeAll { $0.id == repo.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(data, forKey: "savedRepositories")
        }
    }

    /// What a new source's address answered with, read off the main thread.
    private struct CheckedSource: Sendable {
        let name: String?
        let iconUrl: String
        let apps: [FSAppModel]
    }

    private func addRepository() async {
        var trimmed = newRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address typed without its scheme is a web address.
        if !trimmed.isEmpty, !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host != nil else {
            showErr("lc.appList.urlInvalidError".loc); return
        }
        // A source is listed once: twice, its apps would show twice everywhere.
        if repos.contains(where: { $0.sourceURL == trimmed }) {
            showErr("lc.flek.sourceAlreadyAdded".loc); return
        }
        await MainActor.run { isAdding = true }
        defer { Task { @MainActor in isAdding = false } }
        do {
            // Not left waiting a minute on an address that does not answer.
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
            // Read as the catalog it is to be, off the main thread, as a big
            // one takes a moment: an object without apps is no source.
            let checked = await Task.detached(priority: .userInitiated) { () -> CheckedSource? in
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let apps = try? SourceAppsListViewModel.decodeCustomRepo(data) else {
                    return nil
                }
                var iconUrl = (json["iconURL"] as? String) ?? ""
                if iconUrl.isEmpty, let meta = json["META"] as? [String: Any] {
                    iconUrl = (meta["repoIcon"] as? String) ?? ""
                }
                return CheckedSource(name: json["name"] as? String, iconUrl: iconUrl, apps: apps)
            }.value
            guard let checked else {
                showErr("lc.flek.invalidSource".loc); return
            }
            // What was read is kept, so that the source shows and is searched
            // at once rather than downloaded again.
            let source = trimmed
            Task.detached(priority: .utility) {
                RepoCatalogCache.shared.store(apps: checked.apps, for: source)
            }
            let repo = AppRepository(name: checked.name ?? url.host ?? trimmed, iconUrl: checked.iconUrl,
                                     sourceURL: trimmed, isSelected: false)
            await MainActor.run {
                repos.append(repo)
                save()
                newRepoURL = ""
            }
        } catch {
            showErr(error.localizedDescription)
        }
    }

    @MainActor private func showErr(_ msg: String) {
        errorMessage = msg
        showError = true
    }
}
