import Foundation
import GRDB

/// 引用関係のキャッシュ管理（→ docs/08-citation-graph.md 3節）。
/// ライブラリ外の論文はstub行（is_stub = 1、書誌のみ）としてpapersに保持し、
/// citationsエッジの両端が常にpapers.idを参照できるようにする。
public struct CitationStore: Sendable {
    public let db: AppDatabase
    /// citations取得の既定TTL（→ docs/08 3節）
    public static let defaultTTLDays = 30

    public init(db: AppDatabase) {
        self.db = db
    }

    /// stub論文の書誌（S2 / OpenAlexのレスポンスから構築）
    public struct StubInfo: Equatable, Sendable {
        public var title: String
        public var year: Int?
        public var venue: String?
        public var s2PaperId: String?
        public var doi: String?
        public var arxivId: String?
        public var openalexId: String?
        public var authors: [String]

        public init(
            title: String,
            year: Int? = nil,
            venue: String? = nil,
            s2PaperId: String? = nil,
            doi: String? = nil,
            arxivId: String? = nil,
            openalexId: String? = nil,
            authors: [String] = []
        ) {
            self.title = title
            self.year = year
            self.venue = venue
            self.s2PaperId = s2PaperId
            self.doi = doi
            self.arxivId = arxivId
            self.openalexId = openalexId
            self.authors = authors
        }
    }

    /// stub論文をupsertしてpaper_idを返す。
    /// 外部ID（s2_paper_id / doi / arxiv_id）で重複排除し、既存行（stub・非stubとも）があれば再利用する（→ docs/08 3節）。
    @discardableResult
    public func upsertStub(_ info: StubInfo) throws -> String {
        try db.write { dbc in
            try Self.upsertStub(dbc, info)
        }
    }

    static func upsertStub(_ dbc: Database, _ info: StubInfo) throws -> String {
        var info = info
        // stub書誌にもマークアップが混入する（→ docs/04 3節）
        info.title = MetadataSanitizer.clean(info.title)
        if let venue = info.venue { info.venue = MetadataSanitizer.clean(venue) }
        if let existing = try findByExternalIds(dbc, s2PaperId: info.s2PaperId, doi: info.doi, arxivId: info.arxivId, openalexId: info.openalexId) {
            // 既存stub行の欠落フィールドを補完（非stub行はライブラリ正本なので触らない）
            if existing.isStub {
                var paper = existing
                if paper.year == nil { paper.year = info.year }
                if paper.venue == nil { paper.venue = info.venue }
                if paper.s2PaperId == nil { paper.s2PaperId = info.s2PaperId }
                if paper.doi == nil { paper.doi = info.doi }
                if paper.arxivId == nil { paper.arxivId = info.arxivId }
                if paper.openalexId == nil { paper.openalexId = info.openalexId }
                paper.updatedAt = PaperdDates.nowString()
                try paper.save(dbc)
            }
            return existing.id
        }
        var paper = Paper(
            title: info.title,
            year: info.year,
            venue: info.venue,
            doi: info.doi,
            arxivId: info.arxivId,
            s2PaperId: info.s2PaperId,
            openalexId: info.openalexId,
            status: .stub,
            isStub: true
        )
        paper.paperStatus = .stub
        try paper.save(dbc)
        for (i, name) in info.authors.enumerated() {
            let author = Author(displayName: name)
            try author.save(dbc)
            try PaperAuthor(paperId: paper.id, authorId: author.id, position: i).save(dbc)
        }
        return paper.id
    }

    static func findByExternalIds(_ dbc: Database, s2PaperId: String?, doi: String?, arxivId: String?, openalexId: String? = nil) throws -> Paper? {
        if let s2PaperId, let p = try Paper.filter(Column("s2_paper_id") == s2PaperId).fetchOne(dbc) { return p }
        if let doi, let p = try Paper.filter(Column("doi") == doi).fetchOne(dbc) { return p }
        if let arxivId, let p = try Paper.filter(Column("arxiv_id") == arxivId).fetchOne(dbc) { return p }
        if let openalexId, let p = try Paper.filter(Column("openalex_id") == openalexId).fetchOne(dbc) { return p }
        return nil
    }

