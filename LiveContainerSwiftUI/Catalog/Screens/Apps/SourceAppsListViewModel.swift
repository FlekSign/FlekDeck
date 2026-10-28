//
//  SourceAppsListViewModel.swift
//  LiveContainer
//
//  Created by Alexander Grigoryev on 30.09.2025.
//

// SourceAppsListViewModel.swift
import SwiftUI
import QuartzCore

@MainActor
class SourceAppsListViewModel: ObservableObject {
    @Published var apps: [FSAppModel] = [] {
        didSet {
            appsStamp = CACurrentMediaTime()
            // A page append leaves the rows already on screen alone, so only the
            // new tail is a fresh arrival. Anything else (reset, repo/category
            // switch, refresh) is a new batch starting at the first row.
            appsBatchStart = Self.isAppend(oldValue, apps) ? oldValue.count : 0
        }
    }

    /// When `apps` last changed, and where the newest batch starts in it.
    ///
    /// The installer's list uses these to run its row-entrance animation for
    /// freshly arrived rows only — rows the lazy stack rebuilds while the user
    /// scrolls just appear, the way a system list behaves.
    private(set) var appsStamp: TimeInterval = 0
    private(set) var appsBatchStart: Int = 0

    /// Cheap O(1) check for "the new list is the old one plus a page".
    private static func isAppend(_ old: [FSAppModel], _ new: [FSAppModel]) -> Bool {
        guard !old.isEmpty, new.count > old.count else { return false }
        return new[0].id == old[0].id && new[old.count - 1].id == old[old.count - 1].id
    }

    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    /// A repository the user added. There is no built-in catalog, so this is the
    /// only kind there is — and `repository` being nil is a real state rather
    /// than an oversight: a fresh install has no sources at all until one is
    /// added, and nothing should be fetched until then.
    enum RepositorySource: Equatable {
        case custom(url: String)

        var url: String {
            switch self {
            case .custom(let url): return url
            }
        }
    }
    @Published var repository: RepositorySource? = nil

    private func currentEndpoint() -> URL? {
        guard let repository else { return nil }
        return URL(string: repository.url)
    }

