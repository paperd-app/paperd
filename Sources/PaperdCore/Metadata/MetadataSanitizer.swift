import Foundation

/// 書誌テキストのサニタイズ（→ docs/04 3節）。
/// Crossref等が返すタイトル・誌名には生のJATS/MathML/HTMLマークアップが混入することがある
///（実例: 「…energies in<mml:math xmlns…」「Ba<sub><i>x</i></sub>Sr…」）。
public enum MetadataSanitizer {
    /// タグ除去（中身のテキストは残す）+ HTMLエンティティのデコード + 空白正規化
    public static func clean(_ raw: String) -> String {
        var text = raw
        // タグの直前で単語が密着するケース（in<mml:math>）に備え、タグをスペースに置換してから正規化…
        // ではなく、上付き/下付き（<sub>3</sub>）の密着は保ちたいのでタグは無置換で除去し、
        // タグ境界で英単語同士が密着する場合のみ後段の正規化に任せる
        text = text.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    /// 変更が必要か（fix-titles等の差分判定用）
    public static func needsCleaning(_ raw: String) -> Bool {
        clean(raw) != raw
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&nbsp;": " ", "&thinsp;": " ", "&ensp;": " ", "&emsp;": " ",
            "&ndash;": "–", "&mdash;": "—", "&minus;": "−", "&times;": "×", "&deg;": "°",
            "&prime;": "′", "&Prime;": "″", "&hellip;": "…",
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // 数値参照（10進・16進）
        while let match = result.range(of: #"&#x?[0-9A-Fa-f]+;"#, options: .regularExpression) {
            let entity = String(result[match])
            let body = entity.dropFirst(2).dropLast()  // "#x2026" or "#8230" → without & ;
            let scalar: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalar = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(body)
            }
            let replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            result = result.replacingCharacters(in: match, with: replacement)
        }
        return result
    }
}
