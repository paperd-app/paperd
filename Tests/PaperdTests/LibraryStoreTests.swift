import Foundation
import Testing
import PaperdCore

@Suite("LibraryStore")
struct LibraryStoreTests {
    @Test("ライブラリ作成: library.json / ディレクトリ")
    func createLibrary() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.layout.libraryJSON.path))
        #expect(fm.fileExists(atPath: store.layout.papersDir.path))
        #expect(fm.fileExists(atPath: store.layout.databasePath.path))
    }

    @Test("openは未初期化ディレクトリでエラー")
    func openUninitialized() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paperd-nonexistent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { _ = try LibraryStore.open(at: root) }
    }

    @Test("savePaper: meta.json書き出し + DB行 + 著者")
    func savePaper() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)

        let meta = try #require(try store.meta(of: paper.id))
        #expect(meta.title == paper.title)
        #expect(meta.authors.count == 2)
        #expect(meta.authors[0].displayName == "Ashish Vaswani")

        let fetched = try #require(try store.paper(id: paper.id))
        #expect(fetched.doi == paper.doi)
        let authors = try store.authors(of: paper.id)
        #expect(authors.map(\.displayName) == ["Ashish Vaswani", "Noam Shazeer"])
    }

    @Test("meta.jsonのCodableラウンドトリップ")
    func metaRoundtrip() throws {
        let paper = samplePaper()
        let meta = PaperMeta(
            paper: paper,
            authors: [Author(displayName: "Ashish Vaswani", s2AuthorId: "1738948")],
            citationKeyOverride: "custom2017"
        )
        let decoded = try PaperMeta.decode(from: try meta.encode())
        #expect(decoded == meta)
        #expect(decoded.formatVersion == 1)
        let restored = decoded.toPaper()
        #expect(restored.id == paper.id)
        #expect(restored.title == paper.title)
        #expect(restored.doi == paper.doi)
    }

    @Test("stub論文はmeta.jsonを持たない")
    func stubHasNoMeta() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var stub = samplePaper(title: "Cited Work", doi: "10.1/stub", arxivId: nil)
        stub.isStub = true
        try store.savePaper(stub, authors: [])
        #expect(!FileManager.default.fileExists(atPath: store.layout.metaJSONPath(stub.id).path))
        #expect(try store.paper(id: stub.id) != nil)
    }

    @Test("s2_author_id一致で著者行を再利用")
    func authorReuse() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let p1 = samplePaper()
        try store.savePaper(p1, authors: sampleAuthors)
        let p2 = samplePaper(title: "Another", doi: "10.1/x2", arxivId: "2001.00001")
        try store.savePaper(p2, authors: [.init(displayName: "Ashish Vaswani", s2AuthorId: "1738948")])
        let count = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM authors WHERE display_name = 'Ashish Vaswani'") ?? 0
        }
        #expect(count == 1, "同一s2_author_idは1行")
    }

    @Test("ノート保存: notes.md + notes索引")
    func saveNote() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try store.saveNote(paperId: paper.id, content: "# 読みメモ\n重要")
        #expect(store.note(of: paper.id) == "# 読みメモ\n重要")
        // 2回目は上書き（行は1つ）
        try store.saveNote(paperId: paper.id, content: "更新")
        let count = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes WHERE paper_id = ?", arguments: [paper.id]) ?? 0
        }
        #expect(count == 1)
        #expect(store.note(of: paper.id) == "更新")
    }


    @Test("削除でディレクトリとDB行（CASCADE）が消える")
    func deletePaper() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)
        try store.saveNote(paperId: paper.id, content: "note")
        try store.deletePaper(id: paper.id)
        #expect(try store.paper(id: paper.id) == nil)
        let noteCount = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
        }
        #expect(noteCount == 0, "notesもCASCADE削除")
    }

    @Test("削除: jobs行が参照していても削除できる（FK対応）")
    func deletePaperWithJobs() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        // 取り込み完了後の典型状態: succeededなジョブがpaper_idを参照している
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, paperId: paper.id, payload: [:], origin: .app)
        try queue.succeed(job.id)

        try store.deletePaper(id: paper.id)
        #expect(try store.paper(id: paper.id) == nil)
        #expect(try queue.jobs().isEmpty, "該当jobs行も削除される")
    }

    @Test("削除: 孤児になったstub行は掃除、共有stubは残る")
    func deletePaperCleansOrphanStubs() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let citations = CitationStore(db: store.db)

        let paperA = samplePaper(title: "A", doi: "10.1/a", arxivId: nil)
        let paperB = samplePaper(title: "B", doi: "10.1/b", arxivId: nil)
        try store.savePaper(paperA, authors: [])
        try store.savePaper(paperB, authors: [])
        // Aのみが参照するstubと、A・B両方が参照するstub
        try citations.replaceEdges(center: paperA.id, references: [
            .init(title: "Only A cites", s2PaperId: "s2-only-a"),
            .init(title: "Shared", s2PaperId: "s2-shared"),
        ], citations: [], source: .s2)
        try citations.replaceEdges(center: paperB.id, references: [
            .init(title: "Shared", s2PaperId: "s2-shared"),
        ], citations: [], source: .s2)

        try store.deletePaper(id: paperA.id)

        let stubs = try store.db.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM papers WHERE is_stub = 1 ORDER BY title")
        }
        #expect(stubs == ["Shared"], "孤児stubは消え、Bが参照するstubは残る")
    }

    @Test("インデックス再構築: meta.jsonからDBを復元（フラグ含む）")
    func rebuildIndex() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)
        try store.setFavorite(paper.id, true)
        try store.setOwn(paper.id, true)

        // DBを破壊（全行削除）してファイルから再構築
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM paper_authors; DELETE FROM authors; DELETE FROM papers;")
        }
        #expect(try store.paper(id: paper.id) == nil)
        try store.rebuildIndexFromFiles()

        let restored = try #require(try store.paper(id: paper.id))
        #expect(restored.title == paper.title)
        #expect(restored.doi == paper.doi)
        #expect(restored.isFavorite && restored.isOwn, "フラグはmeta.jsonから復元される")
        #expect(try store.authors(of: paper.id).map(\.displayName) == ["Ashish Vaswani", "Noam Shazeer"])
    }

    @Test("allPapersはstub除外・追加日降順")
    func allPapersOrdering() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var old = samplePaper(title: "Old", doi: "10.1/old", arxivId: nil)
        old.addedAt = "2020-01-01T00:00:00Z"
        try store.savePaper(old, authors: [])
        var new = samplePaper(title: "New", doi: "10.1/new", arxivId: nil)
        new.addedAt = "2026-01-01T00:00:00Z"
        try store.savePaper(new, authors: [])
        var stub = samplePaper(title: "Stub", doi: "10.1/stub", arxivId: nil)
        stub.isStub = true
        try store.savePaper(stub, authors: [])
        let papers = try store.allPapers()
        #expect(papers.map(\.title) == ["New", "Old"])
    }
}

