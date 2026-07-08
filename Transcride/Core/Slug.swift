import Foundation

/// Converts an entry title into a folder-name slug: lowercase, hyphens for
/// separators, punctuation stripped, capped at ~40 characters.
enum Slug {
    static let maxLength = 40

    static func make(from title: String, maxLength: Int = Slug.maxLength) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var out = ""
        var lastWasHyphen = true // suppress leading hyphens
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }

        if out.count > maxLength {
            out = String(out.prefix(maxLength))
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
