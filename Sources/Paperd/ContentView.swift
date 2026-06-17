import SwiftUI
import PaperdCore
import AppKit
import UniformTypeIdentifiers

/// 3ペイン構成（→ docs/09 1節）: サイドバー / 論文リスト / 詳細ペイン
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        // ステータスバー／セットアップバナーはsplit viewの上下に積む3段構成
        // （safeAreaInsetで重ねるとサイドバーの「Library」見出しや下部の「＋ 取り込み」ボタンと
        // 干渉して文字が重なる → docs/09 1節のモックアップどおり）
        VStack(spacing: 0) {
            if model.workerStatus == .notSetup { setupBanner }
            splitView
            JobStatusBar()
        }
    }

    /// 未セットアップ時の誘導バナー（→ docs/09 7.1節。初回ウィザードの前段）
    var setupBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(.orange)
            Text("Python環境が未セットアップです。セットアップを完了するとSemantic検索とPDF変換が有効になります。")
                .font(.callout)
            Spacer()
            SettingsLink { Text("設定を開く") }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    var splitView: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            PaperListView()
        } detail: {
            DetailView()
        }
        .searchable(text: $model.searchQuery, isPresented: $model.searchPresented, prompt: "ライブラリを検索")
        // 検索モードはフィールド直下のスコープバーで切替（→ docs/09 6節）
        .searchScopes($model.searchMode) {
            Text("ハイブリッド").tag(SearchMode.hybrid)
            Text("キーワードのみ").tag(SearchMode.keywordOnly)
        }
        .onSubmit(of: .search) { model.performSearch() }
        .onChange(of: model.searchQuery) { _, newValue in
            if newValue.isEmpty { model.searchResults = nil }
        }
        .onChange(of: model.searchMode) { _, _ in
            // 結果表示中のモード切替は即再検索
            if model.searchResults != nil { model.performSearch() }
        }
        // ウィンドウ全体をPDFドロップターゲットに（→ docs/09 7節）
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadFileURL() {
                        urls.append(url)
                    }
                }
                model.importDroppedPDFs(urls)
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    Rectangle().fill(.blue.opacity(0.15))
                    Label("PDFをドロップして取り込み", systemImage: "arrow.down.doc")
                        .font(.title2)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showImportSheet) { ImportSheet() }
        // paperd:// URLスキーム（→ docs/01 6節）。外部起源は確認を経る（→ docs/11 6節）
        .onOpenURL { url in model.handleURLScheme(url) }
        .confirmationDialog(
            "外部からの取り込みリクエスト",
            isPresented: .init(get: { model.pendingExternalImport != nil },
                               set: { if !$0 { model.pendingExternalImport = nil } }),
            titleVisibility: .visible
        ) {
            Button("取り込む") { model.confirmExternalImport() }
            Button("キャンセル", role: .cancel) { model.pendingExternalImport = nil }
        } message: {
            Text("「\(model.pendingExternalImport ?? "")」をライブラリに取り込みますか？")
        }
        // 一括取り込みの確認（5件以上 → docs/09 7節）
        .confirmationDialog(
            "\(model.pendingBulkImport?.count ?? 0) 件のPDFを取り込みますか？",
            isPresented: .init(get: { model.pendingBulkImport != nil },
                               set: { if !$0 { model.pendingBulkImport = nil } }),
            titleVisibility: .visible
        ) {
            Button("取り込む") { model.confirmBulkImport() }
            Button("キャンセル", role: .cancel) { model.pendingBulkImport = nil }
        } message: {
            Text("変換は1件ずつ順番に実行されるため、件数が多いと完了まで時間がかかります。進捗はステータスバーで確認できます。")
        }
        // インデックス再構築の確認（→ docs/03 5節）
        .confirmationDialog(
            "検索インデックスを再構築しますか？",
            isPresented: $model.showRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button("再構築する") { model.rebuildIndex() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("meta.json等のファイル（正本）からデータベースを作り直し、全論文の検索インデックスをバックグラウンドで再計算します。ワーカーが必要です。")
        }
        .alert("再構築", isPresented: .constant(model.rebuildMessage != nil)) {
            Button("OK") { model.rebuildMessage = nil }
        } message: {
            Text(model.rebuildMessage ?? "")
        }
        .alert("エラー", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            // ジョブ進捗・論文リスト・ワーカー状態の定期更新（JobRunnerは別途5秒ポーリングで駆動）
            while !Task.isCancelled {
                model.reloadJobs()
                model.reload()
                await model.refreshWorkerStatus()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }
}

// MARK: - 取り込みダイアログ（→ docs/09 7節）

struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
    @State private var prefilled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("論文を取り込む").font(.headline)
            Text("arXiv ID / DOI / URL を入力（種別は自動判別）")
                .font(.caption).foregroundStyle(.secondary)
            TextField("例: 1706.03762, 10.1038/nature14539, https://arxiv.org/abs/...", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 420)
                .onSubmit(submit)
            if prefilled {
                Label("クリップボードから入力しました", systemImage: "doc.on.clipboard")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("PDFファイルはウィンドウへのドラッグ&ドロップでも取り込めます（フォルダ可）。")
                .font(.caption).foregroundStyle(.tertiary)
            HStack {
                Button {
                    model.showImportSheet = false
                    model.pickAndImportFiles()
                } label: {
                    Label("ファイル / フォルダから…", systemImage: "folder")
                }
                Spacer()
                Button("キャンセル") { model.showImportSheet = false }
                Button("取り込む", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        // クリップボードの自動プリフィル（→ docs/09 7節）
        .onAppear {
            guard input.isEmpty,
                  let clipboard = NSPasteboard.general.string(forType: .string),
                  PaperIdentifier.isImportable(clipboard)
            else { return }
            input = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            prefilled = true
        }
    }

    func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.enqueueImport(trimmed)
        model.showImportSheet = false
    }
}

// MARK: - サイドバー

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("ライブラリ") {
                ForEach(AppModel.SmartList.allCases) { list in
                    HStack {
                        Label(list.localizedName, systemImage: icon(for: list))
                        // 件数バッジ: 処理中はジョブ数、ステータス別リストは論文数（→ docs/09 2.1節）
                        if let badge = badgeCount(for: list) {
                            Spacer()
                            Text("\(badge)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .tag(AppModel.SidebarSelection.smart(list))
                }
            }
        }
        .listStyle(.sidebar)
        // 「＋ 取り込み」はサイドバー下部に常設（ツールバーだとオーバーフロー「»」に畳まれる → docs/09 7節）
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarImportButton()
        }
    }

    func badgeCount(for list: AppModel.SmartList) -> Int? {
        if list == .processing {
            return model.activeJobs.isEmpty ? nil : model.activeJobs.count
        }
        return model.count(for: list)
    }

    func icon(for list: AppModel.SmartList) -> String {
        switch list {
        case .all: return "books.vertical"
        case .favorites: return "star"
        case .ownPapers: return "person.crop.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .pdfMissing: return "doc.badge.ellipsis"
        case .unresolved: return "questionmark.text.page"
        case .failed: return "xmark.octagon"
        }
    }
}

