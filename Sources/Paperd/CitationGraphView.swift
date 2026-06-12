import SwiftUI
import PaperdCore

/// エゴネットワーク表示（→ docs/08 5節）。
/// SwiftUI Canvas + ForceLayout（自前実装）。ズーム/パン、ホップ数切替、ノードクリックで詳細。
struct CitationGraphView: View {
    @EnvironmentObject var model: AppModel
    let paper: Paper

    @State private var network: CitationStore.EgoNetwork?
    @State private var positions: [String: CGPoint] = [:]
    /// 漸進レイアウト（UIスレッドで同期実行しない → docs/08 6節）
    @State private var layout: ForceLayout?
    let frameTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    @State private var hops = 1
    @State private var selectedNodeId: String?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var autoRefetched = false
    /// 年代フィルタ（→ docs/08 6節）。表示する出版年の下限
    @State private var minYear: Double = 0
    @State private var yearBounds: ClosedRange<Double> = 0...1
    /// 関係フィルタ（→ docs/08 6節）
    @State private var relation: CitationStore.CitationRelation = .all

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 関係フィルタ: 引用している/されているの切替（→ docs/08 6節）
                Picker("関係", selection: $relation) {
                    Text("すべて").tag(CitationStore.CitationRelation.all)
                    Text("参考文献").tag(CitationStore.CitationRelation.references)
                    Text("被引用").tag(CitationStore.CitationRelation.citations)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("参考文献 = この論文が引用 / 被引用 = この論文を引用")
                Picker("ホップ", selection: $hops) {
                    Text("1ホップ").tag(1)
                    Text("2ホップ").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                if yearBounds.lowerBound < yearBounds.upperBound {
                    // 年代フィルタスライダ（→ docs/08 6節）
                    Slider(value: $minYear, in: yearBounds, step: 1) {
                        Text("年代")
                    }
                    .frame(width: 140)
                    .help("表示する出版年の下限")
                    Text(minYear > yearBounds.lowerBound ? "\(Int(minYear))年〜" : "全期間")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                }
                Spacer()
                if autoRefetched {
                    Text("引用情報を更新中…").font(.caption).foregroundStyle(.tertiary)
                }
                Button {
                    model.refetchCitations(paperId: paper.id)
                } label: {
                    Label("引用情報を更新", systemImage: "arrow.clockwise")
                }
            }
            .padding(8)
            Divider()

            if let network, !network.edges.isEmpty {
                GeometryReader { geo in
                    graphCanvas(network: network, size: geo.size)
                }
                // 凡例（→ docs/08 5節）
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 3) {
                        legendRow(.blue, String(localized: "参考文献（この論文が引用）"))
                        legendRow(.green, String(localized: "被引用（この論文を引用）"))
                        legendRow(.purple, String(localized: "相互引用"))
                        legendRow(.gray, String(localized: "2ホップ先（間接）"))
                        HStack(spacing: 5) {
                            Circle().strokeBorder(.orange, lineWidth: 2).frame(width: 9, height: 9)
                            Text("中心").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("薄色 = 未取り込み（stub）").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    if let nodeId = selectedNodeId,
                       let node = network.nodes.first(where: { $0.id == nodeId }) {
                        NodeDetailPanel(node: node) { self.selectedNodeId = nil }
                            .padding(8)
                    }
                }
            } else {
                ContentUnavailableView(
                    "引用データがありません",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("「引用情報を更新」でSemantic Scholarから取得します（取り込み完了時にも自動取得されます）")
                )
            }
        }
        .task(id: "\(paper.id)-\(hops)-\(Int(minYear))-\(relation.rawValue)") { load() }
        .onReceive(frameTimer) { _ in advanceLayout() }
    }

    func load() {
        // TTL失効時はキャッシュで即描画した上でバックグラウンド再取得（→ docs/08 2節・3節）
        if !autoRefetched, let store = model.store,
           (try? CitationStore(db: store.db).isStale(paperId: paper.id)) == true {
            model.refetchCitations(paperId: paper.id)
            autoRefetched = true
        }
        // 関係フィルタ（→ docs/08 6節）
        var fetched = model.egoNetwork(center: paper.id, hops: hops)?.filtered(relation)
        // 年代フィルタ: 範囲外ノード（中心以外）とそのエッジを間引く（→ docs/08 6節）
        if let full = fetched {
            let years = full.nodes.compactMap(\.year)
            if let lo = years.min(), let hi = years.max(), lo < hi {
                let bounds = Double(lo)...Double(hi)
                if yearBounds != bounds {
                    yearBounds = bounds
                    minYear = bounds.lowerBound
                }
                if minYear > bounds.lowerBound {
                    let kept = Set(full.nodes.filter {
                        $0.id == paper.id || Double($0.year ?? 0) >= minYear
                    }.map(\.id))
                    fetched = CitationStore.EgoNetwork(
                        center: full.center,
                        nodes: full.nodes.filter { kept.contains($0.id) },
                        edges: full.edges.filter { kept.contains($0.citingId) && kept.contains($0.citedId) }
                    )
                }
            }
        }
        network = fetched
        guard let network else {
            layout = nil
            return
        }
        // 漸進レイアウト: フレームごとに数ステップ進め、収束までアニメーション表示（→ docs/08 6節）
        layout = ForceLayout(
            nodes: network.nodes.map(\.id),
            edges: network.edges.map { ($0.citingId, $0.citedId) },
            width: 800, height: 600,
            fixed: paper.id
        )
        applyPositions()
    }

    func advanceLayout() {
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

    func graphCanvas(network: CitationStore.EgoNetwork, size: CGSize) -> some View {
        let transform = { (p: CGPoint) -> CGPoint in
            CGPoint(
                x: (p.x - 400) * zoom + size.width / 2 + pan.width,
                y: (p.y - 300) * zoom + size.height / 2 + pan.height
            )
        }
        return Canvas { context, _ in
            // エッジ（citing → cited、矢印つき → docs/08 5節）
            for edge in network.edges {
                guard let from = positions[edge.citingId].map(transform),
                      let to = positions[edge.citedId].map(transform) else { continue }
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                drawArrowhead(context: context, from: from, to: to)
            }
            // ノード
            for node in network.nodes {
                guard let center = positions[node.id].map(transform) else { continue }
                let radius = ForceLayout.nodeRadius(citationCount: 0) * zoom
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                // 中心との関係で色分け + stubは薄色（→ docs/08 5節）
                let base = relationColor(network.nodeRelation(of: node.id))
                let color = node.isStub ? base.opacity(0.35) : base
                context.fill(Path(ellipseIn: rect), with: .color(color))
                if node.id == network.center {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.orange), lineWidth: 2)
                }
                if zoom > 0.7 {
                    let title = node.title.count > 28 ? String(node.title.prefix(28)) + "…" : node.title
                    context.draw(
                        Text(title).font(.system(size: 9)).foregroundStyle(.secondary),
                        at: CGPoint(x: center.x, y: center.y + radius + 8)
                    )
                }
                // 表示上限による間引きの明示（→ docs/08 6節）
                if let omittedCount = network.omittedEdgeCounts[node.id] {
                    context.draw(
                        Text("+\(omittedCount)件省略").font(.system(size: 8, weight: .medium)).foregroundStyle(.orange),
                        at: CGPoint(x: center.x, y: center.y - radius - 8)
                    )
                }
            }
        }
        .gesture(
            DragGesture().onChanged { pan = $0.translation }
        )
        .gesture(
            MagnifyGesture().onChanged { zoom = max(0.3, min($0.magnification, 3)) }
        )
        .onTapGesture { location in
            // 逆変換してノード当たり判定
            let p = CGPoint(
                x: (location.x - size.width / 2 - pan.width) / zoom + 400,
                y: (location.y - size.height / 2 - pan.height) / zoom + 300
            )
            selectedNodeId = network.nodes.first { node in
                guard let pos = positions[node.id] else { return false }
                return hypot(pos.x - p.x, pos.y - p.y) < 14
            }?.id
        }
    }

    /// 中心との関係 → 色（凡例と一致 → docs/08 5節）
    func relationColor(_ relation: CitationStore.EgoNetwork.NodeRelation) -> Color {
        switch relation {
        case .center: return .blue
        case .reference: return .blue
        case .citer: return .green
        case .both: return .purple
        case .indirect: return .gray
        }
    }

    func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    func drawArrowhead(context: GraphicsContext, from: CGPoint, to: CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let tip = CGPoint(x: to.x - 10 * cos(angle), y: to.y - 10 * sin(angle))
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - 6 * cos(angle - 0.4), y: tip.y - 6 * sin(angle - 0.4)))
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - 6 * cos(angle + 0.4), y: tip.y - 6 * sin(angle + 0.4)))
        context.stroke(arrow, with: .color(.gray.opacity(0.7)), lineWidth: 1)
    }
}

/// ノードクリックの詳細パネル（→ docs/08 5節）
struct NodeDetailPanel: View {
    @EnvironmentObject var model: AppModel
    let node: Paper
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(node.title).font(.callout).bold().lineLimit(2)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                if let year = node.year { Text(String(year)) }
                if let venue = node.venue { Text(venue).lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)

            if node.isStub {
                Button {
                    model.promoteStub(node)
                    onClose()
                } label: {
                    Label("ライブラリに取り込む", systemImage: "plus.circle")
                }
                .controlSize(.small)
            } else {
                Button {
                    model.selectedPaperId = node.id
                    onClose()
                } label: {
                    Label("開く", systemImage: "arrow.right.circle")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
