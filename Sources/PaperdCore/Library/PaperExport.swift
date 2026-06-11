import Foundation

/// PDF書き出し時のファイル名生成（→ docs/09 4節）。
/// ライブラリ内部の `paper.pdf` を人に送れる体裁の名前にする:
/// `{第一著者の姓}[ and {第二著者の姓} | et al.] {年} - {タイトル}.pdf`
public enum PaperExport {
    public static func filename(paper: Paper, authors: [String], maxTitleLength: Int = 80) -> String {
        var parts: [String] = []

        let familyNames = authors.map { BibtexGenerator.familyName(of: $0) }.filter { !$0.isEmpty }
        switch familyNames.count {
        case 0:
            break
        case 1:
            parts.append(familyNames[0])
        case 2:
            parts.append("\(familyNames[0]) and \(familyNames[1])")
        default:
            parts.append("\(familyNames[0]) et al.")
        }
        if let year = paper.year {
            parts.append(String(year))
        }

        var title = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > maxTitleLength {
            title = String(title.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
        }

        let head = parts.joined(separator: " ")
        let base = head.isEmpty ? title : "\(head) - \(title)"
        let sanitized = sanitize(base)
        return (sanitized.isEmpty ? "paper" : sanitized) + ".pdf"
    }

    /// ファイル名に使えない・問題を起こしやすい文字の除去
    static func sanitize(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "/", "\\", ":":
                result.append("-")
            case "\"", "?", "*", "<", ">", "|", "\0":
                continue
            case "\n", "\r", "\t":
                result.append(" ")
            default:
                result.append(ch)
            }
        }
        // 連続空白を畳み、先頭のドット（隠しファイル化）を避ける
        let collapsed = result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.hasPrefix(".") ? String(collapsed.drop(while: { $0 == "." })) : collapsed
    }
}
