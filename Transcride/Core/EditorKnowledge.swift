import Foundation

struct EditorWikiLink: Equatable, Sendable {
    var range: EditorUTF16Range
    var target: String
    var alias: String?

    var displayText: String { alias ?? target }
}

enum EditorWikiLinkParser {
    static func links(in body: String) -> [EditorWikiLink] {
        let expression = try! NSRegularExpression(pattern: #"\[\[([^\]\r\n]+)\]\]"#)
        let nsBody = body as NSString
        return expression.matches(
            in: body,
            range: NSRange(location: 0, length: nsBody.length)
        ).compactMap { match in
            // Embeds are deliberately preserved as inert source.
            if match.range.location > 0,
               nsBody.substring(with: NSRange(location: match.range.location - 1, length: 1)) == "!" {
                return nil
            }
            let content = nsBody.substring(with: match.range(at: 1))
            let pieces = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            let alias: String? = pieces.count == 2
                ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            return EditorWikiLink(
                range: EditorUTF16Range(
                    from: match.range.location,
                    to: NSMaxRange(match.range)
                ),
                target: target,
                alias: alias?.isEmpty == true ? nil : alias
            )
        }
    }
}

enum EditorExternalLinkPolicy {
    static func allowedURL(_ destination: String) -> URL? {
        guard let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}

struct EditorWikiLinkCandidate: Equatable, Hashable, Sendable {
    var relativePath: String
    var title: String
    var modified: Date

    var parentPath: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }
}

struct EditorWikiLinkResolution: Equatable, Sendable {
    var candidate: EditorWikiLinkCandidate
    /// All title matches in deterministic winner order. More than one means the
    /// UI should explain that the selected target was ambiguous.
    var titleMatches: [EditorWikiLinkCandidate]

    var isAmbiguous: Bool { titleMatches.count > 1 }
}

/// Immutable, deterministic vault index built only when the vault snapshot
/// changes. Resolving links while a note is edited is O(links + matches), not
/// O(links × vault entries).
struct EditorWikiLinkIndex: Equatable, Sendable {
    private var candidatesByTitle: [String: [EditorWikiLinkCandidate]]

    init(candidates: [EditorWikiLinkCandidate]) {
        candidatesByTitle = Dictionary(grouping: candidates) {
            EditorWikiLinkResolver.normalized($0.title)
        }.mapValues { $0.sorted(by: EditorWikiLinkResolver.winnerComesFirst) }
    }

    func resolve(_ link: EditorWikiLink) -> EditorWikiLinkResolution? {
        resolve(target: link.target)
    }

    func resolve(target: String) -> EditorWikiLinkResolution? {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains("#"), !target.contains("^") else { return nil }
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard let titleComponent = components.last, !titleComponent.isEmpty,
              let titleMatches = candidatesByTitle[
                EditorWikiLinkResolver.normalized(String(titleComponent))
              ], !titleMatches.isEmpty else { return nil }
        if components.count > 1 {
            let folder = EditorWikiLinkResolver.normalized(
                components.dropLast().joined(separator: "/")
            )
            let qualified = titleMatches.filter {
                EditorWikiLinkResolver.normalized($0.parentPath) == folder
            }
            if qualified.count == 1 {
                return EditorWikiLinkResolution(candidate: qualified[0], titleMatches: qualified)
            }
        }
        return EditorWikiLinkResolution(candidate: titleMatches[0], titleMatches: titleMatches)
    }
}

enum EditorWikiLinkResolver {
    static func resolve(
        _ link: EditorWikiLink,
        among candidates: [EditorWikiLinkCandidate]
    ) -> EditorWikiLinkResolution? {
        resolve(target: link.target, among: candidates)
    }

