import Foundation

/// 整形済み引用文の生成（→ docs/02 2.4節）。
/// 完全ローカル生成（外部APIなし）。主要エントリタイプに対する代表的整形のみ提供し、
/// CSLプロセッサの完全実装はv1スコープ外。出力はプレーンテキスト。
public enum CitationFormatter {
    public enum Style: String, CaseIterable, Identifiable, Sendable {
        case apa = "APA 7"
        case mla = "MLA 9"
        case chicago = "Chicago（著者-年）"
        case ieee = "IEEE"
        case vancouver = "Vancouver"
        public var id: String { rawValue }
    }

    struct Name {
        var family: String
        var given: String

        init(displayName: String) {
            let trimmed = displayName.trimmingCharacters(in: .whitespaces)
            if let comma = trimmed.firstIndex(of: ",") {
                family = String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
                given = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            } else {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                family = parts.last ?? trimmed
                given = parts.dropLast().joined(separator: " ")
            }
        }

        /// "A. M." のようなイニシャル（区切りつき）
        var initials: String {
            given.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { "\($0.prefix(1))." }
                .joined(separator: " ")
        }

        /// "AM" のようなイニシャル（Vancouver）
        var initialsCompact: String {
            given.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { String($0.prefix(1)) }
                .joined()
        }
    }

    public static func format(paper: Paper, authors: [Author], style: Style) -> String {
        let names = authors.map { Name(displayName: $0.displayName) }
        switch style {
        case .apa: return apa(paper, names)
        case .mla: return mla(paper, names)
        case .chicago: return chicago(paper, names)
        case .ieee: return ieee(paper, names)
        case .vancouver: return vancouver(paper, names)
        }
    }

    // MARK: - 共通部品

    /// 掲載誌情報（journal優先、なければbooktitle、なければvenue）
    static func container(_ p: Paper) -> String? {
        p.journal ?? p.booktitle ?? p.venue
    }

    static func isArxivOnly(_ p: Paper) -> Bool {
        p.arxivId != nil && container(p) == nil
    }

    static func doiURL(_ p: Paper) -> String? {
        if let doi = p.doi { return "https://doi.org/\(doi)" }
        if let arxivId = p.arxivId { return "https://arxiv.org/abs/\(arxivId)" }
        return nil
    }

    static func sentenceEnd(_ s: String) -> String {
        s.hasSuffix(".") || s.hasSuffix("?") || s.hasSuffix("!") ? s : s + "."
    }

    // MARK: - スタイル実装

    /// Vaswani, A., Shazeer, N., & Parmar, N. (2017). Title. Journal, 30, 1–10. https://doi.org/...
    static func apa(_ p: Paper, _ names: [Name]) -> String {
        var authorPart: String
        switch names.count {
        case 0: authorPart = ""
        case 1: authorPart = "\(names[0].family), \(names[0].initials)"
        default:
            // APA 7: 20名まで全員。それ以上は19名 + … + 最終著者（v1は21名以上を簡略化）
            let listed = names.count <= 20 ? names : Array(names.prefix(19)) + [names.last!]
            let formatted = listed.map { "\($0.family), \($0.initials)" }
            authorPart = formatted.dropLast().joined(separator: ", ")
                + (names.count > 20 ? ", … " : ", & ")
                + formatted.last!
        }
        var parts: [String] = []
        if !authorPart.isEmpty { parts.append(sentenceEnd(authorPart)) }
        parts.append("(\(p.year.map(String.init) ?? "n.d.")).")
        parts.append(sentenceEnd(p.title))
        if let container = container(p) {
            var pub = container
            if let volume = p.volume { pub += ", \(volume)" }
            if let number = p.number { pub += "(\(number))" }
            if let pages = p.pages { pub += ", \(pages)" }
            parts.append(sentenceEnd(pub))
        } else if p.arxivId != nil {
            parts.append("arXiv.")
        }
        if let url = doiURL(p) { parts.append(url) }
        return parts.joined(separator: " ")
    }

    /// Vaswani, Ashish, et al. "Title." Journal, vol. 30, 2017, pp. 1–10.
    static func mla(_ p: Paper, _ names: [Name]) -> String {
        var authorPart: String
        switch names.count {
        case 0: authorPart = ""
        case 1: authorPart = "\(names[0].family), \(names[0].given)"
        case 2: authorPart = "\(names[0].family), \(names[0].given), and \(names[1].given) \(names[1].family)"
        default: authorPart = "\(names[0].family), \(names[0].given), et al"
        }
        var parts: [String] = []
        if !authorPart.isEmpty { parts.append(sentenceEnd(authorPart)) }
        parts.append("\"\(sentenceEnd(p.title))\"")
        var pub: [String] = []
        if let container = container(p) { pub.append(container) }
        if let volume = p.volume { pub.append("vol. \(volume)") }
        if let number = p.number { pub.append("no. \(number)") }
        if let year = p.year { pub.append(String(year)) }
        if let pages = p.pages { pub.append("pp. \(pages)") }
        if isArxivOnly(p), let arxivId = p.arxivId { pub.append("arXiv:\(arxivId)") }
        if !pub.isEmpty { parts.append(sentenceEnd(pub.joined(separator: ", "))) }
        return parts.joined(separator: " ")
    }

