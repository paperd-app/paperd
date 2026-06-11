import Foundation
import GRDB

/// クエリembeddingの供給者。アプリ/MCPはWorkerClientを、テストはフェイクを注入する（→ docs/06 5節）
public protocol QueryEmbedder: Sendable {
    func embedQuery(_ text: String) async throws -> [Float]
}

public enum SearchMode: String, Sendable {
    case hybrid
    case keywordOnly = "keyword"
}

public enum MatchType: String, Codable, Sendable {
    case semantic
    case keyword
    case hybrid
}

/// 検索結果（チャンク単位、UI/MCP共通スキーマ → docs/06 4節）
public struct SearchResult: Equatable, Sendable {
    /// ヒットしたチャンクのID（一意。UIの行識別・将来のページジャンプ用）
    public var chunkId: Int64
    public var paperId: String
    public var title: String
    public var year: Int?
    public var sectionPath: String?
    public var chunkText: String
    /// RRF統合スコア（順位ベース。相対比較のみに使う）
    public var score: Double
    public var matchType: MatchType
    /// semantic側のコサイン類似度（0〜1。semantic/hybridヒット時のみ → docs/06 4節）
    public var semanticScore: Double?
    /// FTS5順位（1始まり。keyword/hybridヒット時のみ）
    public var keywordRank: Int?
}

/// FTS5 + semantic のRRF統合検索（→ docs/06 4節）
public struct HybridSearch: Sendable {
    public let db: AppDatabase
    let vectorStore = VectorStore()

    public var semanticTopK: Int
    public var ftsTopK: Int
    public var rrfK: Double
    /// 同一論文のチャンクが上位を占有しないための論文ごと最大表示チャンク数
    public var maxChunksPerPaper: Int

    public init(db: AppDatabase, semanticTopK: Int = 50, ftsTopK: Int = 50, rrfK: Double = 60, maxChunksPerPaper: Int = 3) {
        self.db = db
        self.semanticTopK = semanticTopK
        self.ftsTopK = ftsTopK
        self.rrfK = rrfK
        self.maxChunksPerPaper = maxChunksPerPaper
    }

    /// - Parameter embedder: nilまたはembedding生成失敗時はFTS5のみで応答（ワーカー未起動時の即時応答 → docs/07 4節）
    /// - Returns: (結果, semanticが使えたか)
    public func search(
        query: String,
        topK: Int = 20,
        embedder: QueryEmbedder?
    ) async throws -> (results: [SearchResult], semanticUsed: Bool) {
        var queryEmbedding: [Float]?
        if let embedder {
            queryEmbedding = try? await embedder.embedQuery(query)
        }
        let embedding = queryEmbedding
        let results = try db.read { dbc -> [SearchResult] in
            let allowedChunkIds: Set<Int64>? = nil

            let ftsRanked = try Self.ftsSearch(dbc, query: query, topK: ftsTopK, allowedChunkIds: allowedChunkIds)
            var semanticRanked: [Int64] = []
            var semanticScores: [Int64: Double] = [:]
            if let embedding {
                let matches = try vectorStore
                    .topK(dbc, query: embedding, k: semanticTopK, allowedChunkIds: allowedChunkIds)
                semanticRanked = matches.map(\.chunkId)
                for match in matches { semanticScores[match.chunkId] = match.score }
            }
            let ftsRanks = Dictionary(uniqueKeysWithValues: ftsRanked.enumerated().map { ($0.element, $0.offset + 1) })

            let fused = Self.rrf(rankings: [semanticRanked, ftsRanked], k: rrfK)
            let semanticSet = Set(semanticRanked)
            let ftsSet = Set(ftsRanked)

            var perPaper: [String: Int] = [:]
            var results: [SearchResult] = []
            for (chunkId, score) in fused {
                guard let row = try Row.fetchOne(dbc, sql: """
                    SELECT chunks.paper_id, chunks.section_path, chunks.text, papers.title, papers.year
                    FROM chunks JOIN papers ON papers.id = chunks.paper_id
                    WHERE chunks.id = ?
                    """, arguments: [chunkId])
                else { continue }
                let paperId: String = row["paper_id"]
                let count = perPaper[paperId, default: 0]
                guard count < maxChunksPerPaper else { continue }
                perPaper[paperId] = count + 1

                let matchType: MatchType
                switch (semanticSet.contains(chunkId), ftsSet.contains(chunkId)) {
                case (true, true): matchType = .hybrid
                case (true, false): matchType = .semantic
                default: matchType = .keyword
                }
                results.append(SearchResult(
                    chunkId: chunkId,
                    paperId: paperId,
                    title: row["title"],
                    year: row["year"],
                    sectionPath: row["section_path"],
                    chunkText: row["text"],
                    score: score,
                    matchType: matchType,
                    semanticScore: semanticScores[chunkId],
                    keywordRank: ftsRanks[chunkId]
                ))
                if results.count >= topK { break }
            }
            return results
        }
        return (results, embedding != nil)
    }

    // MARK: - 構成要素

    /// FTS5検索（rowidをbm25順で返す）。クエリはFTS構文エラー防止のためトークンごとにクオートする
    static func ftsSearch(_ db: Database, query: String, topK: Int, allowedChunkIds: Set<Int64>?) throws -> [Int64] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        let rowids = try Int64.fetchAll(db, sql: """
            SELECT rowid FROM fts_chunks WHERE fts_chunks MATCH ?
            ORDER BY bm25(fts_chunks) LIMIT ?
            """, arguments: [sanitized, allowedChunkIds == nil ? topK : topK * 10])
        if let allowed = allowedChunkIds {
            return Array(rowids.filter(allowed.contains).prefix(topK))
        }
        return rowids
    }

    /// 各トークンをダブルクオートで包む（演算子の注入を防ぐ）。複数トークンは暗黙AND
    public static func sanitizeFTSQuery(_ query: String) -> String {
        query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " ")
    }

    /// RRF統合: score(c) = Σ 1 / (k + rank_i(c))（rankは1始まり → docs/06 4節）
    public static func rrf(rankings: [[Int64]], k: Double) -> [(id: Int64, score: Double)] {
        var scores: [Int64: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        return scores.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key  // 決定的順序
        }.map { ($0.key, $0.value) }
    }

}
