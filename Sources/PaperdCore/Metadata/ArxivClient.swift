import Foundation

/// arXiv API（Atomフィード）クライアント（→ docs/04 3節）
public struct ArxivClient: Sendable {
    let http: HTTPClient
    let baseURL: String

    public init(http: HTTPClient, baseURL: String = "https://export.arxiv.org/api/query") {
        self.http = http
        self.baseURL = baseURL
    }

    public func resolve(arxivId: String) async throws -> ResolvedMetadata {
        guard let url = URL(string: "\(baseURL)?id_list=\(arxivId)&max_results=1") else {
            throw MetadataError.network(source: "arXiv", message: "Invalid URL")
        }
        let response = try await http.send(HTTPRequest(url: url))
        guard response.isSuccess else {
            throw MetadataError.network(source: "arXiv", message: "HTTP \(response.statusCode)")
        }
        guard let entry = ArxivAtomParser.parse(data: response.body) else {
            throw MetadataError.notFound(source: "arXiv", identifier: arxivId)
        }
        var meta = ResolvedMetadata(
            title: entry.title,
            abstract: entry.summary,
            year: entry.publishedYear,
            venue: "arXiv",
            doi: entry.doi,
            arxivId: entry.arxivId ?? arxivId,
            arxivVersion: entry.arxivVersion,
            bibtexType: BibtexType.misc.rawValue,
            url: "https://arxiv.org/abs/\(entry.arxivId ?? arxivId)",
            authors: entry.authors.map { .init(displayName: $0) }
        )
        meta.pdfURL = "https://arxiv.org/pdf/\(entry.arxivId ?? arxivId)"
        return meta
    }
}

/// arXiv Atomレスポンスの最小パーサ
final class ArxivAtomParser: NSObject, XMLParserDelegate {
    struct Entry {
        var title: String = ""
        var summary: String?
        var publishedYear: Int?
        var doi: String?
        var arxivId: String?
        var arxivVersion: String?
        var authors: [String] = []
    }

    private var entry: Entry?
    private var elementStack: [String] = []
    private var currentText = ""
    private var inAuthor = false

    static func parse(data: Data) -> Entry? {
        let delegate = ArxivAtomParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        // タイトルが空のentry（エラーフィード）は不在扱い
        guard let entry = delegate.entry, !entry.title.isEmpty, entry.title != "Error" else { return nil }
        return entry
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        currentText = ""
        if elementName == "entry" { entry = Entry() }
        if elementName == "author" { inAuthor = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { elementStack.removeLast() }
        guard entry != nil, elementStack.contains("entry") else { return }
        let text = currentText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        switch elementName {
        case "title":
            entry?.title = text
        case "summary":
            entry?.summary = text
        case "published":
            if text.count >= 4 { entry?.publishedYear = Int(text.prefix(4)) }
        case "id":
            // 例: http://arxiv.org/abs/1706.03762v5
            if let last = text.split(separator: "/").last,
               let parsed = PaperIdentifier.parseArxivID(String(last)) {
                entry?.arxivId = parsed.id
                entry?.arxivVersion = parsed.version
            }
        case "name" where inAuthor:
            entry?.authors.append(text)
        case "author":
            inAuthor = false
        case "doi", "arxiv:doi":  // 名前空間処理なしでは修飾名のまま届く
            entry?.doi = text
        default:
            break
        }
    }
}
