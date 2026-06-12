import Foundation

/// Semantic Scholar Graph APIクライアント（→ docs/04 3節, docs/08 1節）
public struct SemanticScholarClient: Sendable {
    let http: HTTPClient
    let baseURL: String
    let apiKey: String?

    public init(http: HTTPClient, baseURL: String = "https://api.semanticscholar.org/graph/v1", apiKey: String? = nil) {
        self.http = http
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var headers: [String: String] {
        apiKey.map { ["x-api-key": $0] } ?? [:]
    }

    /// `DOI:...` / `ARXIV:...` / S2 paperId のいずれかで論文情報を取得
    public struct PaperInfo: Equatable, Sendable {
        public var paperId: String
        public var title: String?
        public var abstract: String?
        public var year: Int?
        public var venue: String?
        public var doi: String?
        public var arxivId: String?
        public var citationCount: Int?
        public var authors: [ResolvedMetadata.AuthorInfo]
    }

    public func paper(identifier: String, fields: String = "title,abstract,year,venue,externalIds,citationCount,authors") async throws -> PaperInfo {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        guard let url = URL(string: "\(baseURL)/paper/\(encoded)?fields=\(fields)") else {
            throw MetadataError.network(source: "SemanticScholar", message: "Invalid URL")
        }
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        if response.statusCode == 404 {
            throw MetadataError.notFound(source: "SemanticScholar", identifier: identifier)
        }
        guard response.isSuccess else {
            throw MetadataError.network(source: "SemanticScholar", message: "HTTP \(response.statusCode)")
        }
        return try Self.parsePaper(data: response.body)
    }

    /// references / citations の取得（→ docs/08）。citationsは上限つき・citationCount降順は呼び出し側で処理
    public func references(paperId: String, limit: Int = 1000) async throws -> [PaperInfo] {
        try await edges(paperId: paperId, kind: "references", key: "citedPaper", limit: limit)
    }

    public func citations(paperId: String, limit: Int = 1000) async throws -> [PaperInfo] {
        try await edges(paperId: paperId, kind: "citations", key: "citingPaper", limit: limit)
    }

    func edges(paperId: String, kind: String, key: String, limit: Int) async throws -> [PaperInfo] {
        let fields = "title,year,venue,externalIds,citationCount,authors"
        guard let url = URL(string: "\(baseURL)/paper/\(paperId)/\(kind)?fields=\(fields)&limit=\(min(limit, 1000))") else {
            throw MetadataError.network(source: "SemanticScholar", message: "Invalid URL")
        }
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        guard response.isSuccess else {
            throw MetadataError.network(source: "SemanticScholar", message: "HTTP \(response.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw MetadataError.parse(source: "SemanticScholar", message: "Malformed JSON response")
        }
        // 出版社がreferencesを非公開にしている論文では "data": null が返る → 空として扱う
        let items = json["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let paperJSON = item[key] as? [String: Any] else { return nil }
            return try? Self.paperInfo(from: paperJSON)
        }
    }

    static func parsePaper(data: Data) throws -> PaperInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataError.parse(source: "SemanticScholar", message: "Malformed JSON response")
        }
        return try paperInfo(from: json)
    }

    static func paperInfo(from json: [String: Any]) throws -> PaperInfo {
        guard let paperId = json["paperId"] as? String else {
            throw MetadataError.parse(source: "SemanticScholar", message: "Missing paperId")
        }
        let external = json["externalIds"] as? [String: Any]
        var authors: [ResolvedMetadata.AuthorInfo] = []
        if let authorList = json["authors"] as? [[String: Any]] {
            for a in authorList {
                guard let name = a["name"] as? String else { continue }
                authors.append(.init(displayName: name, s2AuthorId: a["authorId"] as? String))
            }
        }
        return PaperInfo(
            paperId: paperId,
            title: json["title"] as? String,
            abstract: json["abstract"] as? String,
            year: json["year"] as? Int,
            venue: json["venue"] as? String,
            doi: external?["DOI"] as? String,
            arxivId: external?["ArXiv"] as? String,
            citationCount: json["citationCount"] as? Int,
            authors: authors
        )
    }
}
