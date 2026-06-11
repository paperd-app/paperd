import Foundation
import Testing
import PaperdCore

@Suite("JobQueue")
struct JobQueueTests {
    @Test("enqueue→claim→succeed")
    func happyPath() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .mcp)
        #expect(job.jobStatus == .queued)
        #expect(queue.payload(of: job)["arxiv_id"] == "1706.03762")

        let next = try #require(try queue.nextRunnable())
        #expect(next.id == job.id)
        #expect(try queue.claim(job.id))
        #expect(!(try queue.claim(job.id)), "二重claimは失敗")
        try queue.succeed(job.id)
        #expect(try queue.job(id: job.id)?.jobStatus == .succeeded)
    }

    @Test("一時的エラーはバックオフ付きでqueuedへ戻る")
    func transientFailureBackoff() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
        _ = try queue.claim(job.id)
        let status = try queue.fail(job.id, error: "HTTP 503")
        #expect(status == .queued)
        let updated = try #require(try queue.job(id: job.id))
        #expect(updated.retryCount == 1)

        // バックオフ中（30秒）は実行可能にならない
        #expect(try queue.nextRunnable(now: Date()) == nil)
        // 30秒後には実行可能
        let later = Date().addingTimeInterval(31)
        #expect(try queue.nextRunnable(now: later) != nil)
    }

    @Test("リトライ上限（3回）でfailed")
    func retryLimit() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
        #expect(try queue.fail(job.id, error: "e1") == .queued)
        #expect(try queue.fail(job.id, error: "e2") == .queued)
        #expect(try queue.fail(job.id, error: "e3") == .failed)
        let final = try #require(try queue.job(id: job.id))
        #expect(final.lastError == "e3")
    }

    @Test("恒久的エラーは即failed")
    func permanentFailure() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
        #expect(try queue.fail(job.id, error: "PDF壊れ", permanent: true) == .failed)
        #expect(try queue.job(id: job.id)?.retryCount == 0, "permanentはretry_countを増やさない")
    }

    @Test("手動再試行でretry_countリセット")
    func manualRetry() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
        _ = try queue.fail(job.id, error: "x", permanent: true)
        try queue.retry(job.id)
        let retried = try #require(try queue.job(id: job.id))
        #expect(retried.jobStatus == .queued)
        #expect(retried.retryCount == 0)
        #expect(retried.lastError == nil)
    }

    @Test("ステージ記録")
    func stageTracking() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .urlScheme)
        try queue.updateStage(job.id, stage: .convert)
        #expect(try queue.job(id: job.id)?.jobStage == .convert)
        #expect(JobStage.convert.next == .chunk)
        #expect(JobStage.index.next == nil)
    }

    @Test("cancel")
    func cancelJob() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .mcp)
        try queue.cancel(job.id, reason: "duplicate:abc")
        let cancelled = try #require(try queue.job(id: job.id))
        #expect(cancelled.jobStatus == .cancelled)
        #expect(cancelled.lastError == "duplicate:abc")
    }
}

/// 失敗ジョブの無視（→ docs/09 7.1節）
@Suite("失敗ジョブの無視")
struct FailedJobDismissalTests {
    @Test("dismissFailed: failedのみ削除、他のステータスは対象外")
    func dismissSingle() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let failed = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
        _ = try queue.claim(failed.id)
        for _ in 0..<3 { _ = try queue.fail(failed.id, error: "x") }
        let queued = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)

        try queue.dismissFailed(failed.id)
        #expect(try queue.job(id: failed.id) == nil)
        // queuedなジョブはdismiss対象外
        try queue.dismissFailed(queued.id)
        #expect(try queue.job(id: queued.id) != nil)
    }

    @Test("dismissAllFailed: 失敗のみ一括削除、実行中・成功は残る")
    func dismissAll() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        for _ in 0..<2 {
            let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
            _ = try queue.claim(job.id)
            _ = try queue.fail(job.id, error: "x", permanent: true)
        }
        let ok = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)
        _ = try queue.claim(ok.id)
        try queue.succeed(ok.id)

        try queue.dismissAllFailed()
        #expect(try queue.jobs(status: .failed).isEmpty)
        #expect(try queue.job(id: ok.id)?.jobStatus == .succeeded)
    }
}

/// 重複投入の排除（→ docs/04 7節。重複reindexによる負荷事故の回帰テスト）
@Suite("ジョブの重複投入排除")
struct EnqueueDeduplicationTests {
    @Test("同一論文へのreindexはqueued/running中は1本のみ")
    func reindexDeduplicated() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])

        // 連続バッチ適用を模して5回投入 → 1本だけ
        for _ in 0..<5 {
            _ = try queue.enqueueIfAbsent(kind: .reindex, paperId: paper.id, origin: .mcp)
        }
        #expect(try queue.jobs(status: .queued).count == 1)

        // running中も投入されない
        let job = try #require(try queue.jobs(status: .queued).first)
        _ = try queue.claim(job.id)
        #expect(try queue.enqueueIfAbsent(kind: .reindex, paperId: paper.id, origin: .mcp) == nil)

        // 完了後は再投入できる
        try queue.succeed(job.id)
        #expect(try queue.enqueueIfAbsent(kind: .reindex, paperId: paper.id, origin: .mcp) != nil)
    }

    @Test("別論文・別kindは重複排除の対象外")
    func differentTargetsNotDeduplicated() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let p1 = samplePaper()
        let p2 = samplePaper(title: "Other", doi: "10.1000/other", arxivId: nil)
        try store.savePaper(p1, authors: [])
        try store.savePaper(p2, authors: [])

        _ = try queue.enqueueIfAbsent(kind: .reindex, paperId: p1.id, origin: .app)
        _ = try queue.enqueueIfAbsent(kind: .reindex, paperId: p2.id, origin: .app)
        _ = try queue.enqueueIfAbsent(kind: .refetchCitations, paperId: p1.id, origin: .app)
        #expect(try queue.jobs(status: .queued).count == 3)
    }
}
