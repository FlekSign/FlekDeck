//
//  FSAppDescription.swift
//  LiveContainerSwiftUI
//
//  App descriptions arrive as HTML from a rich-text editor, and they use it:
//  across a 220-app sample, 302 <b>, 242 <i>, 528 <li>, 100 <h3> and 66 <a>.
//  Flattening all of that to one grey slab loses the headings and bullet lists
//  that make a description readable, so it is parsed into blocks instead.
//
//  Deliberately not NSAttributedString's HTML importer: it must run on the main
//  thread, costs tens of milliseconds per page, and carries the document's own
//  fonts and colours across — which fights the sheet's typography and turns
//  unreadable in dark mode. This keeps every visual decision on our side.
//

import SwiftUI

/// One rendered piece of a description — a paragraph, a heading, or a list item.
struct FSDescriptionBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading
        /// The bullet or number shown in the gutter.
        case listItem(marker: String)
    }

    let id: Int
    let kind: Kind
    let text: AttributedString
}

enum FSDescriptionParser {

    /// Base body size the emitted fonts are derived from.
    static let baseSize: CGFloat = 16

    static func blocks(from source: String, baseSize: CGFloat = baseSize) -> [FSDescriptionBlock] {
        guard hasMarkup(source) else { return plainBlocks(source, baseSize: baseSize) }
        return parse(source, baseSize: baseSize)
    }

    private static func hasMarkup(_ string: String) -> Bool {
        string.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil
    }

    /// A custom repo's description is normally plain text, where the line breaks
    /// *are* the formatting. Keep it as a single block so they survive.
    private static func plainBlocks(_ string: String, baseSize: CGFloat) -> [FSDescriptionBlock] {
        let text = decodeEntities(string).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var attributed = AttributedString(text)
        attributed.font = .system(size: baseSize)
        return [FSDescriptionBlock(id: 0, kind: .paragraph, text: attributed)]
    }

    /// A tag, with its attribute section aware of quoting.
    ///
    /// The attribute run is `"…" | '…' | anything-but-a-delimiter` rather than a
    /// plain `[^>]*`, because an attribute value is allowed to contain `>` —
    /// `<div title="a>b">` would otherwise end the tag early and spill the rest
    /// of it (`b">`) into the visible text. Every branch consumes at least one
    /// character, so the repetition can't backtrack pathologically.
    private static let tagPattern = try! NSRegularExpression(
        pattern: "<\\s*(/?)\\s*([a-zA-Z][a-zA-Z0-9]*)((?:\"[^\"]*\"|'[^']*'|[^>\"'])*)>")

    private static func parse(_ html: String, baseSize: CGFloat) -> [FSDescriptionBlock] {
        var blocks: [FSDescriptionBlock] = []
        var current = AttributedString()
        var kind: FSDescriptionBlock.Kind = .paragraph
        var nextID = 0

        // Inline state. Counters rather than flags, so nested <b><b>…</b></b>
        // doesn't switch bold off halfway through.
        var bold = 0
        var italic = 0
        // Pushed for every <a>, URL or not, so a malformed one can't pop the
        // enclosing link's entry.
        var links: [URL?] = []
        // (ordered, next number) per nesting level.
        var lists: [(ordered: Bool, counter: Int)] = []

        func flush() {
            let trimmed = trimTrailingWhitespace(current)
            if !trimmed.characters.isEmpty {
                blocks.append(FSDescriptionBlock(id: nextID, kind: kind, text: trimmed))
                nextID += 1
            }
            current = AttributedString()
            kind = .paragraph
        }

        /// True at the start of a block and just after a `<br>`, where the
        /// source's own indentation would otherwise show up as a leading space.
        var atLineStart: Bool {
            current.characters.isEmpty || current.characters.last == "\n"
        }

        func appendLineBreak() {
            guard !current.characters.isEmpty else { return }
            var piece = AttributedString("\n")
            piece.font = .system(size: baseSize)
            current += piece
        }

        func append(_ raw: String) {
            var text = decodeEntities(raw)
            // In HTML any run of whitespace — including the newlines these
            // descriptions are full of — collapses to a single space.
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !text.isEmpty else { return }
            if atLineStart {
                while text.first == " " { text.removeFirst() }
                guard !text.isEmpty else { return }
            }

            var piece = AttributedString(text)
            var font = Font.system(size: baseSize)
            if bold > 0 { font = font.weight(.semibold) }
            if italic > 0 { font = font.italic() }
            piece.font = font
            if let url = links.last ?? nil { piece.link = url }
            current += piece
        }

        func open(_ name: String, attributes: String) {
            switch name {
            case "b", "strong": bold += 1
            case "i", "em": italic += 1
            case "a": links.append(linkURL(from: attributes))
            case "br":
                // A line break *inside* the paragraph, not a new block. These
                // descriptions write whole feature lists as one <p> separated by
                // <br>, and splitting there would space every line apart.
                appendLineBreak()
            case "ul", "ol":
                flush()
                lists.append((ordered: name == "ol", counter: 1))
            case "li":
                flush()
                if var list = lists.last {
                    kind = .listItem(marker: list.ordered ? "\(list.counter)." : "•")
                    list.counter += 1
                    lists[lists.count - 1] = list
                } else {
                    // <li> outside a list happens; treat it as a bullet anyway.
                    kind = .listItem(marker: "•")
                }
            case "div", "p", "tr", "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if name.count == 2 && name.hasPrefix("h") { kind = .heading }
            default:
                break
            }
        }

        func close(_ name: String) {
            switch name {
            case "b", "strong": bold = max(0, bold - 1)
            case "i", "em": italic = max(0, italic - 1)
            case "a": if !links.isEmpty { links.removeLast() }
            case "ul", "ol":
                flush()
                if !lists.isEmpty { lists.removeLast() }
            case "li", "div", "p", "tr", "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
            default:
                break
            }
        }

        let ns = html as NSString
        var cursor = 0
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length

            let isClosing = ns.substring(with: match.range(at: 1)) == "/"
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let attributes = match.range(at: 3).location == NSNotFound
                ? "" : ns.substring(with: match.range(at: 3))
            if isClosing { close(name) } else { open(name, attributes: attributes) }
        }
        if cursor < ns.length {
            append(ns.substring(from: cursor))
        }
        flush()

