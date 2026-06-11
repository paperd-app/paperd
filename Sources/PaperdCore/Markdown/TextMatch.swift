import Foundation

/// タイトル照合用のテキスト正規化と類似判定（→ docs/04 4節）。
/// 表記ゆれ（大文字小文字・記号・空白・ハイフネーション）に頑健な近似一致を提供する。
public enum TextMatch {
    /// 小文字化し、英数字以外を空白に潰して連続空白を畳む
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var result = ""
        var lastWasSpace = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                result.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 正規化のうえでの包含判定
    public static func containsNormalized(_ haystack: String, _ needle: String) -> Bool {
        let n = normalize(needle)
        guard !n.isEmpty else { return false }
        return normalize(haystack).contains(n)
    }

    /// 単語集合のJaccard類似度（0...1）
    public static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let setA = Set(normalize(a).split(separator: " "))
        let setB = Set(normalize(b).split(separator: " "))
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }
}
