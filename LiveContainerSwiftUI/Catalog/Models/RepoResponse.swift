//
//  RepoResponse.swift
//  LiveContainer
//
//  Created by Alexander Grigoryev on 28.01.2026.
//
//  A custom repository's catalog. Every third-party repo we ship with is a
//  dialect of the AltStore source format: they agree on a top-level `apps`
//  array and disagree on nearly every field inside it, so each value is read
//  through the spellings that actually turn up in the wild —
//
//    icon         iconURL | icon          (some sources send both)
//    download     downloadURL | down
//    developer    developerName | dev | developer
//    updated      versionDate | date | fullDate ("20260901080057")
//    size         bytes as a number *or* as text ("32862407", "12.4 MB")
//    downloads    appstore_download_count | downloads
//    screenshots  screenshotURLs | screenshots — the latter a flat array, an
//                 array of {imageURL}, or {"iphone": [...], "ipad": [...]},
//                 whose arrays AltStore's own source mixes both forms into
//
//  — and an entry that can't be read is dropped on its own: one malformed app
//  in a catalog of several thousand must not empty the list.
//

import Foundation

struct RepoResponse: Decodable {
    let apps: [RepoApp]

    private enum CodingKeys: String, CodingKey { case apps }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decode([RepoEntry].self, forKey: .apps).compactMap(\.app)
    }
}

/// One element of `apps`, decoded so that it can fail without the array failing
/// with it — see the file header.
private struct RepoEntry: Decodable {
    let app: RepoApp?

    init(from decoder: Decoder) throws {
        app = try? RepoApp(from: decoder)
    }
}

struct RepoApp: Decodable {
    let name: String
    let developerName: String?
    let localizedDescription: String?
    let iconURL: String?
    /// Flattened out of whichever shape the repo used; empty when it has none.
    let screenshotURLs: [String]

    // Flat repos carry the current release on the app itself…
    let version: String?
    let versionDate: String?
    let downloadURL: String?
    /// Bytes.
    let size: Int64?
    /// How many times the repo says the app has been downloaded.
    let downloads: Int?

    // …versioned ones list their releases, newest first.
    let versions: [RepoAppVersion]?

    enum CodingKeys: String, CodingKey {
        case name, developerName, dev, developer
        case localizedDescription
        case appDescription = "description"
        case iconURL, icon
        case screenshots, screenshotURLs
        case version, versionDate, date, fullDate
        case downloadURL, down
        case size, versions
        case downloads
        case downloadCount = "appstore_download_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The one field an entry is useless without.
        name = try container.decode(String.self, forKey: .name)
        developerName = container.text(.developerName, .dev, .developer)
        localizedDescription = container.text(.localizedDescription, .appDescription)
        iconURL = container.text(.iconURL, .icon)
        version = container.text(.version)
        versionDate = container.text(.versionDate, .date, .fullDate)
        downloadURL = container.text(.downloadURL, .down)
        size = container.bytes(.size)
        downloads = container.count(.downloadCount, .downloads)
        // `screenshots` first: a source carrying both writes the current shots
        // there and leaves `screenshotURLs` as the older v1 list.
        screenshotURLs = container.imageURLs(.screenshots, .screenshotURLs)
        versions = try? container.decodeIfPresent([RepoAppVersion].self, forKey: .versions)
    }
}

struct RepoAppVersion: Decodable {
    let absoluteVersion: String?
    let version: String?
    let downloadURL: String?
    let date: String?
    /// Bytes.
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case absoluteVersion, version
        case downloadURL, down
        case date, versionDate
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        absoluteVersion = container.text(.absoluteVersion)
        version = container.text(.version)
        downloadURL = container.text(.downloadURL, .down)
        date = container.text(.date, .versionDate)
        size = container.bytes(.size)
    }
}

// MARK: - Reading a field that is spelled several ways

private extension KeyedDecodingContainer {

