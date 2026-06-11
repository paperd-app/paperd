import SwiftUI
import PaperdCore

/// 自著被引用ネットワーク（→ docs/09 4.1節）。
/// サイドバーで「自著論文」を選択した直後（論文未選択）に詳細ペインへ表示する。
/// 利便性ではなく**満足感・達成感のための画面**なので、意図的にリッチに作る:
/// ダーク背景 + 金色に発光する自著ノード + 収束アニメーション + 大きな統計数字。
struct OwnPapersNetworkView: View {
    @EnvironmentObject var model: AppModel

    @State private var network: CitationStore.OwnNetwork?
    @State private var layout: ForceLayout?
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedNodeId: String?
    /// 出現アニメーション用（0→1でフェードイン）
    @State private var reveal: Double = 0

    let frameTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // ダークグラデーション背景（→ docs/09 4.1節）
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if let network, !network.ownIds.isEmpty {
                VStack(spacing: 0) {
                    statsHeader(network)
                    GeometryReader { geo in
                        networkCanvas(network, size: geo.size)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let nodeId = selectedNodeId,
                       let node = network.nodes.first(where: { $0.id == nodeId }) {
                        NodeDetailPanel(node: node) { selectedNodeId = nil }
                            .padding(10)
                    }
                }
            } else {
                emptyState
            }
        }
        .task(id: model.papers.map(\.id).joined()) { load() }
        .onReceive(frameTimer) { _ in advanceAnimation() }
    }

    // MARK: - 統計ヘッダ（大きなタイポグラフィ → docs/09 4.1節）

    func statsHeader(_ network: CitationStore.OwnNetwork) -> some View {
        VStack(spacing: 6) {
            if network.incomingCitationCount > 0 {
                (Text("あなたの ")
                 + Text("\(network.ownIds.count)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(goldGradient)
                 + Text(" 本の論文は、これまでに ")
                 + Text("\(network.incomingCitationCount)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(goldGradient)
                 + Text(" 回 引用されています"))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Text("あなたの \(network.ownIds.count) 本の論文のネットワーク")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
            }
            HStack(spacing: 18) {
                statChip("doc.text.fill", "自著 \(network.ownIds.count) 本")
                statChip("quote.opening", "被引用 \(network.incomingCitationCount) 件")
                statChip("person.2.fill", "引用元 \(network.uniqueCiterCount) 論文")
                if network.edges.count < network.totalIncomingCount {
                    statChip("eye", "表示は上位\(network.edges.count)件")
                }
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 14)
        .opacity(reveal)
    }

    func statChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.callout.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
    }

    var goldGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 1.0, green: 0.85, blue: 0.4), Color(red: 0.95, green: 0.65, blue: 0.15)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: - ネットワーク描画

    func networkCanvas(_ network: CitationStore.OwnNetwork, size: CGSize) -> some View {
        let transform = { (p: CGPoint) -> CGPoint in
            CGPoint(x: p.x / 800 * size.width, y: p.y / 600 * size.height)
        }
        let yearRange = yearBounds(network)

        return Canvas { context, _ in
            // エッジ: 引用元 → 自著への半透明発光ライン
            for edge in network.edges {
                guard let from = positions[edge.citingId].map(transform),
                      let to = positions[edge.citedId].map(transform) else { continue }
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(.cyan.opacity(0.16 * reveal)), lineWidth: 1.6)
                context.stroke(path, with: .color(.white.opacity(0.25 * reveal)), lineWidth: 0.5)
            }

            // 引用元ノード: 出版年が新しいほど明るい（影響が広がっている感覚 → docs/09 4.1節）
            for node in network.nodes where !network.ownIds.contains(node.id) {
                guard let center = positions[node.id].map(transform) else { continue }
                let brightness = yearBrightness(node.year, range: yearRange)
                let radius = 4.5
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color(hue: 0.52, saturation: 0.65, brightness: 0.35 + 0.6 * brightness).opacity(reveal))
                )
            }

            // 自著ノード: 金色グロー（サイズは被引用数の対数スケール）
            for ownId in network.ownIds {
                guard let center = positions[ownId].map(transform) else { continue }
                let radius = ForceLayout.nodeRadius(citationCount: network.citationCount(of: ownId), base: 9, scale: 7)
                // グロー（外側ほど薄い同心円）
                for (factor, alpha) in [(2.6, 0.07), (1.9, 0.14), (1.4, 0.25)] {
                    let r = radius * factor
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .color(Color(red: 1.0, green: 0.78, blue: 0.25).opacity(alpha * reveal))
                    )
                }
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.6).opacity(reveal),
                                          Color(red: 0.93, green: 0.62, blue: 0.12).opacity(reveal)]),
                        center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3),
                        startRadius: 0, endRadius: radius * 1.4
                    )
                )
                // タイトルラベル
                if let paper = network.nodes.first(where: { $0.id == ownId }) {
                    let title = paper.title.count > 34 ? String(paper.title.prefix(34)) + "…" : paper.title
                    context.draw(
                        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85 * reveal)),
                        at: CGPoint(x: center.x, y: center.y + radius + 11)
                    )
                }
            }
        }
        .onTapGesture { location in
            let p = CGPoint(x: location.x / size.width * 800, y: location.y / size.height * 600)
            let hit = network.nodes.min { a, b in
                distance(positions[a.id], p) < distance(positions[b.id], p)
            }
            if let hit, distance(positions[hit.id], p) < 24 {
                if network.ownIds.contains(hit.id) {
                    model.selectedPaperId = hit.id  // 自著 → 詳細を開く
                } else {
                    selectedNodeId = hit.id
                }
            } else {
                selectedNodeId = nil
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(goldGradient)
            Text("自著論文を登録しましょう")
                .font(.title2.bold())
                .foregroundStyle(.white.opacity(0.9))
            Text("論文リストの右クリックメニュー、または情報タブの人物アイコンから\n「自著論文に登録」すると、ここにあなたの論文の被引用ネットワークが表示されます。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(40)
    }

    // MARK: - レイアウトと収束アニメーション（→ docs/09 4.1節）

    func load() {
        guard case .smart(.ownPapers) = model.sidebarSelection else { return }
        let fetched = model.ownCitationNetwork()
        network = fetched
        reveal = 0
        guard let fetched, !fetched.nodes.isEmpty else {
            layout = nil
            return
        }
        layout = ForceLayout(
            nodes: fetched.nodes.map(\.id),
            edges: fetched.edges.map { ($0.citingId, $0.citedId) },
            width: 800, height: 560
        )
        applyPositions()
    }

    /// 毎フレーム: レイアウトを数ステップ進め、収束までネットワークが組み上がる様子を見せる
    func advanceAnimation() {
        if reveal < 1 { reveal = min(1, reveal + 0.04) }
        guard var current = layout, !current.isConverged else { return }
        for _ in 0..<3 { current.step() }
        layout = current
        applyPositions()
    }

    func applyPositions() {
        guard let layout, let network else { return }
        var result: [String: CGPoint] = [:]
        for (i, node) in network.nodes.enumerated() where i < layout.positions.count {
            result[node.id] = CGPoint(x: layout.positions[i].x, y: layout.positions[i].y)
        }
        positions = result
    }

    func yearBounds(_ network: CitationStore.OwnNetwork) -> ClosedRange<Int> {
        let years = network.nodes.compactMap(\.year)
        guard let lo = years.min(), let hi = years.max(), lo <= hi else { return 2000...2026 }
        return lo...hi
    }

    func yearBrightness(_ year: Int?, range: ClosedRange<Int>) -> Double {
        guard let year, range.upperBound > range.lowerBound else { return 0.6 }
        return Double(year - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    func distance(_ a: CGPoint?, _ b: CGPoint) -> CGFloat {
        guard let a else { return .infinity }
        return hypot(a.x - b.x, a.y - b.y)
    }
}
