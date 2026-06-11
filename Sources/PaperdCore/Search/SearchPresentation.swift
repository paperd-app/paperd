import Foundation

/// 検索結果の表示支援（→ docs/09 6節）。UIに依存しない範囲計算のみを担う。
public enum SearchPresentation {
    /// snippet中のクエリ語の出現範囲（大文字小文字・ダイアクリティカル無視、重複はマージ済み）。
    /// keyword / hybridヒットのハイライト用。semantic一致には語の対応が存在しないため適用しない。
    public static func termRanges(query: String, in text: String) -> [Range<String.Index>] {
        let terms = Set(
            TextMatch.normalize(query).split(separator: " ").map(String.init)
        ).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        for term in terms {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                ranges.append(found)
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return merge(ranges)
    }

    /// 重なり・隣接する範囲を統合する
    static func merge(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<String.Index>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

extension MarkdownBlockParser {
    /// section_path（例 "3. Method > 3.2 Training"）に対応する見出しブロックのインデックス。
    /// 検索ヒットからMarkdownタブの該当セクションへスクロールするために使う（→ docs/09 6節）。
    /// 末尾のセクション名と正規化一致する最初の見出しを返す。
    public static func blockIndex(forSectionPath path: String, in blocks: [MarkdownBlock]) -> Int? {
        let target = TextMatch.normalize(path.components(separatedBy: " > ").last ?? path)
        guard !target.isEmpty else { return nil }
        return blocks.firstIndex { block in
            if case .heading(_, let text) = block {
                return TextMatch.normalize(text) == target
            }
            return false
        }
    }
}
