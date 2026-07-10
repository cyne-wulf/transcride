import Foundation

/// A `transcript.md` document: YAML frontmatter (flat `key: value` scalars) plus
/// the markdown body. Parsing is line-preserving — untouched lines (including
/// unknown keys and lines we can't parse) are written back byte-for-byte, so
/// externally edited files are never "corrected" by the app.
struct FrontmatterDocument: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        /// Parsed key if the line looks like `key: value`, else nil.
        var key: String?
        /// Raw (still-quoted) value text for parsed lines.
        var rawValue: String?
        /// The exact original or regenerated line, without trailing newline.
        var line: String
    }

    var fields: [Field]
    /// Everything after the closing `---` line, verbatim.
    var body: String

    /// True when the document had (or now has) a frontmatter block.
    var hasFrontmatter: Bool { !fields.isEmpty }

    // MARK: - Parse / serialize

    static func parse(_ text: String) -> FrontmatterDocument {
        guard text.hasPrefix("---\n") else {
            return FrontmatterDocument(fields: [], body: text)
        }
        let rest = text.dropFirst(4)
        let header: Substring
        let body: Substring
        if let close = rest.range(of: "\n---\n") {
            header = rest[..<close.lowerBound]
            body = rest[close.upperBound...]
        } else if rest.hasSuffix("\n---") {
            header = rest.dropLast(4)
            body = ""
        } else {
            // Unclosed frontmatter — treat the whole file as body, never rewrite it.
            return FrontmatterDocument(fields: [], body: text)
        }

        var fields: [Field] = []
        // An empty header is "---\n---\n" → one empty line? Avoid emitting a phantom field.
        if !header.isEmpty {
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                fields.append(Self.parseLine(String(line)))
            }
        }
        return FrontmatterDocument(fields: fields, body: String(body))
    }

    private static func parseLine(_ line: String) -> Field {
        if let match = line.wholeMatch(of: /([A-Za-z0-9_-]+):[ \t]*(.*)/) {
            return Field(key: String(match.1), rawValue: String(match.2), line: line)
        }
        return Field(key: nil, rawValue: nil, line: line)
    }

    func serialized() -> String {
        guard hasFrontmatter else { return body }
        var out = "---\n"
        for field in fields {
            out += field.line + "\n"
        }
        out += "---\n"
        out += body
        return out
    }

    // MARK: - Raw value access

    func rawValue(for key: String) -> String? {
        fields.first(where: { $0.key == key })?.rawValue
    }

    /// Unquoted scalar value for a key, or nil when absent/blank.
    func value(for key: String) -> String? {
        guard let raw = rawValue(for: key) else { return nil }
        let unquoted = Self.unquote(raw)
        return unquoted.isEmpty ? nil : unquoted
    }

    /// Sets `key: value`. Pass `quoted: true` for free-form user text (titles).
    /// Pass nil to remove the field.
    mutating func setValue(_ value: String?, for key: String, quoted: Bool = false) {
        guard let value else {
            fields.removeAll { $0.key == key }
            return
        }
        let raw = quoted ? Self.quote(value) : value
        let line = "\(key): \(raw)"
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index] = Field(key: key, rawValue: raw, line: line)
        } else {
            fields.append(Field(key: key, rawValue: raw, line: line))
        }
    }

    // MARK: - Quoting

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        // Strip a trailing YAML comment from plain scalars: `value # comment`
        if let hash = trimmed.range(of: " #") {
            return String(trimmed[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

// MARK: - Typed accessors for the entry contract

extension FrontmatterDocument {
    var title: String? {
        get { value(for: "title") }
        set { setValue(newValue, for: "title", quoted: true) }
    }

    var created: Date? {
        get { value(for: "created").flatMap(FrontmatterDate.parse) }
        set { setValue(newValue.map(FrontmatterDate.format), for: "created") }
    }

    var duration: Double? {
        get { value(for: "duration").flatMap(Double.init) }
        set { setValue(newValue.map { String(format: "%.2f", $0) }, for: "duration") }
    }

    /// Favorite flag (LIB-3). Clearing removes the key rather than writing
    /// `false`, so ordinary entries never carry it; Obsidian parses the bare
    /// `true` as a real boolean property.
    var favorite: Bool {
        get { Self.bool(value(for: "favorite")) }
        set { setValue(newValue ? "true" : nil, for: "favorite") }
    }

    /// Set when the entry's audio was deleted (AUD-1). Clearing removes the
    /// key rather than writing `false`, so ordinary entries never carry it.
    var audioDeleted: Bool {
        get { Self.bool(value(for: "audio_deleted")) }
        set { setValue(newValue ? "true" : nil, for: "audio_deleted") }
    }

    var source: String? {
        get { value(for: "source") }
        set { setValue(newValue, for: "source") }
    }

    var engine: String? {
        get { value(for: "engine") }
        set { setValue(newValue, for: "engine") }
    }

    /// An explicit fork marker for the editable layer. Absence is distinct
    /// from false: entries do not show an Original/Edited badge until the
    /// first real edit. Clearing the fork removes the key rather than writing
    /// `false`, preserving that distinction.
    var handEdited: Bool {
        get { Self.bool(value(for: "hand_edited")) }
        set { setValue(newValue ? "true" : nil, for: "hand_edited") }
    }

    private static func bool(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["true", "yes", "1", "on"].contains(value.lowercased())
    }
}

/// Frontmatter date scalars: written as ISO 8601 with the local UTC offset
/// (`2026-07-08T14:32:05+02:00`), parsed leniently so externally edited
/// values (date-only, space separator, Z suffix) still work.
enum FrontmatterDate {
    static func format(_ date: Date) -> String {
        let tz = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = tz.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let absOffset = abs(offset)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                      sign, absOffset / 3600, (absOffset % 3600) / 60)
    }

    static func parse(_ string: String) -> Date? {
        let pattern = /(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?/
        guard let match = string.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else {
            return nil
        }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = match.4.flatMap { Int($0) } ?? 0
        components.minute = match.5.flatMap { Int($0) } ?? 0
        components.second = match.6.flatMap { Int($0) } ?? 0

        var calendar = Calendar(identifier: .gregorian)
        if let zone = match.7 {
            if zone == "Z" {
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            } else {
                let cleaned = zone.replacingOccurrences(of: ":", with: "")
                let sign = cleaned.hasPrefix("-") ? -1 : 1
                let digits = cleaned.dropFirst()
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = Int(digits.suffix(2)) ?? 0
                calendar.timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))!
            }
        } else {
            calendar.timeZone = TimeZone.current
        }
        return calendar.date(from: components)
    }
}
