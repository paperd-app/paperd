import Foundation

/// paper.docling.json（DoclingDocument）から読み取った本文要素。
/// チャンク再生成・インデックス再構築に使う（→ docs/05 2節）。
public struct DoclingItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case title
        case sectionHeader(level: Int)
        case paragraph
        case table
        case formula
        case other
    }

    public var kind: Kind
    public var text: String
    public var page: Int?

    public init(kind: Kind, text: String, page: Int? = nil) {
        self.kind = kind
        self.text = text
        self.page = page
    }
}

public enum DoclingParseError: Error {
    case invalidJSON
}

/// DoclingDocument JSONの最小パーサ。
/// `texts` / `tables` 配列を読み、(ページ番号, bboxのtop降順)で読み順を近似する。
/// 2段組レイアウトでは近似となるが、チャンクのセクション帰属には十分（v1の割り切り）。
public enum DoclingParser {
    public static func parse(data: Data) throws -> [DoclingItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DoclingParseError.invalidJSON
        }

        struct Positioned {
            var item: DoclingItem
            var page: Int
            var top: Double
            var seq: Int
        }
        var positioned: [Positioned] = []
        var seq = 0

        if let texts = json["texts"] as? [[String: Any]] {
            for t in texts {
                guard let text = t["text"] as? String, !text.isEmpty else { continue }
                let label = (t["label"] as? String) ?? "text"
                let kind: DoclingItem.Kind
                switch label {
                case "title":
                    kind = .title
                case "section_header":
                    kind = .sectionHeader(level: (t["level"] as? Int) ?? 1)
                case "text", "paragraph", "list_item", "caption", "footnote":
                    kind = .paragraph
                case "formula":
                    kind = .formula
                default:
                    kind = .other
                }
                let (page, top) = provenance(of: t)
                positioned.append(.init(item: DoclingItem(kind: kind, text: text, page: page), page: page ?? 0, top: top, seq: seq))
                seq += 1
            }
        }

        if let tables = json["tables"] as? [[String: Any]] {
            for t in tables {
                guard let markdown = tableMarkdown(t), !markdown.isEmpty else { continue }
                let (page, top) = provenance(of: t)
                positioned.append(.init(item: DoclingItem(kind: .table, text: markdown, page: page), page: page ?? 0, top: top, seq: seq))
                seq += 1
            }
        }

        // 読み順の近似: ページ → bbox top（座標原点は左下なのでtop降順）→ 元の出現順
        positioned.sort { a, b in
            if a.page != b.page { return a.page < b.page }
            if a.top != b.top { return a.top > b.top }
            return a.seq < b.seq
        }
        return positioned.map(\.item)
    }

    /// タイトル候補の抽出。`title` ラベルを優先し、なければ1ページ目の
    /// 見出しらしい要素（一定長以上のsection_header）にフォールバックする。
    /// 全大文字でない見出しを優先する: 誌名ランニングヘッダ
    /// （例: "THEORETICAL AND MATHEMATICAL PHYSICS"）が全大文字見出しとして
    /// 本タイトルより先に抽出されるケースの誤認識対策（→ docs/04 4節）。
    public static func titleCandidate(items: [DoclingItem]) -> String? {
        if let title = items.first(where: { $0.kind == .title })?.text, !title.isEmpty {
            return title
        }
        let headers = items.filter { item in
            guard case .sectionHeader = item.kind else { return false }
            guard item.page == nil || item.page == 1 else { return false }
            return item.text.count >= 20
        }
        return (headers.first { !isAllCaps($0.text) } ?? headers.first)?.text
    }

    static func isAllCaps(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    static func provenance(of item: [String: Any]) -> (page: Int?, top: Double) {
        guard let prov = (item["prov"] as? [[String: Any]])?.first else { return (nil, 0) }
        let page = prov["page_no"] as? Int
        let top = ((prov["bbox"] as? [String: Any])?["t"] as? Double) ?? 0
        return (page, top)
    }

    /// tables[].data.grid（セルの2次元配列）→ Markdownテーブル
    static func tableMarkdown(_ table: [String: Any]) -> String? {
        guard let data = table["data"] as? [String: Any],
              let grid = data["grid"] as? [[[String: Any]]], !grid.isEmpty
        else { return nil }
        var lines: [String] = []
        for (rowIndex, row) in grid.enumerated() {
            let cells = row.map { ($0["text"] as? String ?? "").replacingOccurrences(of: "|", with: "\\|") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if rowIndex == 0 {
                lines.append("|" + Array(repeating: "---", count: row.count).joined(separator: "|") + "|")
            }
        }
        return lines.joined(separator: "\n")
    }
}
