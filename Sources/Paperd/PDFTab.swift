import SwiftUI
import PDFKit
import PaperdCore

/// PDFKitビューア（→ docs/09 5節）。サムネイルと文書内検索はPDFViewの標準機能を利用。
/// 検索ヒットからのページジャンプ（provenance近似）はv1.x課題。
struct PDFTab: View {
    @EnvironmentObject var model: AppModel
    let paperId: String
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            SupplementsSection(paperId: paperId)
        }
    }

    var paper: Paper? { model.papers.first { $0.id == paperId } }

    @ViewBuilder
    var mainContent: some View {
        if let url = model.pdfURL(for: paperId) {
            PDFKitView(url: url)
        } else {
            // ドロップ領域: この論文へのPDF添付（推測なしの確実な合流 → docs/04 4節, docs/09 4節）
            ContentUnavailableView(
                "PDFがありません",
                systemImage: "doc.questionmark",
                description: Text("ここにPDFをドロップすると、**この論文に添付**されて変換・インデックス化が再開されます。")
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : .secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .padding(24)
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                Task {
                    for provider in providers {
                        if let url = try? await provider.loadFileURL(),
                           url.pathExtension.lowercased() == "pdf" {
                            model.attachPDF(paperId: paperId, from: url)
                            break  // 添付は1ファイルのみ
                        }
                    }
                }
                return true
            }
            // 代替PDF（プレプリント・OA版）の自動探索（→ docs/04 6節）
            .safeAreaInset(edge: .bottom) {
                if let paper, paper.doi != nil || paper.arxivId != nil {
                    Button {
                        model.refetchPDF(paper)
                    } label: {
                        Label("代替PDF（プレプリント等）を自動で探す", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    }
                    .help("S2/OpenAlexの補完情報を更新し、arXiv版・OA版のPDFを再探索します")
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

/// 添付ファイル（Supplementary等）セクション（→ docs/09 4節, docs/03 2節）。
/// supplements/フォルダの中身を一覧し、追加（ファイル選択/ドロップ）・削除（ゴミ箱）を提供
struct SupplementsSection: View {
    @EnvironmentObject var model: AppModel
    let paperId: String
    @State private var files: [URL] = []
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("添付ファイル", systemImage: "paperclip")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if files.isEmpty {
                    Text("なし").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    pickSupplements()
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Supplementary等の補助ファイルを追加（ドロップでも追加できます）")
            }
            if !files.isEmpty {
                FlowLikeList(files: files, onOpen: { NSWorkspace.shared.open($0) }, onDelete: remove)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task {
                for provider in providers {
                    if let url = try? await provider.loadFileURL() {
                        model.addSupplement(paperId: paperId, from: url)
                    }
                }
                reload()
            }
            return true
        }
        .task(id: paperId) { reload() }
    }

    func reload() {
        files = model.store?.supplements(of: paperId) ?? []
    }

    func pickSupplements() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "この論文に添付する補助ファイル（Supplementary等）を選択してください")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.addSupplement(paperId: paperId, from: url) }
        reload()
    }

    func remove(_ url: URL) {
        model.removeSupplement(paperId: paperId, filename: url.lastPathComponent)
        reload()
    }
}

/// 添付ファイルの行リスト（クリックで開く・右クリックで削除）
struct FlowLikeList: View {
    let files: [URL]
    let onOpen: (URL) -> Void
    let onDelete: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files, id: \.path) { file in
                    Button {
                        onOpen(file)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc").font(.caption2)
                            Text(file.lastPathComponent).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("クリックで開く: \(file.lastPathComponent)")
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(file)
                        } label: {
                            Label("削除（ゴミ箱へ）", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
