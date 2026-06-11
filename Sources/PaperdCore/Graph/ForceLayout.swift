import Foundation

/// Fruchterman-Reingold系のforce-directedレイアウト自前実装（→ docs/08 5節）。
/// 対象は数百ノード規模。UIに依存しない純粋な計算なので単体テスト可能。
public struct ForceLayout: Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public let nodeIds: [String]
    public let edges: [(Int, Int)]
    public private(set) var positions: [Point]
    /// 中心論文は固定位置（初期レイアウトの中央 → docs/08 5節）
    public let fixedIndex: Int?
    public let width: Double
    public let height: Double

    let k: Double  // 理想エッジ長
    var temperature: Double

    /// 収束したか（アニメーション表示の停止判定 → docs/09 4.1節）
    public var isConverged: Bool { temperature <= 0.5 }

    /// - Parameters:
    ///   - nodes: ノードID列（決定的な初期配置のためIDのハッシュで配置する）
    ///   - edges: (citing, cited)のIDペア。未知のIDは無視
    ///   - fixed: 固定するノードID（中心論文）。中央に配置される
    public init(
        nodes: [String],
        edges: [(String, String)],
        width: Double = 800,
        height: Double = 600,
        fixed: String? = nil
    ) {
        self.nodeIds = nodes
        self.width = width
        self.height = height
        var indexOf: [String: Int] = [:]
        for (i, id) in nodes.enumerated() { indexOf[id] = i }
        self.edges = edges.compactMap { pair in
            guard let a = indexOf[pair.0], let b = indexOf[pair.1], a != b else { return nil }
            return (a, b)
        }
        self.fixedIndex = fixed.flatMap { indexOf[$0] }

        // 決定的な初期配置: IDのFNVハッシュで円周上に散らす
        var positions: [Point] = []
        for id in nodes {
            let h = Self.fnv1a(id)
            let angle = Double(h % 360) * .pi / 180
            let radius = 0.25 * min(width, height) * (0.5 + Double((h / 360) % 100) / 200)
            positions.append(Point(
                x: width / 2 + radius * cos(angle),
                y: height / 2 + radius * sin(angle)
            ))
        }
        if let fixedIndex = self.fixedIndex {
            positions[fixedIndex] = Point(x: width / 2, y: height / 2)
        }
        self.positions = positions

        self.k = nodes.isEmpty ? 1 : sqrt(width * height / Double(nodes.count))
        self.temperature = min(width, height) / 10
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// 反復を1回進める（呼び出し側がアニメーションのために繰り返す）
    public mutating func step() {
        let n = nodeIds.count
        guard n > 1 else { return }
        var displacement = [Point](repeating: Point(x: 0, y: 0), count: n)

        // 斥力（全ペア）
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = positions[i].x - positions[j].x
                var dy = positions[i].y - positions[j].y
                var distance = sqrt(dx * dx + dy * dy)
                if distance < 0.01 {
                    // 完全一致は決定的に微小オフセット
                    dx = 0.01 * Double(i - j)
                    dy = 0.01
                    distance = sqrt(dx * dx + dy * dy)
                }
                let force = k * k / distance
                displacement[i].x += dx / distance * force
                displacement[i].y += dy / distance * force
                displacement[j].x -= dx / distance * force
                displacement[j].y -= dy / distance * force
            }
        }

        // 引力（エッジ）
        for (a, b) in edges {
            let dx = positions[a].x - positions[b].x
            let dy = positions[a].y - positions[b].y
            let distance = max(sqrt(dx * dx + dy * dy), 0.01)
            let force = distance * distance / k
            displacement[a].x -= dx / distance * force
            displacement[a].y -= dy / distance * force
            displacement[b].x += dx / distance * force
            displacement[b].y += dy / distance * force
        }

        // 変位の適用（温度で制限、固定ノードは動かさない）
        for i in 0..<n {
            if i == fixedIndex { continue }
            let dx = displacement[i].x
            let dy = displacement[i].y
            let magnitude = max(sqrt(dx * dx + dy * dy), 0.01)
            let limited = min(magnitude, temperature)
            var x = positions[i].x + dx / magnitude * limited
            var y = positions[i].y + dy / magnitude * limited
            x = min(max(x, 0), width)
            y = min(max(y, 0), height)
            positions[i] = Point(x: x, y: y)
        }

        // 冷却
        temperature = max(temperature * 0.95, 0.5)
    }

    /// 指定回数反復して最終配置を返す
    public mutating func run(iterations: Int = 200) -> [Point] {
        for _ in 0..<iterations { step() }
        return positions
    }

    /// ノードサイズ: 被引用数の対数スケール（→ docs/08 5節）
    public static func nodeRadius(citationCount: Int, base: Double = 6, scale: Double = 4) -> Double {
        base + scale * log10(Double(max(citationCount, 0)) + 1)
    }
}
