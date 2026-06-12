import Foundation
import GRDB
import PaperdCore

/// v1の7ツール実装（→ docs/07 2節）。
/// 書き込みはpapers行 + jobs行への短いINSERTのみ。長時間処理はアプリ側JobRunnerが実行する（→ docs/07 3節）。
public struct PaperdTools: Sendable {
    public let store: LibraryStore
    /// semantic検索用のembedder。nil（ワーカー未セットアップ等）ならFTS5のみで応答（→ docs/07 4, 5節）
    public let embedderProvider: @Sendable () async -> QueryEmbedder?
    /// add_paperのメタデータ解決（テストではフェイクを注入）
    public let resolver: @Sendable (PaperIdentifier) async throws -> ResolvedMetadata
    public let fulltextLimit: Int
    /// 最終アクセスの記録（→ docs/07 6節）。nilなら記録しない（テスト等）
    public let accessLog: MCPAccessLog?

    public init(
        store: LibraryStore,
        embedderProvider: @escaping @Sendable () async -> QueryEmbedder?,
        resolver: @escaping @Sendable (PaperIdentifier) async throws -> ResolvedMetadata,
        fulltextLimit: Int = 50_000,
        accessLog: MCPAccessLog? = nil
    ) {
        self.store = store
        self.embedderProvider = embedderProvider
        self.resolver = resolver
        self.fulltextLimit = fulltextLimit
        self.accessLog = accessLog
    }

    // MARK: - ツール定義（→ docs/07 2節）

