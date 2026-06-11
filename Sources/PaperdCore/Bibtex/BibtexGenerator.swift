import Foundation

/// bibtexの動的生成（→ docs/02-data-model.md 2節）
public struct BibtexGenerator: Sendable {
    public struct Options: Sendable {
        /// 非ASCII文字をASCIIへ変換する（既定はbiblatex前提でそのまま出力）
        public var asciiMode: Bool
        /// 取得元提供の生BibTeX（bibtex_cached）を優先する
        public var preferCachedBibtex: Bool

        public init(asciiMode: Bool = false, preferCachedBibtex: Bool = false) {
            self.asciiMode = asciiMode
            self.preferCachedBibtex = preferCachedBibtex
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - エントリタイプ決定（→ docs/02 2.1）

    public static func entryType(for paper: Paper) -> BibtexType {
        if paper.journal != nil { return .article }
        if paper.booktitle != nil { return .inproceedings }
        return .misc
    }

    // MARK: - citation key（→ docs/02 2.2）

    /// `{第一著者の姓(小文字, ASCII化)}{年}{タイトル先頭の内容語(小文字)}`
    /// 重複時は `a`, `b`, ... を末尾に付与する。
    public static func citationKey(
        title: String,
        firstAuthor: String?,
        year: Int?,
        existingKeys: Set<String> = [],
        override: String? = nil
    ) -> String {
        if let override, !override.isEmpty { return override }
        let family = firstAuthor.map { familyName(of: $0) } ?? "unknown"
        let familyPart = asciiFold(family).lowercased().filter { $0.isLetter || $0.isNumber }
        let yearPart = year.map(String.init) ?? ""
        let word = firstContentWord(of: title)
        var base = "\(familyPart.isEmpty ? "unknown" : familyPart)\(yearPart)\(word)"
        if base.isEmpty { base = "untitled" }
        guard existingKeys.contains(base) else { return base }
        for suffix in "abcdefghijklmnopqrstuvwxyz" {
            let candidate = base + String(suffix)
            if !existingKeys.contains(candidate) { return candidate }
        }
        return base + UUID().uuidString.prefix(4).lowercased()
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "on", "of", "for", "and", "or", "in", "to", "with",
        "is", "are", "at", "by", "from", "as", "its", "their", "towards", "toward", "via",
    ]

    static func firstContentWord(of title: String) -> String {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for w in words where !stopWords.contains(w) {
            return asciiFold(w).filter { $0.isLetter || $0.isNumber }
        }
        return words.first.map { asciiFold($0).filter { $0.isLetter || $0.isNumber } } ?? ""
    }

    /// "Ashish Vaswani" → "Vaswani"。"姓, 名" 形式にも対応
    static func familyName(of displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if let comma = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed.components(separatedBy: .whitespaces).last ?? trimmed
    }

    /// ダイアクリティカルマーク除去によるASCII化（é→e等）
    static func asciiFold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    // MARK: - LaTeXエスケープ

    /// `& % # _ { }` 等のLaTeX特殊文字をエスケープ（→ docs/02 2.3）
    static func escapeLatex(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "&": out += "\\&"
            case "%": out += "\\%"
            case "#": out += "\\#"
            case "_": out += "\\_"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "$": out += "\\$"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 生成

    /// 著者は `姓, 名` 形式で ` and ` 連結
    static func authorField(_ authors: [String]) -> String {
        authors.map { name -> String in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(",") { return trimmed }
            var parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { return trimmed }
            let family = parts.removeLast()
            return "\(family), \(parts.joined(separator: " "))"
        }.joined(separator: " and ")
    }

    public func generate(
        paper: Paper,
        authors: [String],
        existingKeys: Set<String> = [],
        citationKeyOverride: String? = nil
    ) -> String {
        // 取得元優先設定かつキャッシュあり（→ docs/02 2節）
        if options.preferCachedBibtex, let cached = paper.bibtexCached, !cached.isEmpty {
            return cached
        }

        let type = Self.entryType(for: paper)
        let key = Self.citationKey(
            title: paper.title,
            firstAuthor: authors.first,
            year: paper.year,
            existingKeys: existingKeys,
            override: citationKeyOverride
        )

        var fields: [(String, String)] = []
        fields.append(("title", transform(Self.escapeLatex(paper.title))))
        if !authors.isEmpty {
            fields.append(("author", transform(Self.escapeLatex(Self.authorField(authors)))))
        }
        switch type {
        case .article:
            if let journal = paper.journal { fields.append(("journal", transform(Self.escapeLatex(journal)))) }
            if let volume = paper.volume { fields.append(("volume", volume)) }
            if let number = paper.number { fields.append(("number", number)) }
            if let pages = paper.pages { fields.append(("pages", pages)) }
        case .inproceedings:
            if let booktitle = paper.booktitle { fields.append(("booktitle", transform(Self.escapeLatex(booktitle)))) }
            if let pages = paper.pages { fields.append(("pages", pages)) }
        case .misc:
            // arXivのみ（出版情報なし）→ eprint情報を付与（→ docs/02 2.1）
            if let arxivId = paper.arxivId {
                fields.append(("eprint", arxivId))
                fields.append(("archivePrefix", "arXiv"))
            }
        }
        if let year = paper.year { fields.append(("year", String(year))) }
        if let publisher = paper.publisher { fields.append(("publisher", transform(Self.escapeLatex(publisher)))) }
        if let doi = paper.doi { fields.append(("doi", doi)) }
        if let url = paper.url { fields.append(("url", url)) }

        let width = fields.map { $0.0.count }.max() ?? 0
        // 注: クロージャの戻り型を明示する（GRDBのSQL文字列補間がjoinedの型推論に漏れ込むのを防ぐ）
        let lines: [String] = fields.map { (name, value) -> String in
            let padding = String(repeating: " ", count: width - name.count)
            return "  \(name)\(padding) = {\(value)},"
        }
        let body = lines.joined(separator: "\n")
        return "@\(type.rawValue){\(key),\n\(body)\n}"
    }

    private func transform(_ s: String) -> String {
        options.asciiMode ? Self.asciiFold(s) : s
    }
}
