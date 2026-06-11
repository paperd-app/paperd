import Foundation
import GRDB

/// チャンクのDB投入とFTS5 / ベクトルインデックスの同期。
/// chunks.id = vec_chunks.rowid = fts_chunks.rowid を維持する（→ docs/06 3節）。
public struct SearchIndex: Sendable {
    public let db: AppDatabase
    let vectorStore = VectorStore()

    public init(db: AppDatabase) {
        self.db = db
    }

    /// 論文のチャンク一式を差し替えて投入する。embeddingsはpiecesと同数（nil可: FTS5のみ投入）
    @discardableResult
    public func indexPaper(
        paperId: String,
        pieces: [Chunker.Piece],
        embeddings: [[Float]]? = nil
    ) throws -> [Int64] {
        if let embeddings {
            precondition(embeddings.count == pieces.count, "embeddings数がチャンク数と一致しません")
        }
        return try db.write { dbc in
            try deleteChunks(dbc, paperId: paperId)
            var chunkIds: [Int64] = []
            for (i, piece) in pieces.enumerated() {
                var chunk = Chunk(
                    paperId: paperId,
                    chunkIndex: i,
                    sectionPath: piece.sectionPath,
                    text: piece.text,
                    tokenCount: piece.tokenCount
                )
                try chunk.insert(dbc)
                let chunkId = chunk.id!
                chunkIds.append(chunkId)
                try dbc.execute(
                    sql: "INSERT INTO fts_chunks(rowid, text) VALUES (?, ?)",
                    arguments: [chunkId, piece.text]
                )
                if let embeddings {
                    try vectorStore.insert(dbc, chunkId: chunkId, embedding: embeddings[i])
                }
            }
            return chunkIds
        }
    }

    /// embeddingのみ後から投入する（FTS先行投入 → embed完了時）
    public func attachEmbeddings(chunkIds: [Int64], embeddings: [[Float]]) throws {
        precondition(chunkIds.count == embeddings.count)
        try db.write { dbc in
            for (chunkId, embedding) in zip(chunkIds, embeddings) {
                try vectorStore.insert(dbc, chunkId: chunkId, embedding: embedding)
            }
        }
    }

    public func deleteChunks(paperId: String) throws {
        try db.write { try deleteChunks($0, paperId: paperId) }
    }

    func deleteChunks(_ db: Database, paperId: String) throws {
        let chunkIds = try Int64.fetchAll(db, sql: "SELECT id FROM chunks WHERE paper_id = ?", arguments: [paperId])
        for id in chunkIds {
            try db.execute(sql: "DELETE FROM fts_chunks WHERE rowid = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vec_chunks WHERE rowid = ?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM chunks WHERE paper_id = ?", arguments: [paperId])
    }

    /// embedding_metaの記録（再embedding判定用 → docs/06 6節）
    public func recordEmbeddingMeta(modelName: String, dimensions: Int) throws {
        try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM embedding_meta")
            try EmbeddingMeta(modelName: modelName, dimensions: dimensions).insert(dbc)
        }
    }

    /// 現在のモデル設定と embedding_meta の不一致を検出する（true = 再embeddingが必要）
    public func needsReembedding(modelName: String, dimensions: Int) throws -> Bool {
        try db.read { dbc in
            guard let meta = try EmbeddingMeta.fetchOne(dbc) else { return false }
            return meta.modelName != modelName || meta.dimensions != dimensions
        }
    }
}