    /// 中心論文のエッジを更新する。
    /// references = 中心が引用する論文（center → cited）、citations = 中心を引用する論文（citing → center）。
    ///
    /// - 出方向（references）は全件取得できるため**差し替え**（古い出エッジを削除）
    /// - 入方向（citations）は上限つき取得（→ docs/08 3節）のため**upsert**。
    ///   全削除すると他の中心論文の取得結果（X → center エッジ）まで失われるため削除しない
    public func replaceEdges(
        center paperId: String,
        references: [StubInfo],
        citations: [StubInfo],
        source: CitationSource
    ) throws {
        try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM citations WHERE citing_id = ?", arguments: [paperId])
            let now = PaperdDates.nowString()
            for ref in references {
                let citedId = try Self.upsertStub(dbc, ref)
                guard citedId != paperId else { continue }
                try Citation(citingId: paperId, citedId: citedId, source: source, fetchedAt: now).save(dbc)
            }
            for cite in citations {
                let citingId = try Self.upsertStub(dbc, cite)
                guard citingId != paperId else { continue }
                try Citation(citingId: citingId, citedId: paperId, source: source, fetchedAt: now).save(dbc)
            }
        }
    }

    /// 中心論文のエッジのfetched_atがTTLを超過しているか（エッジ未取得もtrue → 取得が必要）
    public func isStale(paperId: String, ttlDays: Int = defaultTTLDays, now: Date = Date()) throws -> Bool {
        let latest = try db.read { dbc in
            try String.fetchOne(dbc, sql: """
                SELECT MAX(fetched_at) FROM citations WHERE citing_id = ? OR cited_id = ?
                """, arguments: [paperId, paperId])
        }
        guard let latest, let fetchedAt = PaperdDates.date(from: latest) else { return true }
        return now.timeIntervalSince(fetchedAt) > Double(ttlDays) * 24 * 3600
    }

    /// エッジの**追加**（補完マージ用 → docs/08 1節）。
    /// `INSERT OR IGNORE` で既存エッジを上書きしない（source列は先に取得した側を保持）。
    public func addEdges(
        center paperId: String,
        references: [StubInfo],
        citations: [StubInfo],
        source: CitationSource
    ) throws {
        try db.write { dbc in
            let now = PaperdDates.nowString()
            for ref in references {
                let citedId = try Self.upsertStub(dbc, ref)
                guard citedId != paperId else { continue }
                try dbc.execute(
                    sql: "INSERT OR IGNORE INTO citations (citing_id, cited_id, source, fetched_at) VALUES (?, ?, ?, ?)",
                    arguments: [paperId, citedId, source.rawValue, now])
            }
            for cite in citations {
                let citingId = try Self.upsertStub(dbc, cite)
                guard citingId != paperId else { continue }
                try dbc.execute(
                    sql: "INSERT OR IGNORE INTO citations (citing_id, cited_id, source, fetched_at) VALUES (?, ?, ?, ?)",
                    arguments: [citingId, paperId, source.rawValue, now])
            }
        }
    }

    /// stub行を取り込み行へ吸収する（→ docs/04 4節, docs/08 4節）。
    /// ローカルPDF取り込みの書誌解決が既存stubと同じDOIに確定した場合に使う。
    /// 引用エッジをpaperIdへ付け替え、stub行を削除する（ファイルを持つ取り込み行のIDが正）。
    public func absorb(stubId: String, into paperId: String) throws {
        guard stubId != paperId else { return }
        try db.write { dbc in
            guard let stub = try Paper.fetchOne(dbc, key: stubId), stub.isStub else { return }
            // 両者間のエッジは自己参照になるため先に除去
            try dbc.execute(sql: """
                DELETE FROM citations
                WHERE (citing_id = ? AND cited_id = ?) OR (citing_id = ? AND cited_id = ?)
                """, arguments: [stubId, paperId, paperId, stubId])
            // エッジ付け替え（既存エッジと衝突する分はスキップし、stub行のCASCADE削除に任せる）
            try dbc.execute(sql: "UPDATE OR IGNORE citations SET citing_id = ? WHERE citing_id = ?", arguments: [paperId, stubId])
            try dbc.execute(sql: "UPDATE OR IGNORE citations SET cited_id = ? WHERE cited_id = ?", arguments: [paperId, stubId])
            try Paper.deleteOne(dbc, key: stubId)
        }
    }

    // MARK: - エゴネットワーク（→ docs/08 5節）

    public struct EgoNetwork: Equatable, Sendable {
        public var center: String
        public var nodes: [Paper]
        public var edges: [Citation]
        /// 表示上限による間引き（ノードID → 省略エッジ数。「+N件省略」表示用 → docs/08 6節）
        public var omittedEdgeCounts: [String: Int]

        public init(center: String, nodes: [Paper], edges: [Citation], omittedEdgeCounts: [String: Int] = [:]) {
            self.center = center
            self.nodes = nodes
            self.edges = edges
            self.omittedEdgeCounts = omittedEdgeCounts
        }
    }

    /// 表示の関係フィルタ（→ docs/08 6節）
    public enum CitationRelation: String, CaseIterable, Sendable {
        /// すべて
        case all
        /// 参考文献 = 中心が引用している方向（citing → cited）に到達可能な部分グラフ
        case references
        /// 被引用 = 中心を引用している方向（逆向き）に到達可能な部分グラフ
        case citations
    }

    /// 中心論文から1〜2ホップのエゴネットワークを取得する。
    /// ハブ論文（次数1,000超）対策として表示上限を設ける（→ docs/08 6節）:
    /// 1ホップ150・2ホップ50/ノード・全体400ノード。間引いた数はomittedEdgeCountsに記録。
    public func egoNetwork(
        center paperId: String,
        hops: Int = 1,
        secondHopLimit: Int = 50,
        firstHopLimit: Int = 150,
        maxNodes: Int = 400
    ) throws -> EgoNetwork {
        try db.read { dbc in
            var nodeIds: Set<String> = [paperId]
            var edges: [Citation] = []
            var omitted: [String: Int] = [:]

            let firstHopTotal = try Self.edgeCount(dbc, of: paperId)
            let firstHop = try Self.edges(dbc, of: paperId, limit: firstHopLimit)
            if firstHopTotal > firstHop.count {
                omitted[paperId] = firstHopTotal - firstHop.count
            }
            edges.append(contentsOf: firstHop)
            for e in firstHop {
                nodeIds.insert(e.citingId)
                nodeIds.insert(e.citedId)
            }

            if hops >= 2 {
                let firstHopNodes = nodeIds.subtracting([paperId])
                for node in firstHopNodes.sorted() {
                    // 全体ノード上限に達したら展開を打ち切る（→ docs/08 6節）
                    guard nodeIds.count < maxNodes else { break }
                    let total = try Self.edgeCount(dbc, of: node)
                    let second = try Self.edges(dbc, of: node, limit: secondHopLimit)
                    if total > second.count {
                        omitted[node, default: 0] += total - second.count
                    }
                    for e in second {
                        guard nodeIds.count < maxNodes
                            || (nodeIds.contains(e.citingId) && nodeIds.contains(e.citedId)) else { continue }
                        edges.append(e)
                        nodeIds.insert(e.citingId)
                        nodeIds.insert(e.citedId)
                    }
                }
            }

            // エッジ重複排除 + 両端が採用ノードのもののみ
            var seen = Set<String>()
            edges = edges.filter {
                nodeIds.contains($0.citingId) && nodeIds.contains($0.citedId)
                    && seen.insert("\($0.citingId)->\($0.citedId)").inserted
            }

            let nodes = try Paper.filter(nodeIds.contains(Column("id"))).fetchAll(dbc)
            return EgoNetwork(center: paperId, nodes: nodes, edges: edges, omittedEdgeCounts: omitted)
        }
    }

    static func edgeCount(_ dbc: Database, of paperId: String) throws -> Int {
        try Int.fetchOne(dbc,
            sql: "SELECT COUNT(*) FROM citations WHERE citing_id = ? OR cited_id = ?",
            arguments: [paperId, paperId]) ?? 0
    }

    static func edges(_ dbc: Database, of paperId: String, limit: Int? = nil) throws -> [Citation] {
        var sql = "SELECT * FROM citations WHERE citing_id = ? OR cited_id = ?"
        if let limit { sql += " LIMIT \(limit)" }
        return try Citation.fetchAll(dbc, sql: sql, arguments: [paperId, paperId])
    }

    // MARK: - 自著被引用ネットワーク（→ docs/09 4.1節）

    /// 自著論文（is_own = 1）集合を中心とした被引用ネットワーク
    public struct OwnNetwork: Equatable, Sendable {
        public var ownIds: Set<String>
        public var nodes: [Paper]
        public var edges: [Citation]
        /// 間引き前の総被引用エッジ数（統計ヘッダは真値を表示 → docs/08 6節）
        public var totalIncomingCount: Int = 0
        public var totalUniqueCiterCount: Int = 0

        /// 外部からの被引用エッジ数（自著間の引用は含めない）
        public var incomingCitationCount: Int {
            max(totalIncomingCount,
                edges.filter { ownIds.contains($0.citedId) && !ownIds.contains($0.citingId) }.count)
        }

        /// ユニークな引用元論文数（自著を除く）
        public var uniqueCiterCount: Int {
            max(totalUniqueCiterCount,
                Set(edges.filter { ownIds.contains($0.citedId) }.map(\.citingId)).subtracting(ownIds).count)
        }

        /// 自著論文ごとの被引用数（ノードサイズ用）
        public func citationCount(of paperId: String) -> Int {
            edges.filter { $0.citedId == paperId && $0.citingId != paperId }.count
        }
    }

    /// 自著論文への入エッジ（被引用）+ 自著間の引用エッジでネットワークを構築する
    public func ownCitationNetwork() throws -> OwnNetwork {
        try db.read { dbc in
            let ownPapers = try Paper
                .filter(Column("is_own") == true && Column("is_stub") == false)
                .fetchAll(dbc)
            let ownIds = Set(ownPapers.map(\.id))
            guard !ownIds.isEmpty else {
                return OwnNetwork(ownIds: [], nodes: [], edges: [])
            }
            let placeholders = ownIds.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(Array(ownIds))
            // 統計は真値、描画はノード上限つき（→ docs/08 6節）
            let totalIncoming = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM citations
                WHERE cited_id IN (\(placeholders)) AND citing_id NOT IN (\(placeholders))
                """, arguments: args + args) ?? 0
            let totalCiters = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(DISTINCT citing_id) FROM citations
                WHERE cited_id IN (\(placeholders)) AND citing_id NOT IN (\(placeholders))
                """, arguments: args + args) ?? 0
            let edges = try Citation.fetchAll(dbc, sql: """
                SELECT * FROM citations WHERE cited_id IN (\(placeholders)) LIMIT 400
                """, arguments: args)

            var nodeIds = ownIds
            for edge in edges { nodeIds.insert(edge.citingId) }
            let nodes = try Paper.filter(nodeIds.contains(Column("id"))).fetchAll(dbc)
            return OwnNetwork(
                ownIds: ownIds, nodes: nodes, edges: edges,
                totalIncomingCount: totalIncoming, totalUniqueCiterCount: totalCiters)
        }
    }
}