    /// The first of `keys` holding usable text.
    ///
    /// A key whose value is the wrong type is skipped rather than throwing:
    /// among these repos a missing field and a field written as `false` or `0`
    /// are the same statement, and neither is worth failing an app over.
    func text(_ keys: Key...) -> String? {
        for key in keys {
            if let string = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                continue
            }
            // Numbers do turn up where the format asks for text — a bare
            // `"version": 2`, or a date written as a Unix timestamp.
            if let number = try? decodeIfPresent(Int64.self, forKey: key) { return String(number) }
            if let number = try? decodeIfPresent(Double.self, forKey: key) { return String(number) }
        }
        return nil
    }

    /// The first of `keys` holding a size, in bytes.
    func bytes(_ keys: Key...) -> Int64? {
        for key in keys {
            if let value = try? decodeIfPresent(Int64.self, forKey: key), value > 0 { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: key), value > 0 { return Int64(value) }
            if let text = try? decodeIfPresent(String.self, forKey: key),
               let value = bytesFromText(text) { return value }
        }
        return nil
    }

    /// The first of `keys` holding a positive whole number.
    func count(_ keys: Key...) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key), value > 0 { return value }
            if let text = try? decodeIfPresent(String.self, forKey: key),
               let value = Int(text), value > 0 { return value }
        }
        return nil
    }

    /// The first of `keys` holding any recognisable list of images.
    func imageURLs(_ keys: Key...) -> [String] {
        for key in keys {
            if let list = try? decodeIfPresent(RepoScreenshotList.self, forKey: key),
               !list.urls.isEmpty { return list.urls }
        }
        return []
    }
}

/// Bytes from a size a repo wrote as text: `"32862407"`, `"12.4 MB"`, `"1,024"`.
private func bytesFromText(_ raw: String) -> Int64? {
    // A comma in front of three digits is a thousands separator ("1,024");
    // any other comma is a decimal point ("12,4 MB").
    let cleaned = raw
        .replacingOccurrences(of: ",(?=[0-9]{3})", with: "", options: .regularExpression)
        .replacingOccurrences(of: ",", with: ".")
        .trimmingCharacters(in: .whitespaces)

    guard let number = cleaned.range(of: "^[0-9]+(\\.[0-9]+)?", options: .regularExpression),
          let value = Double(cleaned[number]), value > 0 else { return nil }

    // Decimal units, to match the ones the size is displayed in — a repo's
    // "12.4 MB" should come back out of the app as 12.4 MB.
    let unit = cleaned[number.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
    let multiplier: Double
    switch unit.first {
    case "k": multiplier = 1_000
    case "m": multiplier = 1_000_000
    case "g": multiplier = 1_000_000_000
    case "t": multiplier = 1_000_000_000_000
    default:  multiplier = 1
    }

    let bytes = value * multiplier
    guard bytes < Double(Int64.max) else { return nil }
    return Int64(bytes)
}

// MARK: - Screenshots

/// The loosest field in the format — see the file header for the shapes.
private struct RepoScreenshotList: Decodable {
    let urls: [String]

    init(from decoder: Decoder) throws {
        if let flat = try? [RepoScreenshot](from: decoder) {
            urls = flat.compactMap(\.url)
            return
        }
        if let byDevice = try? [String: [RepoScreenshot]](from: decoder) {
            // A dictionary's keys arrive in no particular order, so the devices
            // are taken in a fixed one — otherwise which shot the gallery is
            // measured from, and shows first, would vary between launches.
            let preferred = ["iphone", "ipad"]
            func rank(_ key: String) -> Int {
                preferred.firstIndex(of: key.lowercased()) ?? preferred.count
            }
            urls = byDevice
                .sorted { rank($0.key) == rank($1.key) ? $0.key < $1.key : rank($0.key) < rank($1.key) }
                .flatMap { $0.value.compactMap(\.url) }
            return
        }
        urls = []
    }
}

/// One shot: a bare URL, or an object carrying it alongside its dimensions.
private struct RepoScreenshot: Decodable {
    let url: String?

    private enum CodingKeys: String, CodingKey { case imageURL, url }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            url = trimmed.isEmpty ? nil : trimmed
            return
        }
        url = (try? decoder.container(keyedBy: CodingKeys.self))?.text(.imageURL, .url)
    }
}