    public static let definitions: [JSONValue] = [
        toolDef(
            name: "search_papers",
            description: "Full-text search over the user's paper library using natural language or keywords. Hits are per body chunk; returns a snippet for each hit.",
            properties: [
                "query": .object(["type": .string("string"), "description": .string("Search query (natural language allowed)")]),
                "top_k": .object(["type": .string("integer"), "default": .number(10), "maximum": .number(50)]),
            ],
            required: ["query"]
        ),
        toolDef(
            name: "get_bibtex",
            description: "Return the BibTeX entry for a paper. Identify the paper by exactly one of paper_id, doi, or arxiv_id.",
            properties: [
                "paper_id": .object(["type": .string("string")]),
                "doi": .object(["type": .string("string")]),
                "arxiv_id": .object(["type": .string("string")]),
            ],
            required: []
        ),
        toolDef(
            name: "get_fulltext",
            description: "Return the paper's full-text Markdown (paper.md). If section is given, return only that section. For long papers the full text is truncated at a character limit, so it is recommended to first check the section list via get_paper_metadata and fetch by section.",
            properties: [
                "paper_id": .object(["type": .string("string")]),
                "section": .object(["type": .string("string"), "description": .string("Section heading or section_path (optional)")]),
            ],
            required: ["paper_id"]
        ),
        toolDef(
            name: "get_paper_metadata",
            description: "Return the paper's bibliographic metadata (title, authors, year, DOI, status, section list, etc.) as JSON.",
            properties: [
                "paper_id": .object(["type": .string("string")]),
            ],
            required: ["paper_id"]
        ),
        toolDef(
            name: "add_paper",
            description: "Add a paper to the library by arXiv ID, DOI, or URL. Bibliographic metadata is returned immediately; PDF download, conversion, and search indexing are performed asynchronously by the paperd app.",
            properties: [
                "arxiv_id": .object(["type": .string("string")]),
                "doi": .object(["type": .string("string")]),
                "url": .object(["type": .string("string")]),
            ],
            required: []
        ),
        toolDef(
            name: "add_note",
            description: "Append Markdown text to the paper's notes (notes.md). Use this to save research memos and summaries. Existing notes are preserved; the new text is appended at the end as a section with a dated heading. Appended notes become full-text searchable.",
            properties: [
                "paper_id": .object(["type": .string("string")]),
                "content": .object(["type": .string("string"), "description": .string("Markdown text to append")]),
                "heading": .object(["type": .string("string"), "description": .string("Section heading (defaults to 'AI Notes')")]),
            ],
            required: ["paper_id", "content"]
        ),
        .object([
            "name": .string("apply_fulltext_patches"),
            "description": .string("Fix conversion errors in a paper's Markdown by applying patches (find→replace). Each find must occur exactly once in the current text. Before patching, always verify against the original PDF (pdf_path from get_paper_metadata) and never write content that is not in the original. The search index is rebuilt automatically after patching."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "paper_id": .object(["type": .string("string")]),
                    "patches": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "find": .object(["type": .string("string"), "description": .string("Erroneous text in the current body (long enough to be unique)")]),
                                "replace": .object(["type": .string("string"), "description": .string("Corrected text")]),
                            ]),
                            "required": .array([.string("find"), .string("replace")]),
                        ]),
                    ]),
                    "note": .object(["type": .string("string"), "description": .string("Rationale for the fix (recorded in history, optional)")]),
                ]),
                "required": .array([.string("paper_id"), .string("patches")]),
            ]),
        ]),
    ]

    static func toolDef(name: String, description: String, properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    // MARK: - ディスパッチ

    public func call(name: String, arguments: [String: JSONValue]) async -> ToolCallResult {
        accessLog?.record(tool: name)
        do {
            switch name {
            case "search_papers": return try await searchPapers(arguments)
            case "get_bibtex": return try getBibtex(arguments)
            case "get_fulltext": return try getFulltext(arguments)
            case "get_paper_metadata": return try getPaperMetadata(arguments)
            case "add_paper": return try await addPaper(arguments)
            case "apply_fulltext_patches": return try applyFulltextPatches(arguments)
            case "add_note": return try addNote(arguments)
            default:
                return .error("Unknown tool: \(name)")
            }
        } catch let error as LibraryError {
            return .error(error.description)
        } catch let error as MetadataError {
            return .error("Metadata resolution failed: \(error.description). No job was enqueued.")
        } catch {
            let message = String(describing: error)
            if message.lowercased().contains("busy") || message.contains("locked") {
                return .error("The library is busy with another operation. Please retry shortly.")
            }
            return .error("Error: \(message)")
        }
    }

    // MARK: - search_papers

    func searchPapers(_ args: [String: JSONValue]) async throws -> ToolCallResult {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            return .error("query is required. Example: {\"query\": \"attention mechanism\"}")
        }
        let topK = min(args["top_k"]?.intValue ?? 10, 50)

        let embedder = await embedderProvider()
        let search = HybridSearch(db: store.db)
        let (results, semanticUsed) = try await search.search(query: query, topK: topK, embedder: embedder)

        var resultObjects: [JSONValue] = []
        for r in results {
            let authors = (try? store.authors(of: r.paperId).map(\.displayName)) ?? []
            var object: [String: JSONValue] = [
                "paper_id": .string(r.paperId),
                "title": .string(r.title),
                "authors": .array(authors.map { .string($0) }),
                "year": r.year.map { .number(Double($0)) } ?? .null,
                "score": .number((r.score * 10000).rounded() / 10000),
                "match_type": .string(r.matchType.rawValue),
                "section_path": r.sectionPath.map { .string($0) } ?? .null,
                "snippet": .string(String(r.chunkText.prefix(500))),
            ]
            // ヒット強度（→ docs/06 4節）
            if let semantic = r.semanticScore {
                object["semantic_score"] = .number((semantic * 1000).rounded() / 1000)
            }
            if let rank = r.keywordRank {
                object["keyword_rank"] = .number(Double(rank))
            }
            resultObjects.append(.object(object))
        }
        var payload: [String: JSONValue] = ["results": .array(resultObjects)]
        if !semanticUsed {
            // 初回はワーカー起動待ちのためFTS5のみで応答（→ docs/07 4節）
            payload["semantic"] = .string("warming_up")
        }
        return ToolCallResult(text: Self.jsonString(.object(payload)))
    }

    // MARK: - get_bibtex

    func getBibtex(_ args: [String: JSONValue]) throws -> ToolCallResult {
        let paper: Paper?
        if let paperId = args["paper_id"]?.stringValue {
            paper = try store.paper(id: paperId)
            guard paper != nil else {
                return .error("paper_id '\(paperId)' not found. Specify it as a UUID (e.g. 8f14e45f-...).")
            }
        } else if let doi = args["doi"]?.stringValue {
            paper = try store.db.read { try Paper.filter(Column("doi") == doi).fetchOne($0) }
            guard paper != nil else {
                return .error("DOI '\(doi)' is not in the library. Example: 10.5555/3295222.3295349")
            }
        } else if let arxivId = args["arxiv_id"]?.stringValue {
            let normalized = PaperIdentifier.parseArxivID(arxivId)?.id ?? arxivId
            paper = try store.db.read { try Paper.filter(Column("arxiv_id") == normalized).fetchOne($0) }
            guard paper != nil else {
                return .error("arXiv ID '\(arxivId)' is not in the library. Example: 1706.03762")
            }
        } else {
            return .error("Specify exactly one of paper_id, doi, or arxiv_id.")
        }

        let p = paper!
        let authors = try store.authors(of: p.id).map(\.displayName)
        let override = try? store.meta(of: p.id)?.citationKeyOverride
        let existingKeys = try existingCitationKeys(excluding: p.id)
        let bibtex = BibtexGenerator().generate(
            paper: p, authors: authors, existingKeys: existingKeys, citationKeyOverride: override ?? nil)
        return ToolCallResult(text: bibtex)
    }

    /// 重複keyの検出用に他論文のkeyを列挙（→ docs/02 2.2）
    func existingCitationKeys(excluding paperId: String) throws -> Set<String> {
        let papers = try store.db.read { try Paper.filter(Column("id") != paperId && Column("is_stub") == false).fetchAll($0) }
        var keys = Set<String>()
        for p in papers {
            let authors = (try? store.authors(of: p.id).map(\.displayName)) ?? []
            keys.insert(BibtexGenerator.citationKey(title: p.title, firstAuthor: authors.first, year: p.year))
        }
        return keys
    }

    // MARK: - get_fulltext

    func getFulltext(_ args: [String: JSONValue]) throws -> ToolCallResult {
        guard let paperId = args["paper_id"]?.stringValue else {
            return .error("paper_id is required.")
        }
        guard try store.paper(id: paperId) != nil else {
            return .error("paper_id '\(paperId)' not found.")
        }
        // 有効Markdown（paper.corrected.md優先 → docs/05 5.2節, docs/07 3節）
        let corrector = FulltextCorrector(layout: store.layout)
        guard let fulltext = corrector.effectiveMarkdown(paperId: paperId) else {
            return .error("This paper has no full-text Markdown yet (PDF not fetched or conversion pending). Check the status with get_paper_metadata.")
        }

        // section指定: chunks.section_pathとの前方一致で該当チャンクを返す（→ docs/07 2.3）
        if let section = args["section"]?.stringValue {
            // 修正のインデックス反映待ちの間は、チャンクが旧本文のまま（reindexはアプリ側で処理）。
            // 未修正テキストを黙って返さない（→ docs/07 2.3節。実AI利用で発見されたバグの対策）
            var staleWarning: String?
            let pendingReindex = (try? store.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM jobs
                    WHERE kind = 'reindex' AND paper_id = ? AND status IN ('queued', 'running')
                    """, arguments: [paperId]) ?? 0
            }) ?? 0
            if pendingReindex > 0, corrector.hasCorrections(paperId: paperId) {
                if let extracted = FulltextCorrector.extractSection(markdown: fulltext, section: section) {
                    return ToolCallResult(text: extracted + """


                    ---
                    (Note: the search index has not yet caught up with the corrections, so this section was extracted \
                    by heading from the corrected Markdown. If subsections appear to be missing, call get_fulltext \
                    without the section parameter to get the full text.)
                    """)
                }
                staleWarning = "⚠ This paper has corrections not yet reflected in the search index (the paperd app applies them in the background). For the accurate text, call get_fulltext without the section parameter.\n\n"
            }
            let chunks = try store.db.read { dbc in
                try Row.fetchAll(dbc, sql: """
                    SELECT section_path, text FROM chunks
                    WHERE paper_id = ? AND section_path LIKE ? || '%'
                    ORDER BY chunk_index
                    """, arguments: [paperId, section])
            }
            guard !chunks.isEmpty else {
                let sections = try sectionList(paperId: paperId)
                return .error("Section '\(section)' not found. Available: \(sections.joined(separator: ", "))")
            }
            let text = chunks.map { row -> String in
                let path: String? = row["section_path"]
                let body: String = row["text"]
                return "## \(path ?? "")\n\n\(body)"
            }.joined(separator: "\n\n")
            return ToolCallResult(text: (staleWarning ?? "") + text)
        }

        if fulltext.count > fulltextLimit {
            let truncated = String(fulltext.prefix(fulltextLimit))
            let sections = try sectionList(paperId: paperId)
            let hint = sections.isEmpty ? "" : " Use the 'section' parameter to fetch specific sections: \(sections.joined(separator: ", "))"
            return ToolCallResult(text: truncated + "\n\n[truncated: \(fulltext.count) chars total.\(hint)]")
        }
        return ToolCallResult(text: fulltext)
    }

    func sectionList(paperId: String) throws -> [String] {
        try store.db.read { dbc in
            try String.fetchAll(dbc, sql: """
                SELECT DISTINCT section_path FROM chunks
                WHERE paper_id = ? AND section_path IS NOT NULL
                ORDER BY chunk_index
                """, arguments: [paperId])
        }
    }

    // MARK: - get_paper_metadata

    func getPaperMetadata(_ args: [String: JSONValue]) throws -> ToolCallResult {
        guard let paperId = args["paper_id"]?.stringValue else {
            return .error("paper_id is required.")
        }
        guard let paper = try store.paper(id: paperId) else {
            return .error("paper_id '\(paperId)' not found.")
        }
        // meta.json相当 + sections（→ docs/07 2.4）
        let meta: PaperMeta
        if let fileMeta = try store.meta(of: paperId) {
            meta = fileMeta
        } else {
            let authors = try store.authors(of: paperId)
            meta = PaperMeta(paper: paper, authors: authors)
        }
        var dict = try JSONSerialization.jsonObject(with: meta.encode()) as? [String: Any] ?? [:]
        dict["sections"] = try sectionList(paperId: paperId)
        // 変換修正ワークフロー用の情報（→ docs/07 2.4節）
        let fm = FileManager.default
        let pdfPath = store.layout.pdfPath(paperId)
        if fm.fileExists(atPath: pdfPath.path) {
            dict["pdf_path"] = pdfPath.path
        }
        // 補助ファイル（Supplementary等 → docs/07 2節, docs/03 2節）
        let supplements = store.supplements(of: paperId)
        if !supplements.isEmpty {
            dict["supplements"] = supplements.map(\.path)
        }
        let corrector = FulltextCorrector(layout: store.layout)
        let corrected = store.layout.correctedMarkdownPath(paperId)
        let original = store.layout.markdownPath(paperId)
        if corrector.hasCorrections(paperId: paperId) {
            dict["markdown_path"] = corrected.path
        } else if fm.fileExists(atPath: original.path) {
            dict["markdown_path"] = original.path
        }
        dict["has_corrections"] = corrector.hasCorrections(paperId: paperId)
        if let warnings = paper.conversionWarnings {
            dict["conversion_warnings"] = warnings
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        return ToolCallResult(text: String(data: data, encoding: .utf8) ?? "{}")
    }

    // MARK: - apply_fulltext_patches（→ docs/07 2.6節）

    // MARK: - add_note（→ docs/07 2.7節）

    func addNote(_ args: [String: JSONValue]) throws -> ToolCallResult {
        guard let paperId = args["paper_id"]?.stringValue else {
            return .error("paper_id is required.")
        }
        guard let content = args["content"]?.stringValue, !content.isEmpty else {
            return .error("content is required.")
        }
        guard let paper = try store.paper(id: paperId), !paper.isStub else {
            return .error("Paper not found: \(paperId)")
        }
        let heading = args["heading"]?.stringValue ?? "AI Notes"
        let date = String(PaperdDates.nowString().prefix(10))
        let section = "## \(heading) (\(date))\n\n\(content)"
        // 既存ノートは保持し、末尾に追記（AIがユーザのメモを上書きしない → docs/07 2.7節）
        let existing = store.note(of: paperId)
        let merged = existing.map { $0.hasSuffix("\n") ? $0 + "\n" + section : $0 + "\n\n" + section } ?? section
        try store.saveNote(paperId: paperId, content: merged)
        // ノートを全文検索へ反映（→ docs/06 2節）
        let queue = JobQueue(db: store.db)
        try queue.enqueueIfAbsent(kind: .reindex, paperId: paperId, origin: .mcp)
        return ToolCallResult(text: "Appended to notes (\(paper.title)). The search index will be updated in the background.")
    }

    func applyFulltextPatches(_ args: [String: JSONValue]) throws -> ToolCallResult {
        guard let paperId = args["paper_id"]?.stringValue else {
            return .error("paper_id is required.")
        }
        guard try store.paper(id: paperId) != nil else {
            return .error("paper_id '\(paperId)' not found.")
        }
        guard case .array(let patchValues)? = args["patches"], !patchValues.isEmpty else {
            return .error("patches is required. Example: [{\"find\": \"103 Å\", \"replace\": \"10³ Å\"}]")
        }
        var patches: [FulltextCorrector.Patch] = []
        for value in patchValues {
            guard let find = value["find"]?.stringValue, let replace = value["replace"]?.stringValue, !find.isEmpty else {
                return .error("Each patch requires find and replace (non-empty strings).")
            }
            patches.append(.init(find: find, replace: replace))
        }

        let corrector = FulltextCorrector(layout: store.layout)
        do {
            try corrector.apply(paperId: paperId, patches: patches, note: args["note"]?.stringValue)
        } catch let error as FulltextCorrector.PatchError {
            return .error("\(error.description) (no patches were applied)")
        }

        // 修正版からの再チャンク・再embeddingをアプリへ委譲（→ docs/07 3節）
        let queue = JobQueue(db: store.db)
        try queue.enqueueIfAbsent(kind: .reindex, paperId: paperId, origin: .mcp)
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("jp.paperd.jobs.enqueued"), object: nil, userInfo: nil, deliverImmediately: true)
        #endif

        return ToolCallResult(text: Self.jsonString(.object([
            "paper_id": .string(paperId),
            "applied": .number(Double(patches.count)),
            "message": .string("Applied \(patches.count) patch(es) to paper.corrected.md. The paperd app rebuilds the search index in the background (or on next launch if the app is not running). The original conversion output (paper.md) is preserved."),
        ])))
    }

    // MARK: - add_paper

    func addPaper(_ args: [String: JSONValue]) async throws -> ToolCallResult {
        var identifier: PaperIdentifier?
        if let arxivId = args["arxiv_id"]?.stringValue, let parsed = PaperIdentifier.parseArxivID(arxivId) {
            identifier = .arxiv(id: parsed.id, version: parsed.version)
        } else if let doi = args["doi"]?.stringValue, let parsed = PaperIdentifier.parseDOI(doi) {
            identifier = .doi(parsed)
        } else if let url = args["url"]?.stringValue {
            identifier = PaperIdentifier.parseURL(url)
        }
        guard let identifier else {
            return .error("Specify one of arxiv_id, doi, or url in a valid format. Example: {\"arxiv_id\": \"1706.03762\"}")
        }

        // 1. メタデータ解決を同期実行（→ docs/07 2.5）
        let meta = try await resolver(identifier)

        // 重複: 既存paper_idを返す（マージ提案はしない → docs/04 5節）
        let existing = try store.db.read { dbc -> Paper? in
            if let doi = meta.doi, let p = try Paper.filter(Column("doi") == doi).fetchOne(dbc) { return p }
            if let arxivId = meta.arxivId, let p = try Paper.filter(Column("arxiv_id") == arxivId).fetchOne(dbc) { return p }
            return nil
        }
        if let existing, !existing.isStub {
            return ToolCallResult(text: Self.jsonString(.object([
                "paper_id": .string(existing.id),
                "title": .string(existing.title),
                "status": .string(existing.status),
                "message": .string("This paper is already in the library."),
            ])))
        }

        // 2. papers行INSERT（metadata_only）+ jobsへINSERT
        var paper = existing ?? Paper(title: meta.title)
        meta.apply(to: &paper)
        paper.isStub = false
        paper.paperStatus = .metadataOnly
        try store.savePaper(paper, authors: meta.authors.map {
            .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
        })
        let queue = JobQueue(db: store.db)
        var payload: [String: String] = [:]
        if let arxivId = meta.arxivId { payload["arxiv_id"] = arxivId }
        if let doi = meta.doi { payload["doi"] = doi }
        if let pdfURL = meta.pdfURL { payload["pdf_url"] = pdfURL }
        try queue.enqueue(kind: .ingest, paperId: paper.id, payload: payload, origin: .mcp)

        // 3. アプリへの通知（補助。主駆動はアプリのポーリング → docs/01 5節）
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("jp.paperd.jobs.enqueued"), object: nil, userInfo: nil, deliverImmediately: true)
        #endif

        return ToolCallResult(text: Self.jsonString(.object([
            "paper_id": .string(paper.id),
            "title": .string(paper.title),
            "year": paper.year.map { .number(Double($0)) } ?? .null,
            "status": .string(paper.status),
            "message": .string("Bibliographic metadata registered. The paperd app downloads the PDF and builds the full-text index in the background. If the app is not running, this happens on its next launch."),
        ])))
    }

    // MARK: - util

    static func jsonString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
