import SwiftUI
import AppKit
import PaperdCore

// paperd.app（→ docs/09）。
// 3ペイン・詳細タブ（情報/PDF/ノート/引用グラフ）・取り込みUI・ジョブ進捗・設定を備える。
// 初回セットアップウィザードの磨き込みはv1リリース前の残課題（設定画面から手動セットアップ可能）。

/// swift run（非バンドル実行）ではアプリのアクティベーションが不完全で、
/// ウィンドウは表示されてもキーボードフォーカスが取れず文字入力できない。
/// 明示的にactivation policyを設定してアクティブ化することで回避する
/// （バンドル実行 scripts/make-app.sh では本来不要だが無害）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// アプリ終了時にワーカーを停止する（残留によるメモリ占有の防止 → docs/01 3.2節）。
    /// MCPは必要時にオンデマンドで再起動できるため停止してよい
    func applicationWillTerminate(_ notification: Notification) {
        if let lock = WorkerLock.read(), lock.isProcessAlive {
            kill(lock.pid, SIGTERM)
        }
        WorkerLock.remove()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PaperdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("paperd") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            // 取り込みショートカット（常時有効 → docs/09 7節）
            CommandGroup(after: .newItem) {
                Button("論文を取り込む（arXiv / DOI / URL）…") { model.showImportSheet = true }
                    .keyboardShortcut("n")
                Button("PDFファイル / フォルダから取り込む…") { model.pickAndImportFiles() }
                    .keyboardShortcut("o")
            }
            // ⌘F: 検索フィールドへフォーカス（searchableは自動でFindにバインドされない → docs/09 6節）
            CommandGroup(after: .textEditing) {
                Button("ライブラリを検索") { model.searchPresented = true }
                    .keyboardShortcut("f")
            }
            // ライブラリメニュー（→ docs/03 5節）
            CommandMenu("ライブラリ") {
                Button("インデックスを再構築…") { model.showRebuildConfirm = true }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var papers: [Paper] = []
    @Published var selectedPaperId: String?
    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchResult]?
    @Published var semanticUsed = false
    @Published var errorMessage: String?
    @Published var activeJobs: [Job] = []
    @Published var failedJobs: [Job] = []
    @Published var showImportSheet = false

    enum SmartList: String, CaseIterable, Identifiable {
        case all = "すべて"
        case favorites = "お気に入り"
        case ownPapers = "自著論文"
        case processing = "処理中"
        case pdfMissing = "PDF未取得"
        case unresolved = "書誌未解決"
        case failed = "失敗"
        var id: String { rawValue }

        /// ステータス絞り込みリストの対象status（nil = 対象外。一括削除のスコープ → docs/09 3節）
        var statusFilter: [PaperStatus]? {
            switch self {
            case .pdfMissing: return [.metadataOnly]
            case .unresolved: return [.pdfOnly]
            case .failed: return [.failed]
            default: return nil
            }
        }
    }

    /// サイドバー選択（→ docs/09 2節）
    enum SidebarSelection: Hashable {
        case smart(SmartList)
    }

    /// 論文リストのソート（→ docs/09 3節）
    enum PaperSort: String, CaseIterable {
        case addedDesc = "追加日"
        case year = "年"
        case title = "タイトル"
        case firstAuthor = "第一著者"
    }

    @Published var sidebarSelection: SidebarSelection = .smart(.all) {
        // リスト切替＝コンテキスト切替として選択と検索を解除（→ docs/09 3節・6節。
        // 自著論文リストの着地で被引用ネットワークを必ず表示するためでもある）
        didSet {
            if oldValue != sidebarSelection {
                selectedPaperId = nil
                searchResults = nil
                searchQuery = ""
            }
        }
    }
    @Published var sortOrder: PaperSort = .addedDesc
    /// 検索モード（→ docs/09 6節）。keywordOnlyはワーカー不要で即応答
    @Published var searchMode: SearchMode = .hybrid
    /// 外部起源（URLスキーム）の取り込みは確認を経る（→ docs/11 6節）
    @Published var pendingExternalImport: String?
    var firstAuthorByPaper: [String: String] = [:]

    /// 詳細ペインのタブ（→ docs/09 4節）。検索ヒットからのタブ切替のためモデルで保持
    enum DetailTab: String, CaseIterable {
        case info = "情報"
        case pdf = "PDF"
        case markdown = "Markdown"
        case notes = "ノート"
        case graph = "引用グラフ"
    }

    @Published var detailTab: DetailTab = .info
    /// Markdownタブで次にスクロールすべきsection_path（検索ヒットクリック → docs/09 6節）
    @Published var markdownScrollTarget: String?

    private(set) var store: LibraryStore?
    private(set) var runner: JobRunner?
    private(set) var queue: JobQueue?

    /// ワーカーの状態（ステータスバー・設定画面の表示用 → docs/09 9節）
    enum WorkerStatus: Equatable {
        case notSetup
        case stopped
        case running(version: String)
    }
    @Published var workerStatus: WorkerStatus = .stopped

    /// 設定画面のタブ（ステータスバーからの直接遷移用 → docs/09 7.1節）
    enum SettingsTab: Hashable {
        case general, integration, worker
    }
    @Published var settingsTab: SettingsTab = .general
    /// 検索フィールドのフォーカス（⌘F → docs/09 6節）
    @Published var searchPresented = false

    init() {
        open()
    }

    func open() {
        do {
            let store = try LibraryStore.create(at: LibraryLayout.defaultRoot)
            self.store = store
            startJobRunner(store: store)
            reload()
            autoConfigureWorkerDirIfNeeded()
            autoStartWorkerIfEnabled()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - ワーカーのライフサイクル（→ docs/01 3.2節, docs/09 9節）

    var workerDirectory: URL? {
        let path = UserDefaults.standard.string(forKey: "workerDir") ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// セットアップ済みか（worker/ディレクトリ指定 + uv環境構築済み）
    var workerIsSetUp: Bool {
        guard let dir = workerDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(".venv").path)
    }

    /// workerパスの自動検出（→ docs/09 9節）。
    /// 未設定なら、アプリバンドルに隣接する worker/（開発ビルド = リポジトリ内 .build/../worker）を探して既定値にする。
    /// 外部起動ワーカーのlock再利用で「設定済みに見える」状態が、ワーカー停止時に突然
    /// セットアップ画面へ化ける紛らわしさへの対策
    func autoConfigureWorkerDirIfNeeded() {
        let defaults = UserDefaults.standard
        guard (defaults.string(forKey: "workerDir") ?? "").isEmpty else { return }
        let fm = FileManager.default
        // ① 開発ビルド: リポジトリ内のworker/（環境構築済みのもの）
        let devCandidate = Bundle.main.bundleURL
            .deletingLastPathComponent()  // .build/
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("worker")
        if fm.fileExists(atPath: devCandidate.appendingPathComponent("pyproject.toml").path),
           fm.fileExists(atPath: devCandidate.appendingPathComponent(".venv").path) {
            defaults.set(devCandidate.path, forKey: "workerDir")
            return
        }
        // ② 配布ビルド: 同梱ワーカーをApplication Supportへ展開（→ docs/01 3.3節）
        if let resources = Bundle.main.resourceURL {
            let deployment = WorkerDeployment(bundledDir: resources.appendingPathComponent("worker"))
            if let deployed = (try? deployment.deployIfNeeded()) ?? nil {
                defaults.set(deployed.path, forKey: "workerDir")
            }
        }
    }

    /// アプリ起動時の自動起動（既定ON。設定「アプリ起動時にワーカーを自動起動」）
    func autoStartWorkerIfEnabled() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoStartWorker") == nil
            ? true
            : defaults.bool(forKey: "autoStartWorker")
        guard enabled, workerIsSetUp else { return }
        startWorker()
    }

    func startWorker() {
        guard let dir = workerDirectory else { return }
        Task {
            let manager = WorkerProcessManager(workerDirectory: dir)
            _ = try? await manager.startOrReuseVerified()
            await refreshWorkerStatus()
        }
    }

    func stopWorker() {
        Task {
            await WorkerLock.terminateRunningWorker()
            await refreshWorkerStatus()
        }
    }

    /// 定期ポーリングで状態を更新（ステータスバーのインジケータ用）
    @MainActor
    func refreshWorkerStatus() async {
        if let client = WorkerLock.reusableClient(), let health = try? await client.health() {
            workerStatus = .running(version: health.version)
        } else if !workerIsSetUp {
            workerStatus = .notSetup
        } else {
            workerStatus = .stopped
        }
    }

    /// MCP / URLスキーム起源のジョブをポーリングで処理する（→ docs/04 8節）。
    /// ワーカー未セットアップ時はconvert/embedが失敗し、リトライ後にfailedとして残る。
    private func startJobRunner(store: LibraryStore) {
        let queue = JobQueue(db: store.db)
        self.queue = queue
        let defaults = UserDefaults.standard
        let mailto = defaults.string(forKey: "mailto")
        let s2Key = defaults.string(forKey: "s2APIKey")
        let resolver = MetadataResolver.live(mailto: mailto, s2APIKey: s2Key)
        let executors = LiveStageExecutors(resolver: resolver, unpaywallEmail: mailto) {
            if let client = WorkerLock.reusableClient() {
                // 旧コードのワーカーが残っていると新オプションが黙って無視されるため、バージョンを照合（→ docs/01 3.2節）
                if let health = try? await client.health(), health.version == WorkerClient.expectedWorkerVersion {
                    return client
                }
                throw WorkerClient.WorkerAPIError(
                    code: "MODEL_NOT_READY",
                    message: "稼働中のワーカーが古いバージョンです。設定画面から起動し直してください。",
                    statusCode: 0
                )
            }
            throw WorkerClient.WorkerAPIError(
                code: "MODEL_NOT_READY",
                message: "Pythonワーカーが未起動です。設定画面からワーカーをセットアップ・起動してください。",
                statusCode: 0
            )
        }
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        let fetcher = CitationFetcher(
            db: store.db,
            s2: SemanticScholarClient(http: URLSessionHTTPClient(), apiKey: s2Key),
            openAlex: OpenAlexClient(http: URLSessionHTTPClient(), mailto: mailto)
        )
        let runner = JobRunner(queue: queue, pipeline: pipeline, citationFetcher: fetcher)
        self.runner = runner
        Task { await runner.start() }
    }

    func reload() {
        guard let store else { return }
        do {
            papers = try store.allPapers()
            firstAuthorByPaper = try store.firstAuthors()
        } catch {
            errorMessage = String(describing: error)
        }
        reloadJobs()
    }

    func reloadJobs() {
        guard let queue else { return }
        let running = (try? queue.jobs(status: .running)) ?? []
        let queued = (try? queue.jobs(status: .queued)) ?? []
        activeJobs = running + queued
        failedJobs = (try? queue.jobs(status: .failed)) ?? []
    }

    var visiblePapers: [Paper] {
        if let searchResults {
            var seen = Set<String>()
            var ordered: [Paper] = []
            for r in searchResults where !seen.contains(r.paperId) {
                seen.insert(r.paperId)
                if let p = papers.first(where: { $0.id == r.paperId }) { ordered.append(p) }
            }
            return ordered
        }
        let filtered: [Paper]
        switch sidebarSelection {
        case .smart(.all):
            filtered = papers
        case .smart(.processing):
            filtered = papers.filter { $0.paperStatus == .converting }
        case .smart(.favorites):
            filtered = papers.filter(\.isFavorite)
        case .smart(.ownPapers):
            filtered = papers.filter(\.isOwn)
        case .smart(let list):
            if let statuses = list.statusFilter {
                filtered = papers.filter { statuses.contains($0.paperStatus) }
            } else {
                filtered = papers
            }
        }
        return sorted(filtered)
    }

    /// ソート（→ docs/09 3節。既定: 追加日降順）
    func sorted(_ papers: [Paper]) -> [Paper] {
        switch sortOrder {
        case .addedDesc:
            return papers.sorted { $0.addedAt > $1.addedAt }
        case .year:
            return papers.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .title:
            return papers.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .firstAuthor:
            return papers.sorted {
                (firstAuthorByPaper[$0.id] ?? "～").localizedCaseInsensitiveCompare(firstAuthorByPaper[$1.id] ?? "～") == .orderedAscending
            }
        }
    }

    var listTitle: String {
        if searchResults != nil { return "検索結果" }
        switch sidebarSelection {
        case .smart(let list): return list.rawValue
        }
    }

    // MARK: - 検索（→ docs/09 6節）

    /// ハイブリッド検索（モード切替 → docs/09 6節）。
    /// コレクション選択中はSQLレベルで絞り込む（→ docs/06 4節）
    func performSearch() {
        guard let store, !searchQuery.isEmpty else {
            searchResults = nil
            return
        }
        let query = searchQuery
        let mode = searchMode
        Task {
            do {
                let embedder: QueryEmbedder? = mode == .hybrid ? WorkerLock.reusableClient() : nil
                let search = HybridSearch(db: store.db)
                let (results, semantic) = try await search.search(query: query, topK: 50, embedder: embedder)
                self.searchResults = results
                self.semanticUsed = semantic
            } catch {
                self.errorMessage = String(describing: error)
            }
        }
    }

    /// 検索結果の論文単位グルーピング（→ docs/09 6節）。出現順 = RRFスコア降順を維持
    var groupedSearchResults: [(paper: Paper, hits: [SearchResult])]? {
        guard let searchResults else { return nil }
        var order: [String] = []
        var byPaper: [String: [SearchResult]] = [:]
        for hit in searchResults {
            if byPaper[hit.paperId] == nil { order.append(hit.paperId) }
            byPaper[hit.paperId, default: []].append(hit)
        }
        return order.compactMap { id in
            guard let paper = papers.first(where: { $0.id == id }) else { return nil }
            return (paper, byPaper[id] ?? [])
        }
    }

    /// 相対強度バー用のトップスコア（RRFは順位ベースのため相対表示 → docs/09 6節）
    var topSearchScore: Double {
        searchResults?.map(\.score).max() ?? 0
    }

    /// 検索ヒットのクリック: 論文を選択し、Markdownタブの該当セクションへ（→ docs/09 6節）
    func openSearchHit(_ hit: SearchResult) {
        selectedPaperId = hit.paperId
        detailTab = .markdown
        markdownScrollTarget = hit.sectionPath
    }

    // MARK: - 取り込み（→ docs/09 7節）

    /// ＋ダイアログからの取り込み。入力種別は自動判別
    func enqueueImport(_ input: String) {
        guard let queue else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PaperIdentifier.parse(trimmed) != nil else {
            errorMessage = "入力を解釈できません: arXiv ID / DOI / URL を指定してください"
            return
        }
        do {
            try queue.enqueue(kind: .ingest, payload: ["input": trimmed], origin: .app)
            reloadJobs()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// 確認待ちの一括取り込み対象（5件以上は確認を経る → docs/09 7節）
    @Published var pendingBulkImport: [URL]?

    /// PDFファイル/フォルダの取り込み（ドロップ・ファイル選択ダイアログ共通 → docs/09 7節）。
    /// フォルダは再帰走査し、件数が多い場合は確認ダイアログを経る
    func importPDFURLs(_ urls: [URL]) {
        let pdfs = PDFImportScanner.pdfs(in: urls)
        guard !pdfs.isEmpty else {
            errorMessage = "PDFファイルが見つかりませんでした"
            return
        }
        if pdfs.count >= 5 {
            pendingBulkImport = pdfs
        } else {
            enqueuePDFs(pdfs)
        }
    }

    /// ファイル選択ダイアログからの取り込み（サイドバーメニュー・⌘O共用 → docs/09 7節）
    func pickAndImportFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.message = "取り込むPDFファイル、またはPDFを含むフォルダを選択してください（フォルダは再帰的に走査されます）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importPDFURLs(panel.urls)
    }

    func confirmBulkImport() {
        if let pdfs = pendingBulkImport { enqueuePDFs(pdfs) }
        pendingBulkImport = nil
    }

    private func enqueuePDFs(_ pdfs: [URL]) {
        guard let queue else { return }
        for url in pdfs {
            do {
                try queue.enqueue(kind: .ingest, payload: ["pdf_path": url.path], origin: .app)
            } catch {
                errorMessage = String(describing: error)
            }
        }
        reloadJobs()
    }

    /// 後方互換: ウィンドウへのドロップ（フォルダ対応はimportPDFURLsに集約）
    func importDroppedPDFs(_ urls: [URL]) {
        importPDFURLs(urls)
    }

    // MARK: - インデックス再構築（→ docs/03 5節）

    @Published var showRebuildConfirm = false
    @Published var rebuildMessage: String?

    /// meta.json群からDBを再構築し、全論文の検索インデックス再計算ジョブを投入する
    func rebuildIndex() {
        guard let store, let queue else { return }
        do {
            try store.rebuildIndexFromFiles()
            var enqueued = 0
            for paper in try store.allPapers() where paper.paperStatus == .indexed || paper.paperStatus == .pdfOnly {
                if try queue.enqueueIfAbsent(kind: .reindex, paperId: paper.id, origin: .app) != nil {
                    enqueued += 1
                }
            }
            reload()
            reloadJobs()
            sidebarSelection = .smart(.processing)
            rebuildMessage = "書誌データベースを再構築しました。検索インデックス（\(enqueued)論文）はバックグラウンドで再計算されます。"
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// 代替PDFの自動探索（→ docs/04 6節）。
    /// 再解決ジョブを投入し、S2/OpenAlex補完（arXiv ID・OAリンク）を更新してfetchを再試行する
    func refetchPDF(_ paper: Paper) {
        guard let queue else { return }
        var payload: [String: String] = [:]
        if let doi = paper.doi { payload["doi"] = doi }
        else if let arxivId = paper.arxivId { payload["arxiv_id"] = arxivId }
        guard !payload.isEmpty else { return }
        do {
            try queue.enqueue(kind: .ingest, paperId: paper.id, payload: payload, origin: .app)
            reloadJobs()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - 添付ファイル（→ docs/09 4節）

    func addSupplement(paperId: String, from url: URL) {
        do {
            try store?.addSupplement(paperId: paperId, from: url)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func removeSupplement(paperId: String, filename: String) {
        do {
            try store?.removeSupplement(paperId: paperId, filename: filename)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// ステータス別リストの一括削除（→ docs/09 3節）。
    /// 現在選択中のリスト（PDF未取得 / 書誌未解決 / 失敗）の全論文をゴミ箱へ
    func deleteCurrentSmartListPapers() {
        guard let store else { return }
        guard case .smart(let list) = sidebarSelection, let statuses = list.statusFilter else { return }
        let targets = papers.filter { statuses.contains($0.paperStatus) }
        for paper in targets {
            do {
                try store.deletePaper(id: paper.id)
                if selectedPaperId == paper.id { selectedPaperId = nil }
            } catch {
                errorMessage = String(describing: error)
            }
        }
        reload()
        reloadJobs()
    }

    /// 失敗ジョブの無視（→ docs/09 7.1節）
    func dismissFailedJob(_ jobId: String) {
        try? queue?.dismissFailed(jobId)
        reloadJobs()
    }

    func dismissAllFailedJobs() {
        try? queue?.dismissAllFailed()
        reloadJobs()
    }

    func retryJob(_ jobId: String) {
        try? queue?.retry(jobId)
        reloadJobs()
    }

    /// PDF未取得の論文へのPDF添付（PDFタブのドロップ → docs/04 6節, docs/09 4節）。
    /// 添付後はconvert以降を再開するジョブを投入する
    func attachPDF(paperId: String, from url: URL) {
        guard let store, let queue else { return }
        do {
            try store.attachPDF(paperId: paperId, from: url)
            try queue.enqueue(kind: .ingest, paperId: paperId, payload: [:], origin: .app, completedStage: .fetch)
            reload()
        } catch let error as IngestError {
            if case .duplicate(let existingId) = error,
               let existing = papers.first(where: { $0.id == existingId }) {
                errorMessage = "このPDFは既に「\(existing.title.prefix(40))」として登録されています"
            } else {
                errorMessage = error.description
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// 論文の削除（ディレクトリごとゴミ箱へ → docs/03 6節）
    func deletePaper(_ paper: Paper) {
        guard let store else { return }
        do {
            try store.deletePaper(id: paper.id)
            if selectedPaperId == paper.id { selectedPaperId = nil }
            searchResults = searchResults?.filter { $0.paperId != paper.id }
            reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - ノート（→ docs/09 4節）

    func note(of paperId: String) -> String {
        store?.note(of: paperId) ?? ""
    }

    func saveNote(paperId: String, content: String) {
        guard let store else { return }
        do {
            try store.saveNote(paperId: paperId, content: content)
            // ノートもチャンク対象（→ docs/06 2節）。索引済み論文は再インデックスして検索へ反映
            if papers.first(where: { $0.id == paperId })?.paperStatus == .indexed {
                try queue?.enqueueIfAbsent(kind: .reindex, paperId: paperId, origin: .app)
                reloadJobs()
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - お気に入り・自著フラグ（→ docs/09 2.2節）

    func toggleFavorite(_ paper: Paper) {
        guard let store else { return }
        do {
            try store.setFavorite(paper.id, !paper.isFavorite)
            reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func toggleOwn(_ paper: Paper) {
        guard let store else { return }
        do {
            try store.setOwn(paper.id, !paper.isOwn)
            reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// ステータス別リストの件数（サイドバーのバッジ表示用 → docs/09 2.1節）
    func count(for list: SmartList) -> Int? {
        guard let statuses = list.statusFilter else { return nil }
        let count = papers.filter { statuses.contains($0.paperStatus) }.count
        return count > 0 ? count : nil
    }

    /// 自著被引用ネットワーク（→ docs/09 4.1節）。
    /// 被引用未取得の自著があればバックグラウンドで取得を投入する
    func ownCitationNetwork() -> CitationStore.OwnNetwork? {
        guard let store else { return nil }
        let network = try? CitationStore(db: store.db).ownCitationNetwork()
        if let network, let queue {
            for paper in papers where paper.isOwn && CitationFetcher.canFetch(for: paper) {
                let hasEdges = network.edges.contains { $0.citedId == paper.id }
                let stale = (try? CitationStore(db: store.db).isStale(paperId: paper.id)) ?? false
                if !hasEdges && stale {
                    try? queue.enqueueIfAbsent(kind: .refetchCitations, paperId: paper.id, origin: .app)
                }
            }
        }
        return network
    }

    // MARK: - 手動解決（→ docs/04 4節, docs/09 3節）

    /// pdf_only論文へDOI / arXiv IDを指定してメタデータ解決をやり直す
    func resolveManually(paperId: String, input: String) {
        guard let queue else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: String] = [:]
        if let parsed = PaperIdentifier.parseArxivID(trimmed) {
            payload["arxiv_id"] = parsed.id
        } else if let doi = PaperIdentifier.parseDOI(trimmed) ?? PaperIdentifier.extractDOI(from: trimmed) {
            payload["doi"] = doi
        } else {
            errorMessage = "DOIまたはarXiv IDとして解釈できません: \(trimmed)"
            return
        }
        do {
            try queue.enqueue(kind: .ingest, paperId: paperId, payload: payload, origin: .app)
            reloadJobs()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - URLスキーム（→ docs/01 6節, docs/11 6節）

    func handleURLScheme(_ url: URL) {
        switch URLSchemeRequest.parse(url) {
        case .importInput(let input):
            // 外部起源は即時実行せず確認ポップアップを経る
            pendingExternalImport = input
        case .openPaper(let id):
            if papers.contains(where: { $0.id == id }) {
                selectedPaperId = id
            } else {
                errorMessage = "論文が見つかりません: \(id)"
            }
        case nil:
            errorMessage = "解釈できないURLです: \(url.absoluteString)"
        }
    }

    func confirmExternalImport() {
        guard let input = pendingExternalImport, let queue else { return }
        do {
            try queue.enqueue(kind: .ingest, payload: ["input": input], origin: .urlScheme)
            reloadJobs()
        } catch {
            errorMessage = String(describing: error)
        }
        pendingExternalImport = nil
    }

    // MARK: - 引用グラフ（→ docs/08）

    func egoNetwork(center paperId: String, hops: Int) -> CitationStore.EgoNetwork? {
        guard let store else { return nil }
        return try? CitationStore(db: store.db).egoNetwork(center: paperId, hops: hops)
    }

    func refetchCitations(paperId: String) {
        guard let queue else { return }
        _ = try? queue.enqueueIfAbsent(kind: .refetchCitations, paperId: paperId, origin: .app)
        reloadJobs()
    }

    /// stubノードの「ライブラリに取り込む」（→ docs/08 4節）。
    /// 外部IDで取り込みジョブを投入すると、resolveで同一行のまま昇格する
    func promoteStub(_ paper: Paper) {
        guard let queue else { return }
        var payload: [String: String] = [:]
        if let doi = paper.doi { payload["doi"] = doi }
        else if let arxivId = paper.arxivId { payload["arxiv_id"] = arxivId }
        else {
            errorMessage = "この論文はDOI/arXiv IDを持たないため取り込めません"
            return
        }
        _ = try? queue.enqueue(kind: .ingest, paperId: nil, payload: payload, origin: .app)
        reloadJobs()
    }

    // MARK: - その他

    func bibtex(for paper: Paper) -> String {
        guard let store else { return "" }
        let authors = (try? store.authors(of: paper.id).map(\.displayName)) ?? []
        let override = (try? store.meta(of: paper.id)?.citationKeyOverride) ?? nil
        return BibtexGenerator().generate(paper: paper, authors: authors, citationKeyOverride: override)
    }

    func authorNames(for paper: Paper) -> [String] {
        guard let store else { return [] }
        return (try? store.authors(of: paper.id).map(\.displayName)) ?? []
    }

    func pdfURL(for paperId: String) -> URL? {
        guard let store else { return nil }
        let url = store.layout.pdfPath(paperId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 有効Markdown（corrected.md優先。AIがMCP経由で読む内容と同一 → docs/05 5.2節, docs/09 4節）
    func markdown(of paperId: String) -> String? {
        guard let store else { return nil }
        return FulltextCorrector(layout: store.layout).effectiveMarkdown(paperId: paperId)
    }

    func hasCorrections(_ paperId: String) -> Bool {
        guard let store else { return false }
        return FulltextCorrector(layout: store.layout).hasCorrections(paperId: paperId)
    }

    func markdownFileURL(of paperId: String) -> URL? {
        guard let store else { return nil }
        let corrector = FulltextCorrector(layout: store.layout)
        let url = corrector.hasCorrections(paperId: paperId)
            ? store.layout.correctedMarkdownPath(paperId)
            : store.layout.markdownPath(paperId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 高精度再変換（force_ocr + formula_enrichment → docs/05 5.1節）
    func reconvert(paperId: String) {
        guard let queue else { return }
        _ = try? queue.enqueue(kind: .reconvert, paperId: paperId, payload: [:], origin: .app)
        reloadJobs()
    }

    /// 変換品質警告の詳細（バッジのツールチップ用 → docs/05 4.1節）
    func qualityWarnings(of paperId: String) -> [ConversionQualityChecker.Warning] {
        guard let markdown = markdown(of: paperId) else { return [] }
        return ConversionQualityChecker().scan(markdown)
    }

    /// Claude Code登録コマンド（最短の登録経路 → docs/07 6節）
    var mcpAddCommand: String {
        let binPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/paperd-mcp").path
        // --scope user: 全プロジェクトで利用可能に（既定のlocalは実行ディレクトリ限定。
        // スキルは ~/.claude/skills で全プロジェクト有効なため、スコープを揃える → docs/07 6節）
        return "claude mcp add --scope user paperd -- \(binPath)"
    }

    /// MCP最終アクセス（→ docs/07 6節）。「◯分前（search_papers）」形式
    var mcpLastAccessText: String? {
        guard let entry = MCPAccessLog().lastAccess(),
              let date = PaperdDates.date(from: entry.at) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "\(relative)（\(entry.tool)）"
    }

    /// MCP設定スニペット（→ docs/07 6節）
    var mcpSnippet: String {
        let binPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/paperd-mcp").path
        return """
        {
          "mcpServers": {
            "paperd": {
              "command": "\(binPath)"
            }
          }
        }
        """
    }
}
