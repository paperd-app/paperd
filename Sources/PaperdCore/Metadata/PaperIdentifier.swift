import Foundation

/// 取り込み入力の種別（→ docs/04-ingest-pipeline.md 2節）
public enum PaperIdentifier: Equatable, Sendable {
    case arxiv(id: String, version: String?)
    case doi(String)
    case localPDF(path: String)
    case directPDFURL(String)
    case webpage(String)

    /// 入力ダイアログのクリップボードプリフィル判定（→ docs/09 7節）。
    /// URL / DOI / arXiv IDとして解釈できる文字列のみ対象（ローカルパスは除外）
    public static func isImportable(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 500, !trimmed.contains("\n") else { return false }
        switch parse(trimmed) {
        case .arxiv, .doi, .webpage, .directPDFURL: return true
        case .localPDF, nil: return false
        }
    }

    /// 入力文字列から種別を自動判別する（UIの＋ダイアログ / MCP add_paper / URLスキーム共通）
    public static func parse(_ input: String) -> PaperIdentifier? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return parseURL(trimmed)
        }
        if let arxiv = parseArxivID(trimmed) { return .arxiv(id: arxiv.id, version: arxiv.version) }
        if let doi = parseDOI(trimmed) { return .doi(doi) }
        if trimmed.lowercased().hasSuffix(".pdf"), FileManager.default.fileExists(atPath: trimmed) {
            return .localPDF(path: trimmed)
        }
        return nil
    }

    /// URLからarXiv ID / DOIを抽出して帰着させる（→ docs/04 2節, docs/11 4節）
    public static func parseURL(_ urlString: String) -> PaperIdentifier? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let path = url.path

        if host.hasSuffix("arxiv.org") {
            // arxiv.org/abs/{id} / arxiv.org/pdf/{id}(.pdf)?
            let components = path.split(separator: "/").map(String.init)
            if components.count >= 2, components[0] == "abs" || components[0] == "pdf" {
                var idPart = components[1...].joined(separator: "/")
                if idPart.lowercased().hasSuffix(".pdf") { idPart = String(idPart.dropLast(4)) }
                if let arxiv = parseArxivID(idPart) {
                    return .arxiv(id: arxiv.id, version: arxiv.version)
                }
            }
        }
        if host.hasSuffix("doi.org") {
            let doiPart = String(path.dropFirst())  // 先頭の"/"
            if let doi = parseDOI(doiPart) { return .doi(doi) }
        }
        // URL中のDOIパターン
        if let doi = extractDOI(from: urlString) { return .doi(doi) }
        if path.lowercased().hasSuffix(".pdf") { return .directPDFURL(urlString) }
        return .webpage(urlString)
    }

    // MARK: - arXiv ID

    /// 新形式 `2403.01234v2` / 旧形式 `cs.CL/0301001`。バージョン番号は分離する（→ docs/02）
    public static func parseArxivID(_ s: String) -> (id: String, version: String?)? {
        var input = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["arXiv:", "arxiv:"] where input.hasPrefix(prefix) {
            input = String(input.dropFirst(prefix.count))
        }
        let newStyle = /^(\d{4}\.\d{4,5})(v\d+)?$/
        if let match = input.wholeMatch(of: newStyle) {
            return (String(match.1), match.2.map(String.init))
        }
        let oldStyle = /^([a-z-]+(?:\.[A-Z]{2})?\/\d{7})(v\d+)?$/
        if let match = input.wholeMatch(of: oldStyle) {
            return (String(match.1), match.2.map(String.init))
        }
        return nil
    }

    // MARK: - DOI

    public static func parseDOI(_ s: String) -> String? {
        var input = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["doi:", "DOI:", "https://doi.org/", "http://doi.org/"] where input.hasPrefix(prefix) {
            input = String(input.dropFirst(prefix.count))
        }
        let pattern = /^10\.\d{4,9}\/\S+$/
        guard input.wholeMatch(of: pattern) != nil else { return nil }
        return trimDOIPunctuation(input)
    }

    /// 任意文字列からのDOIパターン抽出（`10.\d{4,}/...`）
    public static func extractDOI(from s: String) -> String? {
        let pattern = /10\.\d{4,9}\/[^\s"'<>]+/
        guard let match = s.firstMatch(of: pattern) else { return nil }
        return trimDOIPunctuation(String(match.0))
    }

    /// 任意文字列からのarXiv ID抽出（`arXiv:2403.01234v2` 形式の刷り込み → docs/04 4節）
    public static func extractArxivID(from s: String) -> (id: String, version: String?)? {
        let pattern = /arXiv:\s*(\d{4}\.\d{4,5})(v\d+)?/
        guard let match = s.firstMatch(of: pattern) else { return nil }
        return (String(match.1), match.2.map(String.init))
    }

    private static func trimDOIPunctuation(_ doi: String) -> String {
        var result = doi
        while let last = result.last, ".,;)]".contains(last) {
            result = String(result.dropLast())
        }
        return result
    }
}