    //computed property for search for custom repos
    var visibleApps: [FSAppModel] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.app_name.localizedCaseInsensitiveContains(query)
        }
    }
    
    @Published var searchQuery: String = ""
     

    // Pagination
    private var currentPage = 0
    private var canLoadMore = true
    
    // Debounce task for search
    private var searchDebounceTask: Task<Void, Never>?
    
    // Public: call this when user types in the TextField (from the View `.onChange`)
    func debounceSearch(_ newQuery: String) {
        // Cancel any pending debounce
        searchDebounceTask?.cancel()
        
        // Schedule new debounce
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms
            guard !Task.isCancelled else { return }
            await self?.resetAndFetchApps()
        }
    }
    
    // Reset paging and fetch first page
    // Monotonic token so a fresh reset/search always supersedes an in-flight page
    // load instead of being dropped by it (or clobbering its results).
    private var loadGeneration = 0

    func resetAndFetchApps() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        currentPage = 0
        canLoadMore = true
        apps = []
        isLoading = false   // a stale in-flight page load must not block this reset
        await fetchApps(generation: generation)
    }
    
    // Fetch next page (pagination entry point)
    func fetchApps() async {
        await fetchApps(generation: loadGeneration)
    }

    /// Pull-to-refresh: reload the first page *in place*.
    ///
    /// `resetAndFetchApps` empties the list before the request goes out, which
    /// collapses the whole list under the refresh spinner and snaps the scroll
    /// offset back to the top. Here the visible rows stay put and are swapped for
    /// the fresh ones when they land, so unchanged rows never move.
    func refreshCurrentRepository() async {
        guard !apps.isEmpty else {
            await resetAndFetchApps()
            return
        }
        // Supersede any in-flight page load, and drop its `isLoading` claim with
        // it — that load will be discarded on return and would otherwise leave
        // pagination blocked forever.
        guard let repository else { return }
        loadGeneration &+= 1
        isLoading = false
        await silentRefresh(expecting: repository)
    }

    private func fetchApps(generation: Int) async {
        guard !isLoading, canLoadMore else { return }
        guard generation == loadGeneration else { return }
        isLoading = true
        errorMessage = nil

        guard let repository, currentEndpoint() != nil else {
            errorMessage = "Invalid repository URL"
            isLoading = false
            return
        }

        do {
            // Through the loader, which search and the refresh at launch share,
            // so that a source is downloaded once whoever asks, and read off
            // the main thread.
            guard let mappedApps = await RepoCatalogLoader.shared.catalog(for: repository.url) else {
                throw URLError(.cannotLoadFromNetwork)
            }
            // A newer load may have started meanwhile.
            guard generation == loadGeneration else { return }

            apps = mappedApps
            canLoadMore = false
        } catch {
            if generation == loadGeneration {
                errorMessage = "lc.flek.loadFailed".loc
            }
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    // MARK: - Instant source switching

    /// In-memory cache of the last-shown apps per source, so switching back to a
    /// source shows its list instantly instead of reloading from scratch.
    private var memoryCache: [String: [FSAppModel]] = [:]

    /// Whether the source's last-shown list is held in memory.
    func hasMemoryCache(for source: RepositorySource) -> Bool {
        memoryCache[repoCacheKey(source)] != nil
    }

    private func repoCacheKey(_ source: RepositorySource) -> String { source.url }

    /// Switch to `source` and show its apps immediately from cache (in-memory or
    /// the provided disk cache), refreshing in the background. Only falls back to
    /// an empty loading state when there is nothing cached to show.
    func switchRepository(to source: RepositorySource, diskPreloaded: [FSAppModel]? = nil) async {
        // Save the outgoing list so switching back to it is instant.
        if let outgoing = repository, !apps.isEmpty {
            memoryCache[repoCacheKey(outgoing)] = apps
        }

        // A load still under way is the source being left's: it must not land
        // on the new one, nor keep it from loading.
        loadGeneration &+= 1
        isLoading = false
        errorMessage = nil

        repository = source
        searchQuery = ""
        currentPage = 0
        canLoadMore = true

        if let preloaded = memoryCache[repoCacheKey(source)] ?? diskPreloaded, !preloaded.isEmpty {
            apps = preloaded
            // A kept list can run to several pages: none is asked for until the
            // refresh has said where the first one ends, or a page already
            // shown would be added again.
            canLoadMore = false
            await silentRefresh(expecting: source)
        } else {
            apps = []
            await fetchApps()
        }
    }

    /// Re-fetches the first page and replaces the list without clearing it first,
    /// so the visible cached apps don't flash to an empty loading state.
    private func silentRefresh(expecting source: RepositorySource) async {
        // A search or another source meanwhile supersedes it.
        let generation = loadGeneration
        // The loader keeps the catalog on disk itself; a failure keeps the
        // cached list.
        guard let mapped = await RepoCatalogLoader.shared.catalog(for: source.url),
              generation == loadGeneration, repository == source else { return }
        apps = mapped
        canLoadMore = false
        memoryCache[repoCacheKey(source)] = mapped
    }

    //since alt store doesnt provide data if app is adult or not make them all non adult by default
    nonisolated static func decodeCustomRepo(_ data: Data) throws -> [FSAppModel] {
        let response = try JSONDecoder().decode(RepoResponse.self, from: data)

        return response.apps.enumerated().compactMap { index, app in
            // A versioned repo lists its releases newest first; a flat one puts
            // the current release on the app itself. The newest release that
            // can actually be downloaded wins — a repo that lists an entry
            // without a download URL should fall through to the next one
            // rather than lose the app.
            let release = app.versions?.first { $0.downloadURL != nil }
            guard let installURL = release?.downloadURL ?? app.downloadURL else { return nil }

            // Everything the catalog says about the app, carried on the row:
            // custom repos have no detail page behind them, so this listing is
            // all its app page will ever have to show.
            return FSAppModel(
                app_id: index,
                app_icon: app.iconURL ?? "",
                app_name: app.name,
                app_version: release?.absoluteVersion ?? release?.version ?? app.version ?? "Unknown",
                app_short_description: app.localizedDescription ?? "",
                app_isAdult: 0,
                install_url: installURL,
                app_developer: app.developerName,
                app_size: release?.size ?? app.size,
                app_date: release?.date ?? app.versionDate,
                app_downloads: app.downloads,
                app_screenshots: app.screenshotURLs.isEmpty ? nil : app.screenshotURLs
            )
        }
    }

}
