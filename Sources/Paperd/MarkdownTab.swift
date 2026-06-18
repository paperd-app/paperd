import SwiftUI
import AppKit
import PaperdCore

/// Docling変換結果（paper.md）の閲覧タブ（→ docs/09 4節）。
/// AIがMCP経由で読むのはこのMarkdownなので、変換ミスをユーザが発見できるよう
/// PDFタブと見比べられる簡易レンダリングを提供する。
/// 過剰にリッチである必要はなく、見出し・段落・表・リストが読めれば十分。
struct MarkdownTab: View {
    @EnvironmentObject var model: AppModel
    let paperId: String

    var body: some View {
        if let markdown = model.markdown(of: paperId) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label(
                        model.hasCorrections(paperId)
                            ? "修正版Markdown（paper.corrected.md）を表示中 — AIはこの内容を参照します"
                            : "Docling変換結果（paper.md）— AIはこの内容を参照します。変換ミスがないかPDFタブと見比べて確認できます",
                        systemImage: model.hasCorrections(paperId) ? "pencil.circle" : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    qualityBadge

                    Spacer()
                    Button {
                        model.reconvert(paperId: paperId)
                    } label: {
                        Label("高精度で再変換", systemImage: "wand.and.sparkles")
                    }
                    .controlSize(.small)
                    .help(String(localized: "強制OCR + 数式エンリッチメントで変換し直します（数分かかります）。文字化けや上付き文字の潰れの回復に有効です"))
                    Button("Finderで表示") {
                        if let url = model.markdownFileURL(of: paperId) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                Divider()
                let blocks = MarkdownBlockParser.parse(markdown)
                // 検索ヒットからの該当セクションスクロール（→ docs/09 6節）
                let scrollIndex = model.markdownScrollTarget.flatMap {
                    MarkdownBlockParser.blockIndex(forSectionPath: $0, in: blocks)
                }
                MarkdownBlocksView(blocks: blocks, scrollToIndex: scrollIndex) {
                    model.markdownScrollTarget = nil
                }
            }
        } else {
            ContentUnavailableView(
                "Markdownがありません",
                systemImage: "doc.plaintext",
                description: Text("PDF変換（convert）が完了するとここに表示されます。")
            )
        }
    }

    /// 変換品質警告バッジ（→ docs/05 4.1節）
    @ViewBuilder
    var qualityBadge: some View {
        let warnings = model.qualityWarnings(of: paperId)
        if !warnings.isEmpty {
            let total = warnings.reduce(0) { $0 + $1.count }
            Label("文字化けの疑い \(total)件", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(warnings.map { String(localized: "\($0.kind.rawValue): \($0.count)件（例: \($0.sample)）") }.joined(separator: "\n")
                      + String(localized: "\n\nMCP経由でAIに修正させるか、「高精度で再変換」を試してください"))
        }
    }
}

/// ブロック列の簡易レンダラ
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    /// 表示時にスクロールするブロックのインデックス（検索ヒット → docs/09 6節）
    var scrollToIndex: Int? = nil
    var onScrolled: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        render(block)
                            .id(index)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onAppear { scrollIfNeeded(proxy) }
            .onChange(of: scrollToIndex) { _, _ in scrollIfNeeded(proxy) }
        }
    }

    func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard let scrollToIndex else { return }
        // LazyVStackのレイアウト確定を待ってからスクロール
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation {
                proxy.scrollTo(scrollToIndex, anchor: .top)
            }
            onScrolled()
        }
    }

    @ViewBuilder
    func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(let text):
            inlineText(text)

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item)
                    }
                }
            }

        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inlineText(cell).bold()
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }

        case .codeBlock(_, let code):
            Text(code)
                .font(.body.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

        case .imagePlaceholder:
            Label("画像（v1では抽出されません。原図はPDFタブで確認）", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.tertiary)

        case .horizontalRule:
            Divider()
        }
    }

    /// インライン装飾（強調・コード等）はFoundationのMarkdown解釈に委ねる。
    /// 解釈できない場合（生のLaTeX等）はそのまま表示
    func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
    }
}
