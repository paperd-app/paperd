import Foundation
import GRDB

/// jobsテーブルのキュー操作（→ docs/02, docs/04 7節）。
/// すべての取り込み経路（アプリUI / MCP / URLスキーム）がこのキューを通る。
public struct JobQueue: Sendable {
    public let db: AppDatabase
    /// 指数バックオフ: 30秒 → 2分 → 10分、最大3回（→ docs/04 7節）
    public static let backoffSeconds: [TimeInterval] = [30, 120, 600]
    public static let maxRetries = 3

    public init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - 投入

    /// - Parameter completedStage: 完了済みステージを指定すると、その次のステージから再開する
    ///   （PDF後付け時の「convert以降の再開」等 → docs/04 6節）
    @discardableResult
    public func enqueue(
        kind: JobKind,
        paperId: String? = nil,
        payload: [String: String],
        origin: JobOrigin,
        completedStage: JobStage? = nil
    ) throws -> Job {
        let payloadJSON = String(
            data: try JSONEncoder().encode(payload.sorted { $0.key < $1.key }.reduce(into: [String: String]()) { $0[$1.key] = $1.value }),
            encoding: .utf8
        ) ?? "{}"
        let job = Job(kind: kind, paperId: paperId, payload: payloadJSON, stage: completedStage, origin: origin)
        try db.write { try job.save($0) }
        return job
    }

    /// 同一kind + paper_idのqueued/runningジョブが既にあれば投入しない（→ docs/04 7節）。
    /// reindex / refetch_citations の重複による無駄な再計算・負荷事故を防ぐ
    @discardableResult
    public func enqueueIfAbsent(
        kind: JobKind,
        paperId: String,
        payload: [String: String] = [:],
        origin: JobOrigin
    ) throws -> Job? {
        let existing = try db.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM jobs
                WHERE kind = ? AND paper_id = ? AND status IN ('queued', 'running')
                """, arguments: [kind.rawValue, paperId]) ?? 0
        }
        guard existing == 0 else { return nil }
        return try enqueue(kind: kind, paperId: paperId, payload: payload, origin: origin)
    }

    public func payload(of job: Job) -> [String: String] {
        guard let data = job.payload.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - 取得 / クレーム

    /// 実行可能なジョブ（queued かつ バックオフ待機が明けたもの）を取得する。
    /// **未解決（stage IS NULL）のジョブを優先**する（resolve優先スケジューリング → docs/04 8節）
    public func nextRunnable(now: Date = Date()) throws -> Job? {
        try db.read { dbc in
            let queued = try Job.fetchAll(dbc, sql: """
                SELECT * FROM jobs WHERE status = 'queued'
                ORDER BY (stage IS NULL) DESC, created_at
                """)
            return queued.first { Self.isRunnable($0, now: now) }
        }
    }

    /// 継続のための再キュー（resolve優先スケジューリング → docs/04 8節）。
    /// ステージ・リトライ回数を保持したままqueuedへ戻す
    public func requeueForContinuation(_ jobId: String) throws {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId) else { return }
            job.jobStatus = .queued
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
        }
    }

    static func isRunnable(_ job: Job, now: Date) -> Bool {
        guard job.retryCount > 0 else { return true }
        guard let updated = PaperdDates.date(from: job.updatedAt) else { return true }
        let backoffIndex = min(job.retryCount - 1, backoffSeconds.count - 1)
        return now >= updated.addingTimeInterval(backoffSeconds[backoffIndex])
    }

    /// ジョブをrunningにする。すでにrunningなら他プロセスが処理中（false）
    public func claim(_ jobId: String) throws -> Bool {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId), job.jobStatus == .queued else { return false }
            job.jobStatus = .running
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
            return true
        }
    }

    // MARK: - 状態遷移

    /// ステージ完了の記録（再開時はstageの次から実行 → docs/04 7節）
    public func updateStage(_ jobId: String, stage: JobStage) throws {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId) else { return }
            job.jobStage = stage
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
        }
    }

    public func setPaperId(_ jobId: String, paperId: String) throws {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId) else { return }
            job.paperId = paperId
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
        }
    }

    public func succeed(_ jobId: String) throws {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId) else { return }
            job.jobStatus = .succeeded
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
        }
    }

    public func cancel(_ jobId: String, reason: String? = nil) throws {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId) else { return }
            job.jobStatus = .cancelled
            job.lastError = reason
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
        }
    }

    /// 失敗の記録。一時的エラーはretry_countを増やしてqueuedへ戻し（バックオフ）、
    /// 恒久的エラーまたはリトライ上限到達で failed にする。
    /// - Returns: 最終的なジョブ状態
    @discardableResult
    public func fail(_ jobId: String, error: String, permanent: Bool = false) throws -> JobStatus {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId) else { return .failed }
            job.lastError = error
            if permanent || job.retryCount + 1 >= Self.maxRetries {
                job.jobStatus = .failed
                if !permanent { job.retryCount += 1 }
            } else {
                job.retryCount += 1
                job.jobStatus = .queued
            }
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
            return job.jobStatus
        }
    }

    /// 手動再試行（失敗ステージから再開 → docs/04 7節）
    public func retry(_ jobId: String) throws {
        try db.write { dbc in
            guard var job = try Job.fetchOne(dbc, key: jobId), job.jobStatus == .failed else { return }
            job.jobStatus = .queued
            job.retryCount = 0
            job.lastError = nil
            job.updatedAt = PaperdDates.nowString()
            try job.save(dbc)
        }
    }

    /// 失敗ジョブの無視（行削除 → docs/09 7.1節）。再試行しないと判断した失敗をクリアする
    public func dismissFailed(_ jobId: String) throws {
        try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM jobs WHERE id = ? AND status = 'failed'", arguments: [jobId])
        }
    }

    /// すべての失敗ジョブを無視する
    public func dismissAllFailed() throws {
        try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM jobs WHERE status = 'failed'")
        }
    }

    public func job(id: String) throws -> Job? {
        try db.read { try Job.fetchOne($0, key: id) }
    }

    public func jobs(status: JobStatus? = nil) throws -> [Job] {
        try db.read { dbc in
            if let status {
                return try Job.filter(Column("status") == status.rawValue).order(Column("created_at")).fetchAll(dbc)
            }
            return try Job.order(Column("created_at")).fetchAll(dbc)
        }
    }
}
