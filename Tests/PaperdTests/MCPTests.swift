import Foundation
import Testing
import PaperdCore
import PaperdMCPKit

@Suite("MCPServer")
struct MCPTests {
    func makeServer(embedder: QueryEmbedder? = FakeEmbedder()) throws -> (MCPServer, LibraryStore, URL) {
        let (store, root) = try makeTempLibrary()
        let tools = PaperdTools(
            store: store,
            embedderProvider: { embedder },
            resolver: { _ in sampleResolved() }
        )
        return (MCPServer(tools: tools), store, root)
    }

    func callTool(_ server: MCPServer, name: String, args: [String: JSONValue]) async throws -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(args)]))
        let response = try #require(await server.handle(request: request))
        let result = try #require(response.result, "result")
        let content = try #require(result["content"], "content")
        guard case .array(let items) = content, case .object(let first)? = items.first,
              case .string(let text)? = first["text"]
        else {
            throw TestError("contentの形式が不正")
        }
        var isError = false
        if case .bool(let e)? = result["isError"] { isError = e }
        return (text, isError)
    }

    struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    @Test("initializeハンドシェイク")
    func initializeHandshake() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let response = try #require(await server.handle(
            request: JSONRPCRequest(id: .number(0), method: "initialize")))
        let result = try #require(response.result)
        #expect(result["protocolVersion"]?.stringValue == "2024-11-05")
        #expect(result["serverInfo"]?["name"]?.stringValue == "paperd")
        // 通知にはレスポンスしない
        let none = await server.handle(request: JSONRPCRequest(id: nil, method: "notifications/initialized"))
        #expect(none == nil)
    }

    @Test("tools/listは8ツール")
    func toolsList() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let response = try #require(await server.handle(
            request: JSONRPCRequest(id: .number(1), method: "tools/list")))
        guard case .array(let tools)? = response.result?["tools"] else {
            throw TestError("toolsがない")
        }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == ["search_papers", "get_bibtex", "get_fulltext", "get_paper_metadata", "add_paper", "apply_fulltext_patches", "add_note", "get_citations"])
    }

    @Test("未知メソッドはmethod not found")
    func unknownMethod() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let response = try #require(await server.handle(
            request: JSONRPCRequest(id: .number(2), method: "resources/list")))
        #expect(response.error?.code == -32601)
    }

    @Test("不正なJSON行にはparse error")
    func parseError() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let raw = try #require(await server.handle(line: "not json"))
        #expect(raw.contains("-32700"), Comment(rawValue: raw))
    }

    @Test("add_paper: 書誌登録 + ジョブ投入")
    func addPaper() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await callTool(server, name: "add_paper", args: ["arxiv_id": .string("1706.03762")])
        #expect(!isError, Comment(rawValue: text))
        #expect(text.contains("metadata_only"))
        #expect(text.contains("Attention Is All You Need"))

        let papers = try store.allPapers()
        #expect(papers.count == 1)
        let jobs = try JobQueue(db: store.db).jobs(status: .queued)
        try #require(jobs.count == 1)
        #expect(jobs[0].origin == "mcp")
        #expect(jobs[0].kind == "ingest")
    }

    @Test("add_paper: 重複は既存paper_idを返しジョブを投入しない")
    func addPaperDuplicate() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        _ = try await callTool(server, name: "add_paper", args: ["arxiv_id": .string("1706.03762")])
        let (text2, isError2) = try await callTool(server, name: "add_paper", args: ["doi": .string("10.5555/3295222.3295349")])
        #expect(!isError2)
        #expect(text2.contains("already in the library"), Comment(rawValue: text2))
        #expect(try JobQueue(db: store.db).jobs(status: .queued).count == 1, "ジョブは増えない")
    }

    @Test("add_paper: 不正な識別子はエラー案内")
    func addPaperInvalidIdentifier() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await callTool(server, name: "add_paper", args: ["arxiv_id": .string("not-an-id")])
        #expect(isError)
        #expect(text.contains("arxiv_id"), Comment(rawValue: text))
    }

    @Test("get_bibtex: paper_id / doi / arxiv_id指定")
    func getBibtex() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)

        for args in [
            ["paper_id": JSONValue.string(paper.id)],
            ["doi": .string(try #require(paper.doi))],
            ["arxiv_id": .string(try #require(paper.arxivId))],
        ] {
            let (text, isError) = try await callTool(server, name: "get_bibtex", args: args)
            #expect(!isError, Comment(rawValue: text))
            #expect(text.hasPrefix("@inproceedings{vaswani2017attention,"), Comment(rawValue: text))
        }
    }

    @Test("add_note: 既存ノートを保持して追記、reindexジョブ投入")
    func addNote() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try store.saveNote(paperId: paper.id, content: "# 自分のメモ\n大事")

        let (text, isError) = try await callTool(server, name: "add_note", args: [
            "paper_id": .string(paper.id),
            "content": .string("調査結果のサマリ"),
            "heading": .string("文献調査"),
        ])
        #expect(!isError, Comment(rawValue: text))

        let note = try #require(store.note(of: paper.id))
        #expect(note.hasPrefix("# 自分のメモ"), "既存ノートは保持")
        #expect(note.contains("## 文献調査 ("))
        #expect(note.contains("調査結果のサマリ"))
        let jobs = try JobQueue(db: store.db).jobs(status: .queued)
        #expect(jobs.contains { $0.kind == "reindex" && $0.origin == "mcp" }, "検索への反映ジョブ")
    }

    @Test("add_note: 存在しない論文はエラー")
    func addNoteMissingPaper() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await callTool(server, name: "add_note", args: [
            "paper_id": .string("nope"), "content": .string("x"),
        ])
        #expect(isError, Comment(rawValue: text))
    }

    @Test("get_bibtex: 見つからない場合は形式例つきエラー")
    func getBibtexNotFound() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await callTool(server, name: "get_bibtex", args: ["doi": .string("10.9/none")])
        #expect(isError)
        #expect(text.contains("10.5555"), "形式例を含む: \(text)")
    }

    @Test("get_paper_metadata: sections付きJSON")
    func getPaperMetadata() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)
        try SearchIndex(db: store.db).indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: "1. Introduction", text: "intro", tokenCount: 1),
            Chunker.Piece(sectionPath: "3. Method", text: "method", tokenCount: 1),
        ])
        let (text, isError) = try await callTool(server, name: "get_paper_metadata", args: ["paper_id": .string(paper.id)])
        #expect(!isError, Comment(rawValue: text))
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let dict = try #require(json)
        #expect(dict["title"] as? String == paper.title)
        #expect((dict["sections"] as? [String]) ?? [] == ["1. Introduction", "3. Method"])
        #expect((dict["authors"] as? [[String: Any]])?.count == 2)
        #expect(dict["supplements"] == nil, "添付なしではキー自体を出さない")

        // 添付を追加すると一覧が出る（→ docs/07 2節）
        let source = root.appendingPathComponent("mmc1.pdf")
        try Data("%PDF supp".utf8).write(to: source)
        try store.addSupplement(paperId: paper.id, from: source)
        let (text2, _) = try await callTool(server, name: "get_paper_metadata", args: ["paper_id": .string(paper.id)])
        let dict2 = try #require(try JSONSerialization.jsonObject(with: Data(text2.utf8)) as? [String: Any])
        let supplements = try #require(dict2["supplements"] as? [String])
        #expect(supplements.count == 1 && supplements[0].hasSuffix("mmc1.pdf"))
    }

    @Test("get_fulltext: 全文・section指定・存在しないsection")
    func getFulltext() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        let fulltext = "# Paper\n\n" + String(repeating: "Long body text. ", count: 100)
        try Data(fulltext.utf8).write(to: store.layout.markdownPath(paper.id))
        try SearchIndex(db: store.db).indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: "3. Method > 3.2 Training", text: "We train with Adam.", tokenCount: 4),
        ])

        // 全文
        let (full, e1) = try await callTool(server, name: "get_fulltext", args: ["paper_id": .string(paper.id)])
        #expect(!e1)
        #expect(full == fulltext)

        // section前方一致
        let (section, e2) = try await callTool(server, name: "get_fulltext", args: [
            "paper_id": .string(paper.id), "section": .string("3. Method"),
        ])
        #expect(!e2)
        #expect(section.contains("We train with Adam."), Comment(rawValue: section))

        // 存在しないsectionはセクション一覧つきエラー
        let (missing, e3) = try await callTool(server, name: "get_fulltext", args: [
            "paper_id": .string(paper.id), "section": .string("99. Nope"),
        ])
        #expect(e3)
        #expect(missing.contains("3. Method > 3.2 Training"), Comment(rawValue: missing))
    }

    @Test("get_fulltext: 上限超過で切り詰めとセクション案内")
    func getFulltextTruncation() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let tools = PaperdTools(
            store: store,
            embedderProvider: { nil },
            resolver: { _ in sampleResolved() },
            fulltextLimit: 100
        )
        let server = MCPServer(tools: tools)
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try Data(String(repeating: "x", count: 500).utf8).write(to: store.layout.markdownPath(paper.id))
        try SearchIndex(db: store.db).indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: "1. Introduction", text: "intro", tokenCount: 1),
        ])
        let (text, _) = try await callTool(server, name: "get_fulltext", args: ["paper_id": .string(paper.id)])
        #expect(text.contains("[truncated: 500 chars total."), Comment(rawValue: String(text.suffix(200))))
        #expect(text.contains("1. Introduction"), "セクション案内")
    }

    @Test("get_fulltext: Markdown未生成は案内エラー")
    func getFulltextMissing() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        let (text, isError) = try await callTool(server, name: "get_fulltext", args: ["paper_id": .string(paper.id)])
        #expect(isError)
        #expect(text.contains("no full-text Markdown"), Comment(rawValue: text))
    }

    @Test("search_papers: ヒットとスキーマ")
    func searchPapers() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)
        let pieces = [Chunker.Piece(sectionPath: "3. Method", text: "scaled dot product attention transformer", tokenCount: 6)]
        try SearchIndex(db: store.db).indexPaper(
            paperId: paper.id, pieces: pieces,
            embeddings: pieces.map { FakeEmbedder.embed($0.text) })

        let (text, isError) = try await callTool(server, name: "search_papers", args: ["query": .string("attention transformer")])
        #expect(!isError, Comment(rawValue: text))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let results = try #require(json["results"] as? [[String: Any]])
        try #require(results.count == 1)
        #expect(results[0]["paper_id"] as? String == paper.id)
        #expect(results[0]["match_type"] as? String == "hybrid")
        #expect((results[0]["authors"] as? [String]) ?? [] == ["Ashish Vaswani", "Noam Shazeer"])
        #expect(results[0]["snippet"] as? String != nil)
    }

    @Test("search_papers: embedder不在はwarming_up付きFTS応答")
    func searchPapersWarmingUp() async throws {
        let (server, store, root) = try makeServer(embedder: nil)
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try SearchIndex(db: store.db).indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: nil, text: "attention transformer", tokenCount: 2),
        ])
        let (text, isError) = try await callTool(server, name: "search_papers", args: ["query": .string("attention")])
        #expect(!isError)
        #expect(text.contains("warming_up"), Comment(rawValue: text))
    }

    @Test("search_papers: mode=keywordはembedderがあってもFTS5のみ・warming_upを付けない")
    func searchPapersKeywordMode() async throws {
        // embedderは存在するが、mode=keywordなら使わない
        let (server, store, root) = try makeServer(embedder: FakeEmbedder())
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)
        let pieces = [Chunker.Piece(sectionPath: "3. Method", text: "scaled dot product attention transformer", tokenCount: 6)]
        try SearchIndex(db: store.db).indexPaper(
            paperId: paper.id, pieces: pieces,
            embeddings: pieces.map { FakeEmbedder.embed($0.text) })

        let (text, isError) = try await callTool(server, name: "search_papers", args: [
            "query": .string("attention transformer"), "mode": .string("keyword"),
        ])
        #expect(!isError, Comment(rawValue: text))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["mode"] as? String == "keyword")
        #expect(json["semantic"] == nil, "keyword指定ではwarming_upを付けない")
        let results = try #require(json["results"] as? [[String: Any]])
        try #require(results.count == 1)
        #expect(results[0]["match_type"] as? String == "keyword", Comment(rawValue: text))
    }

    @Test("get_citations: references/citationsをin_library付きで返す")
    func getCitations() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: sampleAuthors)
        // ライブラリ内の被引用元
        let citer = samplePaper(title: "BERT", doi: "10.1/bert", arxivId: "1810.04805", year: 2018)
        try store.savePaper(citer, authors: [])

        let citations = CitationStore(db: store.db)
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Neural MT by Jointly Learning", year: 2014, doi: "10.1/bahdanau")],
            citations: [.init(title: "BERT", doi: "10.1/bert", arxivId: "1810.04805")],
            source: .s2)

        let (text, isError) = try await callTool(server, name: "get_citations", args: ["paper_id": .string(center.id)])
        #expect(!isError, Comment(rawValue: text))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "ok", "新鮮なキャッシュ")
        let refs = try #require(json["references"] as? [[String: Any]])
        try #require(refs.count == 1)
        #expect(refs[0]["title"] as? String == "Neural MT by Jointly Learning")
        #expect(refs[0]["in_library"] as? Bool == false, "ライブラリ外はstub")
        let cites = try #require(json["citations"] as? [[String: Any]])
        try #require(cites.count == 1)
        #expect(cites[0]["title"] as? String == "BERT")
        #expect(cites[0]["in_library"] as? Bool == true, "ライブラリ内論文に解決される")
        #expect(cites[0]["paper_id"] as? String == citer.id)
    }

    @Test("get_citations: direction指定でその方向だけ返す")
    func getCitationsDirection() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Ref", year: 2010)],
            citations: [.init(title: "Citer", year: 2020)],
            source: .s2)

        let (text, _) = try await callTool(server, name: "get_citations", args: [
            "paper_id": .string(center.id), "direction": .string("references"),
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["references"] != nil)
        #expect(json["citations"] == nil, "citations方向は返さない")
    }

    @Test("get_citations: キャッシュ未取得かつ外部IDありはrefetchジョブ投入 + status=fetching")
    func getCitationsFetching() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let center = samplePaper() // doi / arxiv_id を持つ
        try store.savePaper(center, authors: [])

        let (text, isError) = try await callTool(server, name: "get_citations", args: ["paper_id": .string(center.id)])
        #expect(!isError, Comment(rawValue: text))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "fetching", Comment(rawValue: text))
        let jobs = try JobQueue(db: store.db).jobs(status: .queued)
        #expect(jobs.contains { $0.kind == "refetch_citations" && $0.origin == "mcp" }, "取得ジョブが投入される")
    }

    @Test("get_citations: 外部IDなし・エッジなしはunavailable（ジョブ投入なし）")
    func getCitationsUnavailable() async throws {
        let (server, store, root) = try makeServer()
        defer { cleanup(root) }
        let local = samplePaper(title: "Local only", doi: nil, arxivId: nil, booktitle: nil)
        try store.savePaper(local, authors: [])

        let (text, _) = try await callTool(server, name: "get_citations", args: ["paper_id": .string(local.id)])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "unavailable", Comment(rawValue: text))
        #expect(try JobQueue(db: store.db).jobs(status: .queued).isEmpty, "取得できないのでジョブは投入しない")
    }

    @Test("get_citations: 存在しない論文はエラー")
    func getCitationsMissing() async throws {
        let (server, _, root) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await callTool(server, name: "get_citations", args: ["paper_id": .string("nope")])
        #expect(isError, Comment(rawValue: text))
    }

}