/// サイドバー下部の常設取り込みボタン（→ docs/09 7節）。
/// macOSのMenuはラベルをAppKitポップアップセルで描き、カスタム塗り・ホバーが効かないため
/// Menuは使わず、本物のButton 2つ（主アクション + ファイル選択）で構成する
struct SidebarImportButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            // 主アクション: URL / DOI / arXiv ID入力（システム標準のアクセント塗り。ホバー・押下はOSが描画）
            Button {
                model.showImportSheet = true
            } label: {
                Label("取り込み", systemImage: "plus")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("arXiv / DOI / URL を入力して取り込む（⌘N）")

            // 副アクション: ファイル / フォルダ選択
            Button {
                model.pickAndImportFiles()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("PDFファイル / フォルダから取り込む（⌘O）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct PaperListView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDelete: Paper?
    @State private var showBulkDeleteConfirm = false

    var selectedPaper: Paper? {
        model.selectedPaperId.flatMap { id in model.papers.first { $0.id == id } }
    }

    @ViewBuilder
    func deleteButton(_ paper: Paper) -> some View {
        // お気に入り・自著フラグのトグル（→ docs/09 2.2節）
        Button {
            model.toggleFavorite(paper)
        } label: {
            Label(paper.isFavorite ? "お気に入りから外す" : "お気に入りに追加",
                  systemImage: paper.isFavorite ? "star.slash" : "star")
        }
        Button {
            model.toggleOwn(paper)
        } label: {
            Label(paper.isOwn ? "自著論文から外す" : "自著論文に登録",
                  systemImage: paper.isOwn ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = paper
        } label: {
            Label("削除…", systemImage: "trash")
        }
    }

    var body: some View {
        List(selection: $model.selectedPaperId) {
            if let grouped = model.groupedSearchResults {
                // 検索結果: 論文単位グルーピング + ヒットチャンク表示（→ docs/09 6節）
                ForEach(grouped, id: \.paper.id) { entry in
                    PaperRow(
                        paper: entry.paper,
                        relativeScore: model.topSearchScore > 0
                            ? (entry.hits.map(\.score).max() ?? 0) / model.topSearchScore
                            : nil
                    )
                    .tag(entry.paper.id)
                    .contextMenu { deleteButton(entry.paper) }
                    // チャンクIDで一意に識別する（offsetだと論文間でIDが衝突し、
                    // Listが行を取り違えて全論文に同じヒットが表示される）
                    ForEach(entry.hits, id: \.chunkId) { hit in
                        SearchHitRow(hit: hit, query: model.searchQuery)
                            // ヒット行はList選択の対象にしない（クリックはButtonが処理。
                            // 選択ハイライトの青で押した行が分からなくなるのを防ぐ）
                            .selectionDisabled(true)
                    }
                }
            } else {
                ForEach(model.visiblePapers, id: \.id) { paper in
                    PaperRow(paper: paper)
                        .tag(paper.id)
                        .contextMenu { deleteButton(paper) }
                }
            }
        }
        // ⌫キーで選択中の論文を削除（→ docs/09 3節）
        .onDeleteCommand {
            if let selected = selectedPaper { pendingDelete = selected }
        }
        .toolbar {
            // ソート（→ docs/09 3節）
            Menu {
                // inline: 「並べ替え >」のサブメニュー階層を作らず選択肢を直接並べる
                Picker("並べ替え", selection: $model.sortOrder) {
                    ForEach(AppModel.PaperSort.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("並べ替え", systemImage: "arrow.up.arrow.down")
            }
            .help("並べ替え: \(model.sortOrder.localizedName)")
            Button {
                if let selected = selectedPaper { pendingDelete = selected }
            } label: {
                Label("削除", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selectedPaper == nil)
            .help("選択中の論文をゴミ箱に移動（⌘⌫）")
            // ステータス別リストの一括削除（→ docs/09 3節）
            if case .smart(let list) = model.sidebarSelection, list.statusFilter != nil, !model.visiblePapers.isEmpty {
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label("このリストをすべて削除…", systemImage: "trash.slash")
                }
                .help("「\(list.localizedName)」の論文をすべてゴミ箱に移動")
            }
        }
        .confirmationDialog(
            "「\(model.listTitle)」の \(model.visiblePapers.count) 件をすべて削除しますか？",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("\(model.visiblePapers.count) 件をゴミ箱に移動", role: .destructive) {
                model.deleteCurrentSmartListPapers()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このリストの論文フォルダがすべてゴミ箱へ移動され、検索インデックスと引用エッジから取り除かれます。")
        }
        // 破壊的操作のため確認ダイアログを経る（→ docs/09 3節）
        .confirmationDialog(
            "「\(pendingDelete?.title ?? "")」を削除しますか？",
            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("ゴミ箱に移動", role: .destructive) {
                if let paper = pendingDelete { model.deletePaper(paper) }
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("PDF・Markdown・ノートを含む論文フォルダがゴミ箱へ移動され、検索インデックスと引用エッジから取り除かれます。ゴミ箱から戻した場合は「インデックス再構築」で復元できます。")
        }
        .navigationTitle(model.listTitle)
        // ⎋（ESC）で選択解除（→ docs/09 3節。リストが長く空白クリックできない場合の経路）
        .background(
            Button("選択を解除") { model.selectedPaperId = nil }
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
        // semantic検索が使えなかったときの案内（→ docs/09 6節「モデル準備中」表示）
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.searchResults != nil, !model.semanticUsed, model.searchMode == .hybrid {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("キーワードのみで検索しました（ワーカー未起動。設定 > ワーカーから起動するとsemantic検索が有効になります）")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.bar)
            }
        }
        .overlay {
            if model.visiblePapers.isEmpty {
                ContentUnavailableView(
                    model.searchResults != nil ? "ヒットなし" : "論文がありません",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(model.searchResults != nil ? "別のキーワードを試してください" : "＋ボタン・PDFドロップ・MCPのadd_paperで論文を追加できます")
                )
            }
        }
    }
}

struct PaperRow: View {
    @EnvironmentObject var model: AppModel
    let paper: Paper
    /// 検索結果での相対強度（トップヒット比 0...1 → docs/09 6節）
    var relativeScore: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                statusBadge
                Text(paper.title).lineLimit(2).font(.body)
                if paper.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                if paper.isOwn {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 10)).foregroundStyle(.teal)
                        .help("自著論文")
                }
                if (paper.conversionWarnings ?? 0) > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("文字化けの疑い \(paper.conversionWarnings!)件（Markdownタブで確認 → docs/05 4.1節）")
                }
                if let relativeScore {
                    Spacer()
                    StrengthBar(ratio: relativeScore)
                        // %は明示specifierでキーに%%として載せる（単独%はString(format:)で%oに化ける）
                        .help("ヒット強度（トップヒット比 \(Int(relativeScore * 100), specifier: "%lld%%")）")
                }
            }
            HStack(spacing: 6) {
                Text(authorAbbrev).foregroundStyle(.secondary)
                if let year = paper.year { Text(String(year)).foregroundStyle(.secondary) }
                if let venue = paper.venue { Text(venue).foregroundStyle(.tertiary) }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// `First+` 形式の省略表記（→ docs/09 3節）
    var authorAbbrev: String {
        let names = model.authorNames(for: paper)
        guard let first = names.first else { return "—" }
        let family = first.components(separatedBy: " ").last ?? first
        return names.count > 1 ? "\(family)+" : family
    }

    /// statusバッジ（→ docs/09 3節）
    @ViewBuilder
    var statusBadge: some View {
        switch paper.paperStatus {
        case .indexed:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .converting:
            ProgressView().controlSize(.mini)
        case .metadataOnly, .pdfOnly:
            Image(systemName: "triangle.fill").font(.system(size: 8)).foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(.red)
        case .stub:
            EmptyView()
        }
    }
}

/// 相対強度バー（→ docs/09 6節）
struct StrengthBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint)
                    .frame(width: max(geo.size.width * ratio, 3))
            }
        }
        .frame(width: 56, height: 5)
    }
}

