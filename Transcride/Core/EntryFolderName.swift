import Foundation

/// The canonical name of an entry folder: `transcride-<timestamp>` optionally
/// suffixed with `-<slug>` after a rename, e.g. `transcride-2026-07-08T14-32-05-morning-thoughts`.
/// The timestamp prefix is the entry's stable identity and never changes.
struct EntryFolderName: Hashable, Sendable {
    static let prefix = "transcride-"
    static let timestampLength = 19 // "2026-07-08T14-32-05"

    /// Raw timestamp component, e.g. "2026-07-08T14-32-05".
    let timestamp: String
    /// Optional slug appended after a rename. Never empty when present.
    let slug: String?

    /// Full folder name string.
    var string: String {
        if let slug { return "\(Self.prefix)\(timestamp)-\(slug)" }
        return "\(Self.prefix)\(timestamp)"
    }

    /// The date encoded in the timestamp (interpreted in the local time zone).
    var date: Date? { Self.date(fromTimestamp: timestamp) }

    /// Parses a folder name; returns nil if it is not a valid entry folder name.
    init?(parsing name: String) {
        guard name.hasPrefix(Self.prefix) else { return nil }
        let rest = name.dropFirst(Self.prefix.count)
        guard rest.count >= Self.timestampLength else { return nil }
        let ts = String(rest.prefix(Self.timestampLength))
        guard Self.isValidTimestamp(ts) else { return nil }
        let remainder = rest.dropFirst(Self.timestampLength)
        if remainder.isEmpty {
            self.slug = nil
        } else if remainder.hasPrefix("-"), remainder.count > 1 {
            self.slug = String(remainder.dropFirst())
        } else {
            return nil
        }
        self.timestamp = ts
    }

    /// Creates a name for a new entry recorded/created at `date`.
    init(date: Date, slug: String? = nil) {
        self.timestamp = Self.timestamp(from: date)
        self.slug = (slug?.isEmpty == false) ? slug : nil
    }

    private init(timestamp: String, slug: String?) {
        self.timestamp = timestamp
        self.slug = slug
    }

    /// Same identity (timestamp), different slug. Pass nil/empty to drop the slug.
    func with(slug: String?) -> EntryFolderName {
        EntryFolderName(timestamp: timestamp, slug: (slug?.isEmpty == false) ? slug : nil)
    }

    // MARK: - Timestamp conversion

    static func isValidTimestamp(_ ts: String) -> Bool {
        guard let match = ts.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})/) else {
            return false
        }
        guard let month = Int(match.2), let day = Int(match.3),
              let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6) else {
            return false
        }
        return (1...12).contains(month) && (1...31).contains(day)
            && hour < 24 && minute < 60 && second < 60
    }

    static func timestamp(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d-%02d-%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func date(fromTimestamp ts: String) -> Date? {
        guard let match = ts.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})/) else {
            return nil
        }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = Int(match.4)
        components.minute = Int(match.5)
        components.second = Int(match.6)
        return Calendar.current.date(from: components)
    }
}
