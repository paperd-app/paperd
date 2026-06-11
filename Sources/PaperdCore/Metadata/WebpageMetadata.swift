import Foundation

/// Webページの `citation_*` メタタグ解析（→ docs/04 2節）。
/// Google Scholarが定める事実上の標準で、出版社・リポジトリ・プレプリントサーバの大半が対応する
///（Zotero等と同じ機構）。
public struct WebpageMetadata: Equatable, Sendable {
    public var title: String?
    public var authors: [String] = []
    public var year: Int?
    public var journal: String?
    public var conference: String?
    public var volume: String?
    public var firstPage: String?
    public var lastPage: String?
    public var doi: String?
    public var arxivId: String?
    public var pdfURL: String?

    public var pages: String? {
        switch (firstPage, lastPage) {
        case (let f?, let l?): return "\(f)-\(l)"
        case (let f?, nil): return f
        default: return nil
        }
    }

    public static func parse(html: String) -> WebpageMetadata {
        var meta = WebpageMetadata()
        guard let tagRegex = try? NSRegularExpression(pattern: #"<meta\s+[^>]*>"#, options: [.caseInsensitive]) else {
            return meta
        }
        let range = NSRange(html.startIndex..., in: html)
        for match in tagRegex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let name = attribute("name", in: tag)?.lowercased(),
                  name.hasPrefix("citation_"),
                  let content = attribute("content", in: tag).map(unescape),
                  !content.isEmpty
            else { continue }

            switch name {
            case "citation_title":
                meta.title = meta.title ?? content
            case "citation_author":
                meta.authors.append(normalizeAuthor(content))
            case "citation_publication_date", "citation_date", "citation_online_date", "citation_year":
                if meta.year == nil, let year = Int(content.prefix(4)), year > 1500 { meta.year = year }
            case "citation_journal_title":
                meta.journal = meta.journal ?? content
            case "citation_conference_title", "citation_conference":
                meta.conference = meta.conference ?? content
            case "citation_volume":
                meta.volume = meta.volume ?? content
            case "citation_firstpage":
                meta.firstPage = meta.firstPage ?? content
            case "citation_lastpage":
                meta.lastPage = meta.lastPage ?? content
            case "citation_doi":
                meta.doi = meta.doi ?? (PaperIdentifier.extractDOI(from: content) ?? content)
            case "citation_arxiv_id":
                meta.arxivId = meta.arxivId ?? content
            case "citation_pdf_url":
                meta.pdfURL = meta.pdfURL ?? content
            default:
                break
            }
        }
        return meta
    }

    /// 属性値の抽出（name= / content= の出現順は両対応、クオート両対応）
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let valueRange = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[valueRange])
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Vaswani, Ashish" → "Ashish Vaswani"（表示名の正規化）
    static func normalizeAuthor(_ name: String) -> String {
        let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[1].isEmpty {
            return "\(parts[1]) \(parts[0])"
        }
        return name
    }
}
