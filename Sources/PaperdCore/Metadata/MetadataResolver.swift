import Foundation

/// メタデータ解決のオーケストレーション（→ docs/04-ingest-pipeline.md 3節）。
/// 優先順: arXiv ID → arXiv API / DOI → Crossref、その後S2 / OpenAlexで補完。
public struct MetadataResolver: Sendable {
    public let arxiv: ArxivClient
    public let crossref: CrossrefClient
    public let semanticScholar: SemanticScholarClient
    public let openAlex: OpenAlexClient
    /// Webページ取得用（citation_*メタタグ解決 → docs/04 2節）
    public let http: HTTPClient

    public init(
        arxiv: ArxivClient,
        crossref: CrossrefClient,
        semanticScholar: SemanticScholarClient,
        openAlex: OpenAlexClient,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.arxiv = arxiv
        self.crossref = crossref
        self.semanticScholar = semanticScholar
        self.openAlex = openAlex
        self.http = http
    }

    public static func live(http: HTTPClient = URLSessionHTTPClient(), mailto: String? = nil, s2APIKey: String? = nil) -> MetadataResolver {
        MetadataResolver(
            arxiv: ArxivClient(http: http),
            crossref: CrossrefClient(http: http, mailto: mailto),
            semanticScholar: SemanticScholarClient(http: http, apiKey: s2APIKey),
            openAlex: OpenAlexClient(http: http, mailto: mailto),
            http: http
        )
    }

    public func resolve(_ identifier: PaperIdentifier) async throws -> ResolvedMetadata {
        switch identifier {
        case .arxiv(let id, let version):
            var meta = try await arxiv.resolve(arxivId: id)
            if meta.arxivVersion == nil { meta.arxivVersion = version }
            // arXiv論文に出版版DOIがある場合は両方保持し、出版情報を優先（→ docs/04 3節）
            if let doi = meta.doi, let published = try? await crossref.resolve(doi: doi) {
                meta = Self.merge(base: published, complement: meta)
            }
            await complement(&meta)
            return meta

        case .doi(let doi):
            var meta = try await crossref.resolve(doi: doi)
            await complement(&meta)
            return meta

        case .webpage(let urlString):
            // citation_*メタタグからの解決（→ docs/04 2節）
            return try await resolveWebpage(urlString)

        case .directPDFURL(let urlString):
            // 直接PDFはパイプラインがダウンロード → ローカルPDF解決に帰着させる（→ docs/04 2節）
            throw MetadataError.notFound(source: "resolver", identifier: urlString)

        case .localPDF(let path):
            // ローカルPDFはconvert先行が必要（→ docs/04 4節）。resolverでは扱わない
            throw MetadataError.notFound(source: "resolver", identifier: path)
        }
    }