extension CitationStore.EgoNetwork {
    /// 関係フィルタの適用（→ docs/08 6節）。
    /// references = 中心から引用方向（citing → cited）に到達可能な部分グラフ、
    /// citations = 逆方向に到達可能な部分グラフ。2ホップにも一貫して適用される。
    public func filtered(_ relation: CitationStore.CitationRelation) -> CitationStore.EgoNetwork {
        guard relation != .all else { return self }

        // BFSで到達可能なノード集合を求める
        var adjacency: [String: [String]] = [:]
        for edge in edges {
            switch relation {
            case .references:
                adjacency[edge.citingId, default: []].append(edge.citedId)
            case .citations:
                adjacency[edge.citedId, default: []].append(edge.citingId)
            case .all:
                break
            }
        }
        var reachable: Set<String> = [center]
        var frontier = [center]
        while let node = frontier.popLast() {
            for next in adjacency[node] ?? [] where !reachable.contains(next) {
                reachable.insert(next)
                frontier.append(next)
            }
        }

        let keptEdges = edges.filter { edge in
            guard reachable.contains(edge.citingId), reachable.contains(edge.citedId) else { return false }
            // 到達方向と一致するエッジのみ（references: 上流側から、citations: 下流側から）
            switch relation {
            case .references: return adjacency[edge.citingId]?.contains(edge.citedId) ?? false
            case .citations: return adjacency[edge.citedId]?.contains(edge.citingId) ?? false
            case .all: return true
            }
        }
        return CitationStore.EgoNetwork(
            center: center,
            nodes: nodes.filter { reachable.contains($0.id) },
            edges: keptEdges
        )
    }

    /// 中心との直接の関係（ノード色分け用 → docs/08 5節）
    public enum NodeRelation: Sendable {
        case center
        /// 中心が引用（参考文献）
        case reference
        /// 中心を引用（被引用）
        case citer
        /// 相互引用
        case both
        /// 2ホップ先（間接）
        case indirect
    }

    public func nodeRelation(of paperId: String) -> NodeRelation {
        if paperId == center { return .center }
        let isReference = edges.contains { $0.citingId == center && $0.citedId == paperId }
        let isCiter = edges.contains { $0.citedId == center && $0.citingId == paperId }
        switch (isReference, isCiter) {
        case (true, true): return .both
        case (true, false): return .reference
        case (false, true): return .citer
        case (false, false): return .indirect
        }
    }
}
