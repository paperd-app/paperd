import Foundation

/// アプリ内の単一actorとしてjobsキューを駆動する（→ docs/04 8節, docs/01 5節）。
/// MCP / URLスキーム起源のジョブは定期ポーリング（既定5秒）で検知する。
public actor JobRunner {
    public let queue: JobQueue
    public let pipeline: IngestPipeline
    /// refetch_citationsジョブの実体（nilなら引用取得ジョブは失敗として処理）
    public let citationFetcher: CitationFetcher?
    public var pollInterval: TimeInterval

    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    public init(
        queue: JobQueue,
        pipeline: IngestPipeline,
        citationFetcher: CitationFetcher? = nil,
        pollInterval: TimeInterval = 5.0
    ) {
        self.queue = queue
        self.pipeline = pipeline
        self.citationFetcher = citationFetcher
        self.pollInterval = pollInterval
    }

    /// ジョブの並行実行数（→ docs/04 8節）。
    /// convertはワーカー側のジョブキューで構造的に直列化されるため、
    /// ここでの並行は変換中にネットワーク系・embedの待ち時間を隠蔽する
    public let maxConcurrentJobs = 3

    /// 1回のポーリングサイクル: 実行可能なジョブを**バッチ並行**で処理する（→ docs/04 8節）。
    /// 取り出し順は未解決（stage IS NULL）優先（resolve優先スケジューリング）。
    @discardableResult
    public func tick(now: Date = Date()) async -> Int {
        var processed = 0
        while true {
            let batch = claimBatch(now: now, limit: maxConcurrentJobs)
            guard !batch.isEmpty else { break }
            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    group.addTask { await self.run(job: job) }
                }
            }
            processed += batch.count
        }
        return processed
    }

    private func claimBatch(now: Date, limit: Int) -> [Job] {
        var batch: [Job] = []
        while batch.count < limit,
              let job = try? queue.nextRunnable(now: now),
              (try? queue.claim(job.id)) == true {
            if let current = try? queue.job(id: job.id) { batch.append(current) }
        }
        return batch
    }

    /// ジョブ種別ごとのディスパッチ
    func run(job: Job) async {
        switch JobKind(rawValue: job.kind) {
        case .ingest:
            do {
                let status = try await pipeline.run(job: job)
                // 取り込み完了時にreferences/citations取得を自動投入（→ docs/08 2節）
                let paperId = job.paperId ?? (try? queue.job(id: job.id))?.paperId
                if status == .indexed, citationFetcher != nil, let paperId {
                    try? enqueueCitationRefetchIfPossible(paperId: paperId)
                }
            } catch {
                // pipeline.run内で状態遷移済み（failed / queuedバックオフ / cancelled）
            }

        case .reindex:
            _ = try? await pipeline.runReindex(job: job)

        case .reconvert:
            _ = try? await pipeline.runReconvert(job: job)

        case .refetchCitations:
            guard let fetcher = citationFetcher, let paperId = job.paperId else {
                _ = try? queue.fail(job.id, error: "引用取得を実行できません（fetcher未設定またはpaper_idなし）", permanent: true)
                return
            }
            do {
                try await fetcher.refetch(paperId: paperId)
                try? queue.succeed(job.id)
            } catch let error as IngestError {
                _ = try? queue.fail(job.id, error: error.description, permanent: true)
            } catch {
                _ = try? queue.fail(job.id, error: String(describing: error))
            }

        case nil:
            _ = try? queue.fail(job.id, error: "未知のジョブ種別: \(job.kind)", permanent: true)
        }
    }

    /// 外部ID（S2/DOI/arXiv/OpenAlex）を持つ論文のみrefetch_citationsを投入する
    func enqueueCitationRefetchIfPossible(paperId: String) throws {
        guard let paper = try pipeline.store.paper(id: paperId),
              CitationFetcher.canFetch(for: paper)
        else { return }
        try queue.enqueueIfAbsent(kind: .refetchCitations, paperId: paperId, origin: .app)
    }

    /// ポーリングループを開始する（アプリ起動時）
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        pollTask = Task { [weak self] in
            while let self, await self.isRunning {
                await self.tick()
                let interval = await self.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
    }
}
