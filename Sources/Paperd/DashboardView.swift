import SwiftUI
import PaperdCore

/// 論文未選択時のライブラリ概況（→ docs/09 4.2節）。
/// 選択中リストを母集合とした統計 + 次のアクションへの導線。
struct LibraryDashboardView: View {
    @EnvironmentObject var model: AppModel

    var papers: [Paper] { model.visiblePapers }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(model.listTitle)
                    .font(.largeTitle.bold())
                    .padding(.top, 8)

                // 統計の大きな数字
                HStack(spacing: 14) {
                    statCard(value: papers.count, label: "論文", icon: "books.vertical.fill", color: .blue)
                    statCard(value: papers.filter { $0.paperStatus == .indexed }.count,
                             label: "全文検索可能", icon: "magnifyingglass", color: .teal)
                    statCard(value: notedCount, label: "ノートあり", icon: "note.text", color: .orange)
                }

                if papers.count > 1 {
                    yearHistogram
                }

                if !recentPapers.isEmpty {
                    section("最近追加") {
                        ForEach(recentPapers, id: \.id) { paper in
                            Button {
                                model.selectedPaperId = paper.id
                            } label: {
                                HStack {
                                    Text(paper.title).lineLimit(1)
                                    Spacer()
                                    Text(String(paper.addedAt.prefix(10)))
                                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }

                attentionSummary

                if warningCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("文字化けの疑いがある論文が \(warningCount) 件あります。Markdownタブの「高精度で再変換」をお試しください。")
                            .font(.callout)
                    }
                }

                Label("「あの手法について書いてあった論文」のように自然言語でも検索できます（⌘F）。ClaudeなどのAIからの利用は設定 > 連携から。",
                      systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 構成要素

    var notedCount: Int {
        guard let store = model.store, let noted = try? store.notedPaperIds() else { return 0 }
        return papers.filter { noted.contains($0.id) }.count
    }

    var recentPapers: [Paper] {
        Array(papers.sorted { $0.addedAt > $1.addedAt }.prefix(5))
    }

    var warningCount: Int {
        papers.filter { ($0.conversionWarnings ?? 0) > 0 }.count
    }

    func statCard(value: Int, label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minWidth: 120, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 出版年のミニヒストグラム（→ docs/09 4.2節）
    var yearHistogram: some View {
        let years = papers.compactMap(\.year)
        guard let lo = years.min(), let hi = years.max(), lo <= hi else {
            return AnyView(EmptyView())
        }
        var buckets: [Int: Int] = [:]
        for year in years { buckets[year, default: 0] += 1 }
        let maxCount = buckets.values.max() ?? 1
        let range = Array(lo...hi)

        return AnyView(section("出版年の分布") {
            VStack(alignment: .leading, spacing: 4) {
                Canvas { context, size in
                    let barWidth = size.width / CGFloat(range.count)
                    for (i, year) in range.enumerated() {
                        let count = buckets[year] ?? 0
                        guard count > 0 else { continue }
                        let height = max(3, size.height * CGFloat(count) / CGFloat(maxCount))
                        let rect = CGRect(
                            x: CGFloat(i) * barWidth + 1, y: size.height - height,
                            width: max(2, barWidth - 2), height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.blue.opacity(0.7)))
                    }
                }
                .frame(height: 56)
                HStack {
                    Text(String(lo)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Text(String(hi)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        })
    }

    /// 対応待ちサマリ: クリックでそのリストへ移動
    @ViewBuilder
    var attentionSummary: some View {
        let items: [(AppModel.SmartList, String)] = [
            (.pdfMissing, "doc.badge.ellipsis"), (.unresolved, "questionmark.text.page"), (.failed, "xmark.octagon"),
        ].compactMap { list, icon in model.count(for: list) != nil ? (list, icon) : nil }
        if !items.isEmpty {
            section("対応待ち") {
                HStack(spacing: 10) {
                    ForEach(items, id: \.0) { list, icon in
                        Button {
                            model.sidebarSelection = .smart(list)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: icon).font(.caption)
                                Text("\(list.rawValue) \(model.count(for: list) ?? 0)")
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("「\(list.rawValue)」リストを開く")
                    }
                }
            }
        }
    }

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// ステータス別リストの説明 + アクションパネル（→ docs/09 4.2節）
struct StatusListPanel: View {
    @EnvironmentObject var model: AppModel
    let list: AppModel.SmartList
    @State private var showBulkDeleteConfirm = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(list.rawValue).font(.title2.bold())
            Text(explanation)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            if model.visiblePapers.isEmpty {
                Label("このリストは空です", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .padding(.top, 6)
            } else {
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label("このリストの \(model.visiblePapers.count) 件をすべて削除…", systemImage: "trash")
                }
                .padding(.top, 6)
            }
        }
        .padding(40)
        .confirmationDialog(
            "「\(list.rawValue)」の \(model.visiblePapers.count) 件をすべて削除しますか？",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("\(model.visiblePapers.count) 件をゴミ箱に移動", role: .destructive) {
                model.deleteCurrentSmartListPapers()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このリストの論文フォルダがすべてゴミ箱へ移動されます。")
        }
    }

    var icon: String {
        switch list {
        case .pdfMissing: return "doc.badge.ellipsis"
        case .unresolved: return "questionmark.text.page"
        case .failed: return "xmark.octagon"
        default: return "doc.text"
        }
    }

    var explanation: String {
        switch list {
        case .pdfMissing:
            return "paywall等でPDFを取得できなかった、または書誌のみ登録した論文です。書誌・BibTeX・タイトル+アブストの検索は機能しています。論文を選択してPDFタブの「代替PDFを自動で探す」でプレプリント版・OA版を再探索するか、入手したPDFをPDFタブへドロップすると全文が索引化されます。"
        case .unresolved:
            return "PDFはありますが書誌（メタデータ）が特定できていない論文です。BibTeXの生成や引用グラフが使えません。論文を選択して「メタデータ未解決」バナーからDOI / arXiv IDを指定すると解決できます。"
        case .failed:
            return "取り込み処理に失敗した論文です。ステータスバーのジョブ一覧から再試行するか、不要であればまとめて削除できます。"
        default:
            return ""
        }
    }
}
