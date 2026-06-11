import Foundation

/// OpenAlex APIクライアント（S2のフォールバック・補完 → docs/04 3節, docs/08 1節）
public struct OpenAlexClient: Sendable {
    let http: HTTPClient
    let baseURL: String
    let mailto: String?

    public init(http: HTTPClient, baseURL: String = "https://api.openalex.org", mailto: String? = nil) {
        self.http = http
        self.baseURL = baseURL
        self.mailto = mailto
    }

    public struct WorkInfo: Equatable, Sendable {
        public var openalexId: String
        public var title: String?
        public var abstract: String?
        public var year: Int?
        public var doi: String?
        public var venue: String?
        /// OA版PDFのURL（best_oa_location。Unpaywall由来データ → docs/04 6節）
        public var oaPdfURL: String?
        /// 参考文献のOpenAlex ID列（→ docs/08 1節。書誌はworks(ids:)で取得）
        public var referencedWorkIds: [String] = []
    }

    /// DOIで論文を取得
    public func work(doi: String) async throws -> WorkInfo {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        return try await fetchWork(path: "/works/doi:\(encoded)", identifier: doi)
    }

    /// OpenAlex IDで論文を取得（referenced_works込み）
    public func work(openalexId: String) async throws -> WorkInfo {
        try await fetchWork(path: "/works/\(openalexId)", identifier: openalexId)
    }

    func fetchWork(path: String, identifier: String) async throws -> WorkInfo {
        var urlString = "\(baseURL)\(path)"
        if let mailto { urlString += "?mailto=\(mailto)" }
        guard let url = URL(string: urlString) else {
            throw MetadataError.network(source: "OpenAlex", message: "不正なURL")
        }
        let response = try await http.send(HTTPRequest(url: url))
        if response.statusCode == 404 {
            throw MetadataError.notFound(source: "OpenAlex", identifier: identifier)
        }
        guard response.isSuccess else {
            throw MetadataError.network(source: "OpenAlex", message: "HTTP \(response.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw MetadataError.parse(source: "OpenAlex", message: "JSONの形式が不正")
        }
        return try Self.parseWork(json)
    }

    /// この論文を引用している論文（被引用側の補完 → docs/08 1節）。
    /// ページング（200件/ページ）でlimitまで取得する
    public func citingWorks(openalexId: String, limit: Int = 1000) async throws -> [WorkInfo] {
        var results: [WorkInfo] = []
        var page = 1
        let perPage = 200
        while results.count < limit {
            var urlString = "\(baseURL)/works?filter=cites:\(openalexId)&per-page=\(perPage)&page=\(page)"
            if let mailto { urlString += "&mailto=\(mailto)" }
            let pageItems = try await fetchWorkList(urlString: urlString)
            results.append(contentsOf: pageItems)
            if pageItems.count < perPage { break }
            page += 1
        }
        return Array(results.prefix(limit))
    }

    /// OpenAlex IDのバッチ取得（referenced_worksの書誌解決用）
    public func works(ids: [String], batchSize: Int = 50) async throws -> [WorkInfo] {
        var results: [WorkInfo] = []
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = ids[start..<min(start + batchSize, ids.count)]
                .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            // ORフィルタの区切り `|` はURLとして不正なため明示的にエンコードする
            let joined = batch.joined(separator: "%7C")
            var urlString = "\(baseURL)/works?filter=openalex:\(joined)&per-page=\(batchSize)"
            if let mailto { urlString += "&mailto=\(mailto)" }
            results.append(contentsOf: try await fetchWorkList(urlString: urlString))
        }
        return results
    }

    func fetchWorkList(urlString: String) async throws -> [WorkInfo] {
        guard let url = URL(string: urlString) else {
            throw MetadataError.network(source: "OpenAlex", message: "不正なURL")
        }
        let response = try await http.send(HTTPRequest(url: url))
        guard response.isSuccess else {
            throw MetadataError.network(source: "OpenAlex", message: "HTTP \(response.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let items = json["results"] as? [[String: Any]]
        else {
            throw MetadataError.parse(source: "OpenAlex", message: "JSONの形式が不正")
        }
        return items.compactMap { try? Self.parseWork($0) }
    }

    static func parse(data: Data) throws -> WorkInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataError.parse(source: "OpenAlex", message: "JSONの形式が不正")
        }
        return try parseWork(json)
    }

    static func parseWork(_ json: [String: Any]) throws -> WorkInfo {
        guard let id = json["id"] as? String else {
            throw MetadataError.parse(source: "OpenAlex", message: "idがありません")
        }
        // "https://openalex.org/W2741809807" → "W2741809807"
        let openalexId = id.split(separator: "/").last.map(String.init) ?? id
        var doi = json["doi"] as? String
        if let d = doi, let parsed = PaperIdentifier.extractDOI(from: d) { doi = parsed }

        var abstract: String?
        if let inverted = json["abstract_inverted_index"] as? [String: [Int]] {
            abstract = reconstructAbstract(from: inverted)
        }
        let venue = ((json["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String
        let oaPdfURL = (json["best_oa_location"] as? [String: Any])?["pdf_url"] as? String
            ?? (json["primary_location"] as? [String: Any])?["pdf_url"] as? String
        let referenced = (json["referenced_works"] as? [String])?.map {
            $0.split(separator: "/").last.map(String.init) ?? $0
        } ?? []
        return WorkInfo(
            openalexId: openalexId,
            title: json["display_name"] as? String,
            abstract: abstract,
            year: json["publication_year"] as? Int,
            doi: doi,
            venue: venue,
            oaPdfURL: oaPdfURL,
            referencedWorkIds: referenced
        )
    }

    /// abstract_inverted_index（単語 → 出現位置リスト）からの本文復元
    static func reconstructAbstract(from inverted: [String: [Int]]) -> String {
        var positions: [(Int, String)] = []
        for (word, indices) in inverted {
            for i in indices { positions.append((i, word)) }
        }
        positions.sort { $0.0 < $1.0 }
        return positions.map(\.1).joined(separator: " ")
    }
}