        return blocks
    }

    /// The href of an `<a>`, if it is one we are willing to open.
    ///
    /// Descriptions are third-party content, so only http(s) links are turned
    /// into tappable links — a `javascript:`, `data:` or app-scheme href in a
    /// description must not become something the reader can fire off by tapping
    /// what looks like ordinary text.
    private static func linkURL(from attributes: String) -> URL? {
        let pattern = "href\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let range = attributes.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var href = String(attributes[range])
        guard let valueRange = href.range(of: "[\"']([^\"']*)[\"']$", options: .regularExpression)
        else { return nil }
        href = String(href[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        href = decodeEntities(href).trimmingCharacters(in: .whitespaces)
        guard !href.isEmpty else { return nil }

        // Plenty of these are written bare, e.g. href="iosgods.com", so a
        // missing scheme is assumed to be https. But the scheme has to be
        // recognised *first*: "mailto:a@evil.com" contains no "://", so blindly
        // prepending would turn it into "https://mailto:a@evil.com" — a valid
        // https URL whose host is evil.com, i.e. a web link the author never
        // wrote. A colon followed by digits is a port on a bare host
        // ("example.com:8080"), not a scheme.
        if let schemeRange = href.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression),
           !(href[schemeRange.upperBound...].first?.isNumber ?? false) {
            let scheme = href[schemeRange].dropLast().lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        } else {
            href = "https://" + href
        }

        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var out = string
        let entities = ["&nbsp;": "\u{00A0}", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&apos;": "'", "&hellip;": "…",
                        "&mdash;": "—", "&ndash;": "–", "&bull;": "•"]
        for (entity, character) in entities {
            out = out.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return decodeNumericEntities(out)
    }

    /// `&#8226;` / `&#x2022;` → the character itself.
    ///
    /// Editors emit these for anything outside the handful of named entities
    /// above — bullets and dashes especially — and without this they reach the
    /// reader as literal `&#8226;`.
    private static let numericEntityPattern = try! NSRegularExpression(
        pattern: "&#([xX][0-9a-fA-F]{1,6}|[0-9]{1,7});")

    private static func decodeNumericEntities(_ string: String) -> String {
        guard string.contains("&#") else { return string }
        let ns = string as NSString
        let matches = numericEntityPattern.matches(
            in: string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return string }

        let out = NSMutableString(string: string)
        // Back to front, so each replacement leaves the earlier ranges valid.
        for match in matches.reversed() {
            let token = ns.substring(with: match.range(at: 1))
            let value: UInt32? = (token.first == "x" || token.first == "X")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token)
            guard let value, let scalar = Unicode.Scalar(value) else { continue }
            // Leave control characters alone rather than injecting them into
            // the middle of a paragraph; tab and newline are already handled as
            // whitespace by the caller.
            if value < 0x20 { continue }
            out.replaceCharacters(in: match.range, with: String(Character(scalar)))
        }
        return out as String
    }

    private static func trimTrailingWhitespace(_ text: AttributedString) -> AttributedString {
        var out = text
        while let last = out.characters.last, last.isWhitespace {
            let end = out.endIndex
            out.removeSubrange(out.characters.index(before: end) ..< end)
        }
        while let first = out.characters.first, first.isWhitespace {
            let start = out.startIndex
            out.removeSubrange(start ..< out.characters.index(after: start))
        }
        return out
    }
}
