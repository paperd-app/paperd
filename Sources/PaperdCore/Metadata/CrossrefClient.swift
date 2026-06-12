import Foundation

/// Crossref works APIクライアント。politeプール用にmailtoを付与する（→ docs/04 9節）
public struct CrossrefClient: Sendable {
    let http: HTTPClient
    let baseURL: String
    let mailto: String?

    public init(http: HTTPClient, baseURL: String = "https://api.crossref.org", mailto: String? = nil) {
        self.http = http
        self.baseURL = baseURL
        self.mailto = mailto
    }

    public func resolve(doi: String) async throws -> ResolvedMetadata {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        var urlString = "\(baseURL)/works/\(encoded)"
        if let mailto { urlString += "?mailto=\(mailto)" }
        guard let url = URL(string: urlString) else {
            throw MetadataError.network(source: "Crossref", message: "Invalid URL")
        }
        let response = try await http.send(HTTPRequest(url: url))
        if response.statusCode == 404 {
            throw MetadataError.notFound(source: "Crossref", identifier: doi)
        }
        guard response.isSuccess else {
            throw MetadataError.network(source: "Crossref", message: "HTTP \(response.statusCode)")
        }
        return try Self.parse(data: response.body, doi: doi)
    }

    /// 出版済みとみなすCrossref type
    static let publishedTypes: Set<String> = ["journal-article", "proceedings-article"]
    /// プレプリントより出版版を優先する際の許容スコア比（→ docs/04 4節）
    static let publishedPreferenceRatio = 0.8

    /// タイトル+著者によるbibliographic検索（ローカルPDF解決用 → docs/04 4節）。
    /// スコア閾値以上の最良一致のDOIを返す。
    /// 最上位がプレプリント（posted-content等）で、僅差に出版版（journal-article /
    /// proceedings-article）がある場合は出版版を優先する（SSRN等のプレプリントDOIは
    /// 出版情報を持たず、S2/OpenAlexの補完・引用取得も効かないことが多いため）。
    public func searchByBibliographic(title: String, author: String?, scoreThreshold: Double = 60) async throws -> String? {
        var query = "query.bibliographic=\(title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title)"
        if let author {
            query += "&query.author=\(author.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? author)"
        }
        query += "&rows=5"
        if let mailto { query += "&mailto=\(mailto)" }
        guard let url = URL(string: "\(baseURL)/works?\(query)") else {
            throw MetadataError.network(source: "Crossref", message: "Invalid URL")
        }
        let response = try await http.send(HTTPRequest(url: url))
        guard response.isSuccess else {
            throw MetadataError.network(source: "Crossref", message: "HTTP \(response.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]]
        else { return nil }

        struct Candidate {
            let doi: String
            let score: Double
            let type: String
        }
        let candidates: [Candidate] = items.compactMap { item in
            guard let doi = item["DOI"] as? String, let score = item["score"] as? Double else { return nil }
            return Candidate(doi: doi, score: score, type: (item["type"] as? String) ?? "")
        }
        guard let top = candidates.first, top.score >= scoreThreshold else { return nil }

        if !Self.publishedTypes.contains(top.type),
           let published = candidates.first(where: {
               Self.publishedTypes.contains($0.type) && $0.score >= top.score * Self.publishedPreferenceRatio
           }) {
            return published.doi
        }
        return top.doi
    }

    static func parse(data: Data, doi: String) throws -> ResolvedMetadata {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any]
        else {
            throw MetadataError.parse(source: "Crossref", message: "Malformed JSON response")
        }

        let title = (message["title"] as? [String])?.first ?? "(no title)"
        let containerTitle = (message["container-title"] as? [String])?.first
        let type = message["type"] as? String

        var year: Int?
        for key in ["published-print", "published-online", "published", "issued"] {
            if let published = message[key] as? [String: Any],
               let parts = published["date-parts"] as? [[Any]],
               let first = parts.first, let y = first.first as? Int {
                year = y
                break
            }
        }

        var authors: [ResolvedMetadata.AuthorInfo] = []
        if let authorList = message["author"] as? [[String: Any]] {
            for a in authorList {
                let given = a["given"] as? String
                let family = a["family"] as? String
                let name = [given, family].compactMap { $0 }.joined(separator: " ")
                guard !name.isEmpty else { continue }
                authors.append(.init(displayName: name, orcid: (a["ORCID"] as? String)))
            }
        }

        // type → bibtexフィールドの対応（→ docs/02 2.1）
        var journal: String?
        var booktitle: String?
        var bibtexType = BibtexType.misc
        switch type {
        case "journal-article":
            journal = containerTitle
            bibtexType = .article
        case "proceedings-article":
            booktitle = containerTitle
            bibtexType = .inproceedings
        default:
            break
        }

        return ResolvedMetadata(
            title: title,
            abstract: message["abstract"] as? String,  // Crossrefは欠落が多い（→ docs/04 3節）
            year: year,
            venue: containerTitle,
            doi: (message["DOI"] as? String) ?? doi,
            bibtexType: bibtexType.rawValue,
            journal: journal,
            booktitle: booktitle,
            volume: message["volume"] as? String,
            number: message["issue"] as? String,
            pages: message["page"] as? String,
            publisher: message["publisher"] as? String,
            url: message["URL"] as? String,
            authors: authors
        )
    }
}