/// ダッシュボード統計用クエリ（→ docs/09 4.2節）
@Suite("ダッシュボード統計")
struct DashboardStatsTests {
    @Test("notedPaperIds: ノートを持つ論文のID集合")
    func notedPaperIds() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let withNote = samplePaper()
        let without = samplePaper(title: "No Note", doi: "10.1000/nonote", arxivId: nil)
        try store.savePaper(withNote, authors: [])
        try store.savePaper(without, authors: [])
        try store.saveNote(paperId: withNote.id, content: "メモ")
        #expect(try store.notedPaperIds() == [withNote.id])
    }
}

/// 補助ファイル（Supplementary等 → docs/03 2節, docs/09 4節）
@Suite("添付ファイル")
struct SupplementsTests {
    @Test("追加・一覧・同名の連番付与")
    func addAndList() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        #expect(store.supplements(of: paper.id).isEmpty, "フォルダなしは空")

        let source = root.appendingPathComponent("mmc1.pdf")
        try Data("%PDF supp".utf8).write(to: source)
        try store.addSupplement(paperId: paper.id, from: source)
        try store.addSupplement(paperId: paper.id, from: source)  // 同名再追加

        let files = store.supplements(of: paper.id).map(\.lastPathComponent)
        #expect(files == ["mmc1 2.pdf", "mmc1.pdf"], "連番付与でファイル名順: \(files)")
    }

    @Test("存在しない論文への追加はエラー")
    func addToMissingPaper() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let source = root.appendingPathComponent("x.pdf")
        try Data("%PDF".utf8).write(to: source)
        #expect(throws: (any Error).self) {
            try store.addSupplement(paperId: "nonexistent", from: source)
        }
    }

    @Test("論文削除で添付ごと消える")
    func deletedWithPaper() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        let source = root.appendingPathComponent("si.mp4")
        try Data("movie".utf8).write(to: source)
        try store.addSupplement(paperId: paper.id, from: source)

        try store.deletePaper(id: paper.id)
        #expect(!FileManager.default.fileExists(atPath: store.layout.supplementsDir(paper.id).path))
    }
}