    static func resolve(
        target: String,
        among candidates: [EditorWikiLinkCandidate]
    ) -> EditorWikiLinkResolution? {
        EditorWikiLinkIndex(candidates: candidates).resolve(target: target)
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    fileprivate static func winnerComesFirst(
        _ lhs: EditorWikiLinkCandidate,
        _ rhs: EditorWikiLinkCandidate
    ) -> Bool {
        if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
        let left = normalized(lhs.relativePath)
        let right = normalized(rhs.relativePath)
        let comparison = left.compare(
            right,
            options: [.numeric],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.relativePath < rhs.relativePath
    }
}

struct EditorTag: Codable, Equatable, Hashable, Sendable {
    var canonical: String
    var display: String
}

enum EditorTagExtractor {
    /// Extracts body tags plus YAML tags from a complete Markdown document.
    static func extract(markdown: String) -> [EditorTag] {
        let split = splitFrontmatter(markdown)
        return extract(body: split.body, frontmatter: split.frontmatter)
    }

    /// `frontmatter` may include or omit the surrounding `---` lines.
    static func extract(body: String, frontmatter: String? = nil) -> [EditorTag] {
        var displayByCanonical: [String: String] = [:]
        var order: [String] = []

        func add(_ display: String) {
            let stripped = display.hasPrefix("#") ? String(display.dropFirst()) : display
            guard isValidTag(stripped) else { return }
            let canonical = canonicalize(stripped)
            guard displayByCanonical[canonical] == nil else { return }
            displayByCanonical[canonical] = stripped
            order.append(canonical)
        }

        for tag in bodyTags(body) { add(tag) }
        if let frontmatter {
            for tag in yamlTags(frontmatter) { add(tag) }
        }
        return order.compactMap { canonical in
            displayByCanonical[canonical].map { EditorTag(canonical: canonical, display: $0) }
        }
    }

    static func canonicalize(_ tag: String) -> String {
        let withoutMarker = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        return withoutMarker.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Empty selection means no tag restriction. Otherwise tags use OR, and a
    /// selected parent matches itself and any slash-delimited descendant.
    static func matchesAny(entryTags: some Sequence<String>, selectedTags: some Sequence<String>) -> Bool {
        let entries = entryTags.map(canonicalize)
        let selected = selectedTags.map(canonicalize)
        guard !selected.isEmpty else { return true }
        return selected.contains { parent in
            entries.contains { candidate in
                candidate == parent || candidate.hasPrefix(parent + "/")
            }
        }
    }

    static func matchesAny(entryTags: [EditorTag], selectedTags: some Sequence<String>) -> Bool {
        matchesAny(entryTags: entryTags.map(\.canonical), selectedTags: selectedTags)
    }

    private static func bodyTags(_ body: String) -> [String] {
        var result: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let characters = Array(line)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // Fence state is carried by the sentinel below.
            }
            result.append(contentsOf: tagsInLine(characters))
        }

        // The per-line scanner handles inline code and links. Remove anything
        // found inside fenced regions in a second, explicit pass.
        result.removeAll()
        var fence: Character?
        var fenceLength = 0
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if fence == nil {
                        fence = marker
                        fenceLength = count
                        continue
                    } else if fence == marker, count >= fenceLength {
                        fence = nil
                        fenceLength = 0
                        continue
                    }
                }
            }
            guard fence == nil else { continue }
            result.append(contentsOf: tagsInLine(Array(line)))
        }
        return result
    }

    private static func tagsInLine(_ characters: [Character]) -> [String] {
        var result: [String] = []
        var index = 0
        var inlineCodeDelimiter = 0
        while index < characters.count {
            if characters[index] == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                if inlineCodeDelimiter == 0 { inlineCodeDelimiter = count }
                else if count == inlineCodeDelimiter { inlineCodeDelimiter = 0 }
                continue
            }
            guard inlineCodeDelimiter == 0 else { index += 1; continue }

            if characters[index] == "[", index + 1 < characters.count, characters[index + 1] == "[" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "]" && characters[index + 1] == "]") { index += 1 }
                index = min(characters.count, index + 2)
                continue
            }
            if characters[index] == "]", index + 1 < characters.count, characters[index + 1] == "(" {
                index += 2
                var depth = 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
                continue
            }

            guard characters[index] == "#" else { index += 1; continue }
            let slashCount = characters[..<index].reversed().prefix(while: { $0 == "\\" }).count
            let hasInvalidPrefix = index > 0 && isTagCharacter(characters[index - 1])
            guard slashCount.isMultiple(of: 2), !hasInvalidPrefix else { index += 1; continue }

            var end = index + 1
            while end < characters.count, isTagCharacter(characters[end]) { end += 1 }
            let tag = String(characters[(index + 1)..<end])
            if isValidTag(tag) { result.append(tag) }
            index = max(end, index + 1)
        }
        return result
    }

    private static func yamlTags(_ yaml: String) -> [String] {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var collectingBlock = false
        var blockIndent = 0

        for line in lines {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed.isEmpty { continue }

            if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                if key.compare("tags", options: .caseInsensitive) == .orderedSame {
                    collectingBlock = true
                    blockIndent = indent
                    let value = String(trimmed[trimmed.index(after: colon)...])
                    result.append(contentsOf: yamlTagTokens(value))
                    continue
                }
            }

            if collectingBlock, indent > blockIndent, trimmed.hasPrefix("-") {
                result.append(contentsOf: yamlTagTokens(String(trimmed.dropFirst())))
            } else if collectingBlock, indent <= blockIndent {
                collectingBlock = false
            }
        }
        return result
    }

    private static func yamlTagTokens(_ value: String) -> [String] {
        var result: [String] = []
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            if characters[index] == "#" { index += 1 }
            let start = index
            while index < characters.count, isTagCharacter(characters[index]) { index += 1 }
            if index > start {
                let token = String(characters[start..<index])
                if isValidTag(token) { result.append(token) }
            } else {
                index += 1
            }
        }
        return result
    }

    private static func isTagCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "/"
    }

    private static func isValidTag(_ tag: String) -> Bool {
        guard !tag.isEmpty,
              tag.allSatisfy(isTagCharacter),
              !tag.hasPrefix("/"),
              !tag.hasSuffix("/"),
              !tag.contains("//")
        else { return false }
        return tag.contains { !$0.isNumber && $0 != "/" }
    }

    private static func splitFrontmatter(_ markdown: String) -> (frontmatter: String?, body: String) {
        guard markdown.hasPrefix("---\n") || markdown.hasPrefix("---\r\n") else {
            return (nil, markdown)
        }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else { return (nil, markdown) }
        let yaml = lines[...closing].joined(separator: "\n")
        let body = lines.index(after: closing) < lines.endIndex
            ? lines[lines.index(after: closing)...].joined(separator: "\n")
            : ""
        return (yaml, body)
    }
}
