import Foundation

/// PDF→Markdown変換の文字化け兆候のヒューリスティック検知（→ docs/05 4.1節）。
/// 機械的に検出できるクラスのみを対象とし、意味的な誤り（10³→103等）は
/// Markdownタブの目視とMCP修正に委ねる。
public struct ConversionQualityChecker: Sendable {
    public struct Warning: Equatable, Sendable {
        public var kind: Kind
        public var sample: String
        public var count: Int

        public enum Kind: String, Equatable, Sendable {
            /// (cid:NNN) — フォントのUnicode対応欠落
            case cidReference = "cid_reference"
            /// U+FFFD置換文字
            case replacementChar = "replacement_char"
            /// 私用領域（PUA）文字
            case privateUseArea = "private_use_area"
            /// 分数・記号グリフの不自然な出現（ToUnicode CMap誤対応の兆候）
            case suspiciousFraction = "suspicious_fraction"
            /// 未正規化の合字（ﬁ ﬂ 等）
            case unnormalizedLigature = "unnormalized_ligature"
            /// ラテン文字主体の文書中のキリル同形字（OCRの混同。例: PbTiO3 → РЬТіОз）
            case cyrillicHomoglyph = "cyrillic_homoglyph"
        }
    }

    public init() {}

    static let fractionChars: Set<Character> = ["¼", "½", "¾", "⅓", "⅔", "⅕", "⅖", "⅗", "⅘", "⅙", "⅚", "⅛", "⅜", "⅝", "⅞"]
    static let ligatureChars: Set<Character> = ["ﬁ", "ﬂ", "ﬀ", "ﬃ", "ﬄ", "ﬅ", "ﬆ"]

    public func scan(_ markdown: String) -> [Warning] {
        var warnings: [Warning] = []

        // (cid:NNN)
        let cidMatches = markdown.matches(of: /\(cid:\d+\)/)
        if !cidMatches.isEmpty {
            warnings.append(Warning(
                kind: .cidReference,
                sample: String(cidMatches[0].0),
                count: cidMatches.count
            ))
        }

        var replacementCount = 0
        var puaCount = 0
        var puaSample: Character?
        var fractionCount = 0
        var fractionSample: Character?
        var ligatureCount = 0
        var ligatureSample: Character?
        var cyrillicCount = 0
        var cyrillicSample: Character?
        var latinCount = 0

        for ch in markdown {
            if ch == "\u{FFFD}" {
                replacementCount += 1
            } else if let scalar = ch.unicodeScalars.first, (0xE000...0xF8FF).contains(scalar.value) {
                puaCount += 1
                if puaSample == nil { puaSample = ch }
            } else if Self.fractionChars.contains(ch) {
                fractionCount += 1
                if fractionSample == nil { fractionSample = ch }
            } else if Self.ligatureChars.contains(ch) {
                ligatureCount += 1
                if ligatureSample == nil { ligatureSample = ch }
            } else if let scalar = ch.unicodeScalars.first, (0x0400...0x04FF).contains(scalar.value) {
                cyrillicCount += 1
                if cyrillicSample == nil { cyrillicSample = ch }
            } else if ch.isLetter, ch.isASCII {
                latinCount += 1
            }
        }

        if replacementCount > 0 {
            warnings.append(Warning(kind: .replacementChar, sample: "\u{FFFD}", count: replacementCount))
        }
        if puaCount > 0 {
            warnings.append(Warning(kind: .privateUseArea, sample: String(puaSample!), count: puaCount))
        }
        // 分数グリフは正当な用例もあるため、複数回出現する場合のみ警告
        if fractionCount >= 2 {
            warnings.append(Warning(kind: .suspiciousFraction, sample: String(fractionSample!), count: fractionCount))
        }
        if ligatureCount > 0 {
            warnings.append(Warning(kind: .unnormalizedLigature, sample: String(ligatureSample!), count: ligatureCount))
        }
        // ラテン文字主体（>90%）の文書に少数のキリル文字が混じる場合はOCRの同形字混同を疑う。
        // ロシア語文献等（キリル主体）は対象外
        if cyrillicCount > 0, latinCount > 0,
           Double(cyrillicCount) / Double(cyrillicCount + latinCount) < 0.1 {
            warnings.append(Warning(kind: .cyrillicHomoglyph, sample: String(cyrillicSample!), count: cyrillicCount))
        }
        return warnings
    }

    /// papers.conversion_warningsに保存する総警告数（個々の出現数の合計）
    public func totalWarningCount(_ markdown: String) -> Int {
        scan(markdown).reduce(0) { $0 + $1.count }
    }
}