/// 検索ヒットチャンク行（→ docs/09 6節）。クリックでMarkdownタブの該当セクションへ
struct SearchHitRow: View {
    @EnvironmentObject var model: AppModel
    let hit: SearchResult
    let query: String

    var body: some View {
        Button {
            model.openSearchHit(hit)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    matchChip
                    if let section = hit.sectionPath {
                        Text("§ \(section)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let semantic = hit.semanticScore {
                        Text("意味 \(Int(semantic * 100), specifier: "%lld%%")")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.purple)
                    }
                    if let rank = hit.keywordRank {
                        Text("キーワード #\(rank)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                    }
                }
                Text(highlightedSnippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("クリックでMarkdownタブの該当セクションを開く")
    }

    var matchChip: some View {
        Text(hit.matchType.rawValue)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(chipColor.opacity(0.18), in: Capsule())
            .foregroundStyle(chipColor)
    }

    var chipColor: Color {
        switch hit.matchType {
        case .hybrid: return .green
        case .semantic: return .purple
        case .keyword: return .orange
        }
    }

    /// クエリ語のハイライト（keyword/hybridのみ → docs/09 6節）
    var highlightedSnippet: AttributedString {
        let raw = String(hit.chunkText.replacingOccurrences(of: "\n", with: " ").prefix(200))
        guard hit.matchType != .semantic else { return AttributedString(raw) }
        let ranges = SearchPresentation.termRanges(query: query, in: raw)
        guard !ranges.isEmpty else { return AttributedString(raw) }

        var result = AttributedString()
        var cursor = raw.startIndex
        for range in ranges {
            result += AttributedString(String(raw[cursor..<range.lowerBound]))
            var term = AttributedString(String(raw[range]))
            term.inlinePresentationIntent = .stronglyEmphasized
            term.foregroundColor = .orange
            result += term
            cursor = range.upperBound
        }
        result += AttributedString(String(raw[cursor...]))
        return result
    }
}

// MARK: - 詳細ペイン（タブ構成 → docs/09 4節）

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let paperId = model.selectedPaperId,
           let paper = model.papers.first(where: { $0.id == paperId }) {
            VStack(spacing: 0) {
                Picker("", selection: $model.detailTab) {
                    ForEach(AppModel.DetailTab.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(8)
                Divider()
                switch model.detailTab {
                case .info: InfoTab(paper: paper)
                case .pdf: PDFTab(paperId: paper.id)
                case .markdown: MarkdownTab(paperId: paper.id)
                case .notes: NotesTab(paperId: paper.id)
                case .graph: CitationGraphView(paper: paper)
                }
            }
        } else if case .smart(.ownPapers) = model.sidebarSelection {
            // 自著リスト選択直後（論文未選択）は被引用ネットワークを表示（→ docs/09 4.1節）
            OwnPapersNetworkView()
        } else if case .smart(.processing) = model.sidebarSelection {
            // 処理中リスト: ジョブモニタ（→ docs/09 4.2節）
            JobMonitorView()
        } else if case .smart(let list) = model.sidebarSelection, list.statusFilter != nil {
            // ステータス別リスト: 説明 + アクションパネル（→ docs/09 4.2節）
            StatusListPanel(list: list)
        } else {
            // 通常リスト: ライブラリ概況ダッシュボード（→ docs/09 4.2節）
            LibraryDashboardView()
        }
    }
}

struct InfoTab: View {
    @EnvironmentObject var model: AppModel
    let paper: Paper
    @State private var manualResolveInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // メタデータ未解決の手動解決UI（→ docs/04 4節, docs/09 3節）
                if paper.paperStatus == .pdfOnly {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("メタデータ未解決", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.bold())
                            .foregroundStyle(.orange)
                        Text("書誌情報を自動解決できませんでした。この論文のDOIまたはarXiv IDを入力すると解決をやり直します。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("例: 10.1134/S1063784214120020 / 1706.03762", text: $manualResolveInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(submitManualResolve)
                            Button("解決", action: submitManualResolve)
                                .disabled(manualResolveInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(paper.title).font(.title2).bold().textSelection(.enabled)
                    Spacer()
                    // お気に入り・自著トグル（→ docs/09 2.2節）
                    Button {
                        model.toggleFavorite(paper)
                    } label: {
                        Image(systemName: paper.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(paper.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(paper.isFavorite ? "お気に入りから外す" : "お気に入りに追加")
                    Button {
                        model.toggleOwn(paper)
                    } label: {
                        Image(systemName: paper.isOwn ? "person.crop.circle.fill" : "person.crop.circle")
                            .foregroundStyle(paper.isOwn ? .teal : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(paper.isOwn ? "自著論文から外す" : "自著論文に登録")
                }
                Text(model.authorNames(for: paper).joined(separator: ", "))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    if let venue = paper.venue { Text(venue) }
                    if let year = paper.year { Text(String(year)) }
                    Text(paper.status).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .foregroundStyle(.secondary)

                if let doi = paper.doi { LabeledContent("DOI", value: doi) }
                if let arxivId = paper.arxivId {
                    LabeledContent("arXiv", value: arxivId + (paper.arxivVersion ?? ""))
                }

                if let abstract = paper.abstract {
                    Text("Abstract").font(.headline).padding(.top, 8)
                    Text(abstract).textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button {
                        let bibtex = model.bibtex(for: paper)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bibtex, forType: .string)
                    } label: {
                        Label("BibTeXをコピー", systemImage: "doc.on.doc")
                    }
                    // 整形済み引用文のコピー（スタイル選択つき → docs/02 2.4節）
                    Menu {
                        ForEach(CitationFormatter.Style.allCases) { style in
                            Button(style.localizedName) { copyCitation(style: style) }
                        }
                    } label: {
                        Label("引用をコピー", systemImage: "quote.opening")
                    }
                    .fixedSize()
                    .help("スタイルを選んで整形済みの引用文をコピー（前回: \(lastCitationStyle.localizedName)）")
                    if let webURL = paper.webURL {
                        Button {
                            NSWorkspace.shared.open(webURL)
                        } label: {
                            Label("Webページを開く", systemImage: "safari")
                        }
                        .help(webURL.absoluteString)
                    }
                    if model.pdfURL(for: paper.id) != nil {
                        Button {
                            exportPDF()
                        } label: {
                            Label("PDFを書き出し", systemImage: "square.and.arrow.down")
                        }
                        .help("人に送れるファイル名でPDFをコピーします")
                    }
                }
                .padding(.top, 8)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func submitManualResolve() {
        let input = manualResolveInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        model.resolveManually(paperId: paper.id, input: input)
        manualResolveInput = ""
    }

    /// PDFの書き出し（送付用ファイル名でコピー → docs/09 4節）
    /// 整形済み引用文のコピー（→ docs/02 2.4節）。最後に使ったスタイルを記憶
    var lastCitationStyle: CitationFormatter.Style {
        UserDefaults.standard.string(forKey: "citationStyle")
            .flatMap(CitationFormatter.Style.init(rawValue:)) ?? .apa
    }

    func copyCitation(style: CitationFormatter.Style) {
        UserDefaults.standard.set(style.rawValue, forKey: "citationStyle")
        let authors = (try? model.store?.authors(of: paper.id)) ?? []
        let citation = CitationFormatter.format(paper: paper, authors: authors ?? [], style: style)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(citation, forType: .string)
    }

    func exportPDF() {
        guard let source = model.pdfURL(for: paper.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PaperExport.filename(
            paper: paper, authors: model.authorNames(for: paper))
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

struct NotesTab: View {
    @EnvironmentObject var model: AppModel
    let paperId: String
    @State private var content = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $content)
                .font(.body.monospaced())
                .padding(4)
            Divider()
            HStack {
                Text("正本: papers/\(String(paperId.prefix(8)))…/notes.md")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("保存") { model.saveNote(paperId: paperId, content: content) }
                    .keyboardShortcut("s")
            }
            .padding(8)
        }
        .onAppear {
            if !loaded {
                content = model.note(of: paperId)
                loaded = true
            }
        }
        .onChange(of: paperId) { _, newId in
            content = model.note(of: newId)
        }
    }
}

// MARK: - ジョブ進捗（→ docs/09 7.1節）

struct JobStatusBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 12) {
            if !model.activeJobs.isEmpty || !model.failedJobs.isEmpty {
                Button {
                    showPopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if !model.activeJobs.isEmpty {
                            ProgressView().controlSize(.small)
                            Text("ジョブ \(model.activeJobs.count) 件")
                        }
                        if !model.failedJobs.isEmpty {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                            Text("失敗 \(model.failedJobs.count) 件")
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPopover) { JobListPopover() }
            }
            Spacer()
            WorkerIndicator()
            Divider().frame(height: 12)
            MCPIndicator()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// MCPインジケータ（→ docs/09 7.1節）。最終アクセスを表示し、クリックで設定の連携タブへ
struct MCPIndicator: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            model.settingsTab = .integration
            openSettings()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(model.mcpLastAccessText != nil ? .purple : .secondary)
                Text(model.mcpLastAccessText.map { "MCP: \($0)" } ?? String(localized: "MCP: 未接続"))
            }
            .font(.caption)
            .foregroundStyle(model.mcpLastAccessText != nil ? .secondary : .tertiary)
        }
        .buttonStyle(.plain)
        .help(model.mcpLastAccessText != nil
              ? "MCPの最終アクセス。クリックで連携設定を開く"
              : "AIクライアント（Claude等）からのアクセスはまだありません。クリックで登録方法を表示")
    }
}

/// ワーカー稼働インジケータ（→ docs/09 7.1節）。クリックで設定のワーカータブへ（MCPインジケータと同じ挙動）
struct WorkerIndicator: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            model.settingsTab = .worker
            openSettings()
        } label: {
            HStack(spacing: 5) {
                switch model.workerStatus {
                case .running(let version):
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("ワーカー稼働中 (\(version))")
                case .stopped:
                    Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 7, height: 7)
                    Text("ワーカー停止中")
                case .notSetup:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                    Text("ワーカー未セットアップ")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    var helpText: String {
        switch model.workerStatus {
        case .running: return String(localized: "Pythonワーカー（PDF変換・Semantic検索）が稼働中。クリックでワーカー設定を開く")
        case .stopped: return String(localized: "ワーカー停止中。クリックでワーカー設定を開く（起動ボタンがあります）")
        case .notSetup: return String(localized: "クリックでワーカー設定を開く")
        }
    }
}

struct JobListPopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.activeJobs + model.failedJobs, id: \.id) { job in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(jobTitle(job)).lineLimit(1)
                        Spacer()
                        Text(job.status).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if let stage = job.stage {
                            Text("ステージ: \(stage)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let error = job.lastError {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        }
                        Spacer()
                        if job.jobStatus == .failed {
                            Button("再試行") { model.retryJob(job.id) }
                                .font(.caption)
                            // 再試行しないと判断した失敗のクリア（→ docs/09 7.1節）
                            Button("無視") { model.dismissFailedJob(job.id) }
                                .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.failedJobs.isEmpty {
                HStack {
                    Text("失敗 \(model.failedJobs.count) 件").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("失敗をすべて無視") { model.dismissAllFailedJobs() }
                        .font(.caption)
                        .help("失敗ジョブの記録を消去します（論文自体は消えません）")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.bar)
            }
        }
        .frame(width: 380, height: 260)
    }

    func jobTitle(_ job: Job) -> String {
        if let paperId = job.paperId,
           let paper = model.papers.first(where: { $0.id == paperId }) {
            return paper.title
        }
        return "\(job.kind): \(job.payload.prefix(60))"
    }
}

extension CitationFormatter.Style {
    /// 表示名。rawValueはUserDefaults保存キーのため固定し、表示のみローカライズする（→ docs/09 10節）
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}
