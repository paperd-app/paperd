import Foundation

/// references / citations の取得とキャッシュ（→ docs/08 1〜3節）。
/// 一次ソースはSemantic Scholar、**OpenAlexで常時補完**する（S2の索引漏れ・
/// 出版社によるreferences非公開への対策。外部IDで重複排除しながら統合）。
/// `kind = refetch_citations` ジョブの実体。
public struct CitationFetcher: Sendable {
    public let db: AppDatabase
    public let s2: SemanticScholarClient
    /// 補完用OpenAlexクライアント（nilならS2のみ）
    public let openAlex: OpenAlexClient?
    /// citationsの取得上限（被引用数の多い論文への対策 → docs/08 3節）
    public var citationLimit: Int

    public init(db: AppDatabase, s2: SemanticScholarClient, openAlex: OpenAlexClient? = nil, citationLimit: Int = 1000) {
        self.db = db
        self.s2 = s2
        self.openAlex = openAlex
        self.citationLimit = citationLimit
    }

    /// S2に渡す論文識別子（→ docs/08 1節: paperId / DOI: / ARXIV: プレフィックス）
    public static func s2Identifier(for paper: Paper) -> String? {
        if let s2id = paper.s2PaperId { return s2id }
        if let doi = paper.doi { return "DOI:\(doi)" }
        if let arxivId = paper.arxivId { return "ARXIV:\(arxivId)" }
        return nil
    }

    /// 引用取得が可能か（S2識別子またはOpenAlex IDのいずれか）
    public static func canFetch(for paper: Paper) -> Bool {
        s2Identifier(for: paper) != nil || paper.openalexId != nil
    }

    public func refetch(paperId: String) async throws {
        let paper = try db.read { try Paper.fetchOne($0, key: paperId) }
        guard let paper else {
            throw IngestError.invalidInput("Paper does not exist: \(paperId)")
        }
        let s2Identifier = Self.s2Identifier(for: paper)
        guard s2Identifier != nil || paper.openalexId != nil else {
            // 外部IDなし（ローカルPDFのみ等）はエッジ取得不能。恒久的（リトライ無意味）
            throw IngestError.permanent("No external ID (S2/DOI/arXiv/OpenAlex) available for citation fetch: \(paperId)")
        }

        // 一次: Semantic Scholar
        var s2References: [CitationStore.StubInfo] = []
        var s2Citations: [CitationStore.StubInfo] = []
        var s2Error: Error?
        if let s2Identifier {
            do {
                s2References = try await s2.references(paperId: s2Identifier).map(Self.stubInfo(from:))
                s2Citations = try await s2.citations(paperId: s2Identifier, limit: citationLimit).map(Self.stubInfo(from:))
            } catch {
                s2Error = error
            }
        }

        // 補完: OpenAlex（→ docs/08 1節）
        var oaReferences: [CitationStore.StubInfo] = []
        var oaCitations: [CitationStore.StubInfo] = []
        var oaError: Error?
        if let openAlex, let openalexId = paper.openalexId {
            do {
                oaCitations = try await openAlex.citingWorks(openalexId: openalexId, limit: citationLimit)
                    .map(Self.stubInfo(fromWork:))
                let referencedIds = try await openAlex.work(openalexId: openalexId).referencedWorkIds
                if !referencedIds.isEmpty {
                    oaReferences = try await openAlex.works(ids: referencedIds).map(Self.stubInfo(fromWork:))
                }
            } catch {
                oaError = error
            }
        }

        // 両ソースとも取得できなかった場合のみエラー（バックオフリトライ対象）
        if s2Error != nil || (s2Identifier == nil) {
            let oaUsable = paper.openalexId != nil && openAlex != nil && oaError == nil
            if !oaUsable {
                throw s2Error ?? oaError ?? IngestError.permanent("Failed to fetch citations")
            }
        }

        let store = CitationStore(db: db)
        // S2分は差し替え（S2が失敗した回は既存の出方向エッジを温存するためスキップ）
        if s2Identifier != nil, s2Error == nil {
            try store.replaceEdges(center: paperId, references: s2References, citations: s2Citations, source: .s2)
        }
        // OpenAlex分は追加（既存エッジは保持）
        if !oaReferences.isEmpty || !oaCitations.isEmpty {
            try store.addEdges(center: paperId, references: oaReferences, citations: oaCitations, source: .openalex)
        }
    }

    static func stubInfo(from info: SemanticScholarClient.PaperInfo) -> CitationStore.StubInfo {
        CitationStore.StubInfo(
            title: info.title ?? "(untitled)",
            year: info.year,
            venue: info.venue,
            s2PaperId: info.paperId,
            doi: info.doi,
            arxivId: info.arxivId,
            authors: info.authors.map(\.displayName)
        )
    }

    static func stubInfo(fromWork work: OpenAlexClient.WorkInfo) -> CitationStore.StubInfo {
        CitationStore.StubInfo(
            title: work.title ?? "(untitled)",
            year: work.year,
            venue: work.venue,
            doi: work.doi,
            openalexId: work.openalexId
        )
    }
}
