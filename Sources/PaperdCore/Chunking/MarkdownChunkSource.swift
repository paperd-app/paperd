import Foundation

/// 修正版Markdown（paper.corrected.md）からのチャンク生成用に、
/// MarkdownブロックをDoclingItem列へ変換する（→ docs/05 5.2節）。
/// セクション構造（見出し）と表はチャンカーの分割規則がそのまま適用される。
public enum MarkdownChunkSource {
    public static func items(fromMarkdown markdown: String) -> [DoclingItem] {
        MarkdownBlockParser.parse(markdown).compactMap { block in
            switch block {
            case .heading(let level, let text):
                return DoclingItem(kind: .sectionHeader(level: level), text: text)
            case .paragraph(let text):
                return DoclingItem(kind: .paragraph, text: text)
            case .list(let items, let ordered):
                let text = items.enumerated()
                    .map { ordered ? "\($0.offset + 1). \($0.element)" : "- \($0.element)" }
                    .joined(separator: "\n")
                return DoclingItem(kind: .paragraph, text: text)
            case .table(let header, let rows):
                var lines = ["| " + header.joined(separator: " | ") + " |"]
                lines.append("|" + Array(repeating: "---", count: header.count).joined(separator: "|") + "|")
                lines.append(contentsOf: rows.map { "| " + $0.joined(separator: " | ") + " |" })
                return DoclingItem(kind: .table, text: lines.joined(separator: "\n"))
            case .codeBlock(_, let code):
                return DoclingItem(kind: .paragraph, text: code)
            case .imagePlaceholder, .horizontalRule:
                return nil
            }
        }
    }
}