    /// Vaswani, Ashish, Noam Shazeer, and Niki Parmar. 2017. "Title." Journal 30: 1–10.
    static func chicago(_ p: Paper, _ names: [Name]) -> String {
        var authorPart: String
        switch names.count {
        case 0: authorPart = ""
        case 1: authorPart = "\(names[0].family), \(names[0].given)"
        default:
            let rest = names.dropFirst().map { "\($0.given) \($0.family)" }
            authorPart = "\(names[0].family), \(names[0].given), "
                + rest.dropLast().joined(separator: ", ")
                + (rest.count > 1 ? ", and " : "and ") + rest.last!
        }
        var parts: [String] = []
        if !authorPart.isEmpty { parts.append(sentenceEnd(authorPart)) }
        if let year = p.year { parts.append("\(year).") }
        parts.append("\"\(sentenceEnd(p.title))\"")
        if let container = container(p) {
            var pub = container
            if let volume = p.volume { pub += " \(volume)" }
            if let pages = p.pages { pub += ": \(pages)" }
            parts.append(sentenceEnd(pub))
        } else if let arxivId = p.arxivId {
            parts.append("arXiv:\(arxivId).")
        }
        if let url = doiURL(p) { parts.append(sentenceEnd(url)) }
        return parts.joined(separator: " ")
    }

    /// A. Vaswani, N. Shazeer, and N. Parmar, "Title," Journal, vol. 30, pp. 1–10, 2017.
    static func ieee(_ p: Paper, _ names: [Name]) -> String {
        var authorPart: String
        let formatted = names.map { n in n.initials.isEmpty ? n.family : "\(n.initials) \(n.family)" }
        switch formatted.count {
        case 0: authorPart = ""
        case 1: authorPart = formatted[0]
        case 2...6: authorPart = formatted.dropLast().joined(separator: ", ") + ", and " + formatted.last!
        default: authorPart = formatted[0] + " et al."
        }
        var parts: [String] = []
        if !authorPart.isEmpty { parts.append(authorPart + ",") }
        parts.append("\"\(p.title),\"")
        var pub: [String] = []
        if let container = container(p) { pub.append(container) }
        if let volume = p.volume { pub.append("vol. \(volume)") }
        if let number = p.number { pub.append("no. \(number)") }
        if let pages = p.pages { pub.append("pp. \(pages)") }
        if isArxivOnly(p), let arxivId = p.arxivId { pub.append("arXiv preprint arXiv:\(arxivId)") }
        if let year = p.year { pub.append(String(year)) }
        return (parts + [pub.joined(separator: ", ")]).joined(separator: " ").trimmingCharacters(in: .whitespaces) + "."
    }

    /// Vaswani A, Shazeer N, Parmar N. Title. Journal. 2017;30:1–10.
    static func vancouver(_ p: Paper, _ names: [Name]) -> String {
        let formatted = names.map { n in n.initialsCompact.isEmpty ? n.family : "\(n.family) \(n.initialsCompact)" }
        let authorPart: String
        if formatted.isEmpty {
            authorPart = ""
        } else if formatted.count > 6 {
            authorPart = formatted.prefix(6).joined(separator: ", ") + ", et al"
        } else {
            authorPart = formatted.joined(separator: ", ")
        }
        var parts: [String] = []
        if !authorPart.isEmpty { parts.append(sentenceEnd(authorPart)) }
        parts.append(sentenceEnd(p.title))
        if let container = container(p) {
            var tail = sentenceEnd(container) + " "
            tail += p.year.map(String.init) ?? "n.d."
            if let volume = p.volume {
                tail += ";\(volume)"
                if let pages = p.pages { tail += ":\(pages)" }
            } else if let pages = p.pages {
                tail += ":\(pages)"
            }
            parts.append(tail + ".")
        } else {
            if let arxivId = p.arxivId { parts.append("arXiv:\(arxivId).") }
            if let year = p.year { parts.append("\(year).") }
        }
        return parts.joined(separator: " ")
    }
}