    /// Webページの解決（→ docs/04 2節）。
    /// citation_doi / citation_arxiv_id があればID解決に帰着（最良の書誌品質）。
    /// なければメタタグの書誌を採用し、Crossref bibliographic検索でDOI補強を試みる。
    /// メタタグの無いページは恒久的エラー（parse）— リトライしても解決しない
    func resolveWebpage(_ urlString: String) async throws -> ResolvedMetadata {
        guard let url = URL(string: urlString) else {
            throw MetadataError.parse(source: "webpage", message: "不正なURL: \(urlString)")
        }
        let response = try await http.send(HTTPRequest(url: url))
        guard response.isSuccess else {
            throw MetadataError.network(source: "webpage", message: "HTTP \(response.statusCode): \(urlString)")
        }
        let html = String(data: response.body, encoding: .utf8)
            ?? String(data: response.body, encoding: .isoLatin1) ?? ""
        let tags = WebpageMetadata.parse(html: html)

        // タグ内のID → 既存のID解決に帰着
        if let doi = tags.doi {
            var meta = try await resolve(.doi(doi))
            if meta.pdfURL == nil { meta.pdfURL = tags.pdfURL }
            if meta.url == nil { meta.url = urlString }
            return meta
        }
        if let arxivId = tags.arxivId {
            var meta = try await resolve(.arxiv(id: arxivId, version: nil))
            if meta.pdfURL == nil { meta.pdfURL = tags.pdfURL }
            if meta.url == nil { meta.url = urlString }
            return meta
        }
        guard let title = tags.title else {
            throw MetadataError.parse(
                source: "webpage",
                message: "citationメタタグが見つかりません。このページからは書誌を特定できないため、DOIまたはarXiv IDでの追加をお試しください: \(urlString)")
        }

        // タグから書誌を構築
        var meta = ResolvedMetadata(title: title)
        meta.authors = tags.authors.map { .init(displayName: $0) }
        meta.year = tags.year
        meta.journal = tags.journal
        meta.booktitle = tags.conference
        meta.venue = tags.journal ?? tags.conference
        meta.volume = tags.volume
        meta.pages = tags.pages
        meta.url = urlString
        meta.pdfURL = tags.pdfURL

        // Crossref bibliographic検索によるDOI補強（ローカルPDF解決と同じ検証規準 → docs/04 4節）
        if let doi = try? await crossref.searchByBibliographic(title: title, author: tags.authors.first),
           let published = try? await crossref.resolve(doi: doi),
           TextMatch.tokenOverlap(published.title, title) >= 0.5 || TextMatch.containsNormalized(published.title, title) {
            meta = Self.merge(base: published, complement: meta)
        }
        await complement(&meta)
        return meta
    }

    /// S2 / OpenAlexによる補完（abstract・s2_paper_id・openalex_id → docs/04 3節）。
    /// 補完失敗は致命的でない（無視して続行）。
    public func complement(_ meta: inout ResolvedMetadata) async {
        let s2Identifier: String?
        if let arxivId = meta.arxivId {
            s2Identifier = "ARXIV:\(arxivId)"
        } else if let doi = meta.doi {
            s2Identifier = "DOI:\(doi)"
        } else {
            s2Identifier = nil
        }

        if let s2Identifier, let info = try? await semanticScholar.paper(identifier: s2Identifier) {
            meta.s2PaperId = info.paperId
            if meta.abstract == nil { meta.abstract = info.abstract }
            if meta.year == nil { meta.year = info.year }
            if meta.venue == nil || meta.venue == "arXiv" {
                if let venue = info.venue, !venue.isEmpty { meta.venue = venue }
            }
            if meta.doi == nil { meta.doi = info.doi }
            // 出版版DOIからプレプリントへの橋渡し（paywall時の代替PDF源 → docs/04 6節）
            if meta.arxivId == nil { meta.arxivId = info.arxivId }
            // 著者のs2AuthorIdを名前一致で補完
            if !info.authors.isEmpty {
                for i in meta.authors.indices {
                    if let match = info.authors.first(where: { $0.displayName == meta.authors[i].displayName }) {
                        meta.authors[i].s2AuthorId = match.s2AuthorId
                    }
                }
                if meta.authors.isEmpty {
                    meta.authors = info.authors
                }
            }
        }

        if let doi = meta.doi, let work = try? await openAlex.work(doi: doi) {
            meta.openalexId = work.openalexId
            if meta.abstract == nil { meta.abstract = work.abstract }
            if meta.year == nil { meta.year = work.year }
            // OA版PDF（Unpaywall由来・メール不要 → docs/04 6節）
            if meta.pdfURL == nil { meta.pdfURL = work.oaPdfURL }
        }
    }

    /// 出版版（base）を優先しつつarXiv情報（complement）を保持するマージ
    static func merge(base: ResolvedMetadata, complement: ResolvedMetadata) -> ResolvedMetadata {
        var merged = base
        if merged.abstract == nil { merged.abstract = complement.abstract }
        merged.arxivId = complement.arxivId
        merged.arxivVersion = complement.arxivVersion
        if merged.authors.isEmpty { merged.authors = complement.authors }
        if merged.pdfURL == nil { merged.pdfURL = complement.pdfURL }
        if merged.url == nil { merged.url = complement.url }
        return merged
    }
}
