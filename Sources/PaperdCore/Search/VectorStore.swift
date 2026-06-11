import Foundation
import GRDB

/// ベクトルインデックス（→ docs/06 3節）。
/// 設計書ではsqlite-vec仮想テーブルだが、システムSQLiteは拡張ロード不可のため、
/// v1は vec_chunks 通常テーブル（rowid = chunks.id, embedding = float32リトルエンディアンBLOB）
/// + Swift側ブルートフォースKNNで同じ性能特性（数十万チャンク全走査 < 1秒）を実現する。
/// sqlite-vec導入時はこの型の実装のみ差し替える。
public struct VectorStore: Sendable {
    public init() {}

    // MARK: - BLOBエンコード

    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    // MARK: - 書き込み

    public func insert(_ db: Database, chunkId: Int64, embedding: [Float]) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO vec_chunks (rowid, embedding) VALUES (?, ?)",
            arguments: [chunkId, Self.encode(embedding)]
        )
    }

    public func deleteAll(_ db: Database, paperId: String) throws {
        try db.execute(
            sql: "DELETE FROM vec_chunks WHERE rowid IN (SELECT id FROM chunks WHERE paper_id = ?)",
            arguments: [paperId]
        )
    }

    // MARK: - KNN検索

    public struct Match: Equatable, Sendable {
        public var chunkId: Int64
        public var score: Double  // コサイン類似度
    }

    /// ブルートフォースKNN。allowedChunkIdsを渡すと候補をその集合に限定する（コレクション絞り込み用）
    public func topK(
        _ db: Database,
        query: [Float],
        k: Int,
        allowedChunkIds: Set<Int64>? = nil
    ) throws -> [Match] {
        let queryNorm = sqrt(query.reduce(0) { $0 + Double($1) * Double($1) })
        guard queryNorm > 0 else { return [] }

        var matches: [Match] = []
        let rows = try Row.fetchCursor(db, sql: "SELECT rowid, embedding FROM vec_chunks")
        while let row = try rows.next() {
            let chunkId: Int64 = row["rowid"]
            if let allowed = allowedChunkIds, !allowed.contains(chunkId) { continue }
            let embedding = Self.decode(row["embedding"])
            guard embedding.count == query.count else { continue }
            var dot = 0.0
            var norm = 0.0
            for i in 0..<embedding.count {
                dot += Double(query[i]) * Double(embedding[i])
                norm += Double(embedding[i]) * Double(embedding[i])
            }
            let denominator = queryNorm * sqrt(norm)
            guard denominator > 0 else { continue }
            matches.append(Match(chunkId: chunkId, score: dot / denominator))
        }
        matches.sort { $0.score > $1.score }
        return Array(matches.prefix(k))
    }
}
