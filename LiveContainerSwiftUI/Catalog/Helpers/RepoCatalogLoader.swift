//
//  RepoCatalogLoader.swift
//  LiveContainerSwiftUI
//
//  Downloads custom sources' catalogs for search, for its refresh at launch and
//  for browsing a source: one download per source at a time, whoever asks, read
//  off the main thread and kept in RepoCatalogCache once it has come. Search
//  waits on a source for a few seconds only and goes on without it, while the
//  download carries on, so that the source is there for the next search, or
//  for the same one if its query is still shown. A source that failed is left
//  alone by search for a while, so that a source that keeps a request open, or
//  answers with a page that is no catalog, does not hold up every keystroke.
//

import Foundation

actor RepoCatalogLoader {
    static let shared = RepoCatalogLoader()

    /// How a source answered a search that waits a limited time on it.
    enum Arrival: Sendable {
        case arrived([FSAppModel])
        /// It failed, now or a short while ago.
        case failed
        /// Still coming when the search stopped waiting. The download goes on,
        /// and this is what its catalog arrives by, nil where it fails.
        case tooSlow(Task<[FSAppModel]?, Never>)
    }

    /// How long search leaves a source that failed alone.
    private static let failureMemory: TimeInterval = 5 * 60

    /// A download gives up on a source that stays silent for 30 seconds, or
    /// takes two minutes in all: long enough for a big catalog over a slow
    /// connection, which nobody is kept waiting on.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    private struct Download {
        let task: Task<Result<[FSAppModel], Error>, Never>
        let startedAt: Date
    }

    private var inFlight: [String: Download] = [:]
    private var failedAt: [String: Date] = [:]

    /// Whether the source failed lately, and is not to be asked again yet.
    func hasFailedRecently(_ url: String) -> Bool {
        guard let date = failedAt[url] else {
            return false
        }
        if Date().timeIntervalSince(date) < Self.failureMemory {
            return true
        }
        failedAt[url] = nil
        return false
    }

    /// How long the source's download has been running, nil while none is.
    func runningTime(for url: String) -> TimeInterval? {
        inFlight[url].map { Date().timeIntervalSince($0.startedAt) }
    }

    /// The source's catalog, from a download started now or the one already
    /// under way for it. Nil where the source failed.
    func catalog(for url: String) async -> [FSAppModel]? {
        if let download = inFlight[url] {
            return try? await download.task.value.get()
        }
        let task = Task.detached(priority: .utility) {
            await Self.download(url)
        }
        inFlight[url] = Download(task: task, startedAt: Date())
        let result = await task.value
        inFlight[url] = nil
        switch result {
        case .success(let apps):
            failedAt[url] = nil
            // Kept even empty, so that a catalog that has emptied does not go
            // on showing its old apps. Written apart from the loader, which a
            // big catalog's writing would otherwise hold up for everyone.
            Task.detached(priority: .utility) {
                RepoCatalogCache.shared.store(apps: apps, for: url)
            }
            return apps
        case .failure(let error):
            // Not for a failure that says nothing of the source, such as no
            // connection for a moment: the source would be left out for
            // minutes after the connection is back.
            if !Self.saysNothingOfTheSource(error) {
                failedAt[url] = Date()
            }
            return nil
        }
    }

    /// The source's catalog if it comes within `limit` seconds, counting the
    /// time its download has already been running: a search after one that
    /// gave up on it does not wait the whole time again. A cancelled wait ends
    /// at once, and the download goes on.
    nonisolated static func catalog(for url: String, within limit: TimeInterval) async -> Arrival {
        if await shared.hasFailedRecently(url) {
            return .failed
        }
        let wait = max(0, limit - (await shared.runningTime(for: url) ?? 0))
        let fetch = Task {
            await shared.catalog(for: url)
        }
        let answer = FirstAnswer<Arrival>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.deliver { continuation.resume(returning: $0) }
                Task {
                    let apps = await fetch.value
                    answer.give(apps.map { .arrived($0) } ?? .failed)
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    answer.give(.tooSlow(fetch))
                }
            }
        } onCancel: {
            answer.give(.tooSlow(fetch))
        }
    }

    private static func download(_ url: String) async -> Result<[FSAppModel], Error> {
        guard let address = URL(string: url) else {
            return .failure(URLError(.badURL))
        }
        do {
            let (data, _) = try await session.data(from: address)
            return .success(try SourceAppsListViewModel.decodeCustomRepo(data))
        } catch {
            return .failure(error)
        }
    }

    /// Failures that come from this device's connection rather than from the
    /// source.
    private static func saysNothingOfTheSource(_ error: Error) -> Bool {
        guard let error = error as? URLError else {
            return false
        }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cancelled, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }
}

/// Passes on the first answer it is given and drops the rest, for a wait that
/// a result, a timer and a cancellation race to end. An answer given before
/// there is anywhere to deliver it is kept until there is.
final class FirstAnswer<Answer>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Answer) -> Void)?
    private var waitingAnswer: Answer?
    private var hasWaitingAnswer = false
    private var isAnswered = false

    func deliver(to handler: @escaping (Answer) -> Void) {
        lock.lock()
        guard !isAnswered else {
            lock.unlock()
            return
        }
        if hasWaitingAnswer, let answer = waitingAnswer {
            isAnswered = true
            waitingAnswer = nil
            lock.unlock()
            handler(answer)
            return
        }
        self.handler = handler
        lock.unlock()
    }

    func give(_ answer: Answer) {
        lock.lock()
        guard !isAnswered, !hasWaitingAnswer else {
            lock.unlock()
            return
        }
        guard let handler else {
            waitingAnswer = answer
            hasWaitingAnswer = true
            lock.unlock()
            return
        }
        isAnswered = true
        self.handler = nil
        lock.unlock()
        handler(answer)
    }
}
