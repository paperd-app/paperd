import Foundation

/// 変換ミスのパッチ修正と paper.corrected.md オーバーレイの管理（→ docs/05 5.2節, docs/07 2.6節）。
/// - Docling出力（paper.md）は不変。修正は corrected.md に保存
/// - 各パッチのfindは有効Markdown中に正確に1回出現することを検証（全件検証後に一括適用）
/// - 履歴は paper.corrections.json に追記
public struct FulltextCorrector: Sendable {
    public let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    public struct Patch: Codable, Equatable, Sendable {
        public var find: String
        public var replace: String

        public init(find: String, replace: String) {
            self.find = find
            self.replace = replace
        }
    }

    public struct CorrectionEntry: Codable, Equatable, Sendable {
        public var appliedAt: String
        public var patches: [Patch]
        public var note: String?
    }

    public struct CorrectionsLog: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var entries: [CorrectionEntry]

        public init(formatVersion: Int = 1, entries: [CorrectionEntry] = []) {
            self.formatVersion = formatVersion
            self.entries = entries
        }
    }

    public enum PatchError: Error, Equatable, CustomStringConvertible {
        case markdownNotFound(paperId: String)
        case emptyPatches
        case findNotFound(index: Int, find: String)
        case findAmbiguous(index: Int, find: String, occurrences: Int)

        public var description: String {
            switch self {
            case .markdownNotFound(let id):
                return "Paper \(id) has no Markdown yet (conversion pending)"
            case .emptyPatches:
                return "patches is empty"
            case .findNotFound(let index, let find):
                return "Patch \(index): find \"\(find.prefix(80))\" not found in the text. Check the current text with get_fulltext"
            case .findAmbiguous(let index, let find, let occurrences):
                return "Patch \(index): find \"\(find.prefix(80))\" occurs \(occurrences) times in the text. Include surrounding context to make it unique"
            }
        }
    }

    /// 有効Markdown（corrected.md優先、なければpaper.md → docs/05 5.2節）
    /// Markdownから見出しベースでセクションを抽出する（→ docs/07 2.3節）。
    /// sectionは "3. Method > 3.2 Training" のようなsection_path形式も受け付け、最後の要素で照合する。
    /// 一致見出しから同レベル以上の次見出しまでを返す。見つからなければnil（呼び出し側がチャンクへフォールバック）
    public static func extractSection(markdown: String, section: String) -> String? {
        let target = (section.components(separatedBy: ">").last ?? section)
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let lines = markdown.components(separatedBy: "\n")
        var startIndex: Int?
        var startLevel = 0
        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("#") else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if let start = startIndex {
                if level <= startLevel {
                    return lines[start..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if TextMatch.containsNormalized(heading, target) || TextMatch.containsNormalized(target, heading) {
                startIndex = i
                startLevel = level
            }
        }
        guard let start = startIndex else { return nil }
        return lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func effectiveMarkdown(paperId: String) -> String? {
        let fm = FileManager.default
        for path in [layout.correctedMarkdownPath(paperId), layout.markdownPath(paperId)] {
            if let data = fm.contents(atPath: path.path) {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    public func hasCorrections(paperId: String) -> Bool {
        FileManager.default.fileExists(atPath: layout.correctedMarkdownPath(paperId).path)
    }

    /// パッチを検証して一括適用する。
    /// - Returns: 適用後の本文
    @discardableResult
    public func apply(paperId: String, patches: [Patch], note: String? = nil) throws -> String {
        guard !patches.isEmpty else { throw PatchError.emptyPatches }
        guard var text = effectiveMarkdown(paperId: paperId) else {
            throw PatchError.markdownNotFound(paperId: paperId)
        }

        // 全件検証（部分適用をしない）。逐次適用なので、各パッチは直前のパッチ適用後の本文に対して検証する
        var working = text
        for (index, patch) in patches.enumerated() {
            let occurrences = Self.occurrenceCount(of: patch.find, in: working)
            if occurrences == 0 {
                throw PatchError.findNotFound(index: index, find: patch.find)
            }
            if occurrences > 1 {
                throw PatchError.findAmbiguous(index: index, find: patch.find, occurrences: occurrences)
            }
            working = working.replacingOccurrences(of: patch.find, with: patch.replace)
        }
        text = working

        try text.data(using: .utf8)!.write(to: layout.correctedMarkdownPath(paperId), options: .atomic)
        try appendLog(paperId: paperId, entry: CorrectionEntry(
            appliedAt: PaperdDates.nowString(), patches: patches, note: note))
        return text
    }

    /// 修正の取り消し（corrected.mdの削除 = Docling出力へ戻る）。
    /// 再変換による破棄の場合はnoteで履歴に理由を残す（→ docs/05 5.1節）
    public func revert(paperId: String, note: String = "reverted") throws {
        try? FileManager.default.removeItem(at: layout.correctedMarkdownPath(paperId))
        try appendLog(paperId: paperId, entry: CorrectionEntry(
            appliedAt: PaperdDates.nowString(), patches: [], note: note))
    }

    public func log(paperId: String) -> CorrectionsLog {
        guard let data = FileManager.default.contents(atPath: layout.correctionsLogPath(paperId).path),
              let log = try? JSONDecoder().decode(CorrectionsLog.self, from: data)
        else { return CorrectionsLog() }
        return log
    }

    func appendLog(paperId: String, entry: CorrectionEntry) throws {
        var current = log(paperId: paperId)
        current.entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(current).write(to: layout.correctionsLogPath(paperId), options: .atomic)
    }

    static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
