import Foundation

/// paper.md（Docling出力）表示用のブロックレベルMarkdownパーサ（→ docs/09 4節 Markdownタブ）。
/// 目的は変換結果の確認なので、CommonMark完全準拠ではなくDocling出力で使われる
/// 構成要素（見出し・段落・パイプテーブル・リスト・コードフェンス・画像プレースホルダ）を
/// 読める形に分解できれば十分。インライン装飾の解釈は表示側に委ねる。
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [String], ordered: Bool)
    case table(header: [String], rows: [[String]])
    case codeBlock(language: String?, code: String)
    /// `<!-- image -->`（v1では画像を抽出しない → docs/05 2節）
    case imagePlaceholder
    case horizontalRule
}

public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var tableLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems, ordered: listOrdered))
                listItems = []
            }
        }
        func flushTable() {
            if !tableLines.isEmpty {
                blocks.append(parseTable(tableLines))
                tableLines = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushTable()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // コードフェンス
            if inCode {
                if line.hasPrefix("```") {
                    blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                codeLanguage = line.dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                inCode = true
                continue
            }

            // 空行
            if line.isEmpty {
                flushAll()
                continue
            }

            // 画像プレースホルダ
            if line == "<!-- image -->" {
                flushAll()
                blocks.append(.imagePlaceholder)
                continue
            }

            // 見出し
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flushAll()
                    blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
                    continue
                }
            }

            // 水平線
            if line.count >= 3, Set(line).isSubset(of: ["-"]) || Set(line).isSubset(of: ["*"]) || Set(line).isSubset(of: ["_"]) {
                flushAll()
                blocks.append(.horizontalRule)
                continue
            }

            // パイプテーブル
            if line.hasPrefix("|") {
                flushParagraph()
                flushList()
                tableLines.append(line)
                continue
            }
            flushTable()

            // リスト項目
            if let item = listItem(line) {
                flushParagraph()
                if listItems.isEmpty { listOrdered = item.ordered }
                listItems.append(item.text)
                continue
            }
            flushList()

            // 段落
            paragraph.append(line)
        }

        if inCode {
            blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    static func listItem(_ line: String) -> (text: String, ordered: Bool)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (String(line.dropFirst(marker.count)), false)
        }
        if let match = line.firstMatch(of: /^(\d{1,3})\.\s+(.*)$/) {
            return (String(match.2), true)
        }
        return nil
    }

    /// `| a | b |` 行の集まりをテーブルへ。2行目が区切り行（`|---|:--:|`等）なら読み飛ばす
    static func parseTable(_ lines: [String]) -> MarkdownBlock {
        func cells(_ line: String) -> [String] {
            var trimmed = line
            if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
            if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
            // エスケープされたパイプを保護してから分割
            let sentinel = "\u{0}"
            return trimmed
                .replacingOccurrences(of: "\\|", with: sentinel)
                .components(separatedBy: "|")
                .map { $0.replacingOccurrences(of: sentinel, with: "|").trimmingCharacters(in: .whitespaces) }
        }
        func isSeparator(_ line: String) -> Bool {
            let allowed = Set("|-: ")
            return !line.isEmpty && line.allSatisfy { allowed.contains($0) } && line.contains("-")
        }

        let header = cells(lines[0])
        var rows: [[String]] = []
        for line in lines.dropFirst() {
            if isSeparator(line) { continue }
            rows.append(cells(line))
        }
        return .table(header: header, rows: rows)
    }
}
