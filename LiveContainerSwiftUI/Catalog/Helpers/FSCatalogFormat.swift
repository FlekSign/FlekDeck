//
//  FSCatalogFormat.swift
//  LiveContainerSwiftUI
//
//  Sizes and dates as the app page shows them, in one place so that a chip
//  reads the same whether the value came from a versioned release entry or
//  from a custom repo's catalog.
//
//  The date is the reason this exists: some repos send ISO-8601 with fractional
//  seconds, but a repo writes whatever its generator produced — an ISO stamp
//  with an offset, a bare day, or a run of digits — and all of them have to end
//  up as the same "10 Aug 2026" beside it.
//

import Foundation

enum FSCatalogFormat {

    /// "45.1 MB". Nil when the source didn't say, so the chip is left out
    /// rather than shown holding a zero.
    static func size(bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return byteFormatter.string(fromByteCount: bytes)
    }

    /// "10 Aug 2026" — month names follow the user's locale.
    static func date(_ raw: String?) -> String? {
        guard let raw, let parsed = parse(raw) else { return nil }
        return displayFormatter.string(from: parsed)
    }

    // MARK: Parsing

    private static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let date = isoWithFraction.date(from: text) { return date }
        if let date = iso.date(from: text) { return date }

        // All-digit dates: the run-together stamp some sources send
        // ("20260901080057"), and Unix timestamps. Told apart by length rather
        // than by trying each in turn, because a timestamp's leading digits are
        // a readable date of their own — "1755012345" would otherwise pass for
        // the 23rd of January 1755.
        if text.allSatisfy(\.isNumber), let value = TimeInterval(text) {
            switch text.count {
            case 14: return compactStamp.date(from: text)
            case 13: return Date(timeIntervalSince1970: value / 1000)
            case 10: return Date(timeIntervalSince1970: value)
            case 8:  return compactDay.date(from: text)
            default: return nil
            }
        }

        // A bare day. Read in the reader's own time zone, as the stamps above
        // are: it carries no zone of its own, and taking it as UTC would show
        // the day before to everyone west of it.
        return day.date(from: text)
    }

    // MARK: Formatters

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return formatter
    }()

    /// Fractional-seconds ISO-8601: "2026-08-12T19:33:00.000Z".
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The same without them, and with any offset: "2026-03-01T03:47:43+00:00".
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let day = fixedFormat("yyyy-MM-dd")
    private static let compactStamp = fixedFormat("yyyyMMddHHmmss")
    private static let compactDay = fixedFormat("yyyyMMdd")

    /// A parser for one exact pattern: POSIX locale, so it reads the same under
    /// a non-Gregorian regional calendar, and non-lenient, so a pattern that
    /// doesn't fit is rejected instead of being bent into a wrong date.
    private static func fixedFormat(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

extension FSAppModel {
    /// Only a custom repo's rows carry these — see `FSAppModel`.
    var formattedSize: String? { FSCatalogFormat.size(bytes: app_size) }
    var formattedDate: String? { FSCatalogFormat.date(app_date) }

    var formattedDownloads: String? {
        guard let app_downloads, app_downloads > 0 else { return nil }
        return String(app_downloads)
    }
}
