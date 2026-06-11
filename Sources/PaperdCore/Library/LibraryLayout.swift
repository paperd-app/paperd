import Foundation

/// ライブラリディレクトリのパス規約（→ docs/03-library-layout.md）
public struct LibraryLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PaperdLibrary")
    }

    public var libraryJSON: URL { root.appendingPathComponent("library.json") }
    public var papersDir: URL { root.appendingPathComponent("papers") }
    public var indexDir: URL { root.appendingPathComponent("index") }
    public var databasePath: URL { indexDir.appendingPathComponent("library.sqlite") }

    public func paperDir(_ paperId: String) -> URL { papersDir.appendingPathComponent(paperId) }
    /// 部分書き込み対策: 取り込み完了まで .partial に書き、完了時にリネーム（→ docs/03 4節）
    public func partialPaperDir(_ paperId: String) -> URL { papersDir.appendingPathComponent("\(paperId).partial") }
    public func pdfPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("paper.pdf") }
    /// 補助ファイル（Supplementary等）のフォルダ。中身そのものが正本（→ docs/03 2節）
    public func supplementsDir(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("supplements") }
    public func markdownPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("paper.md") }
    /// 修正版Markdown（存在する場合これが有効Markdown → docs/05 5.2節）
    public func correctedMarkdownPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("paper.corrected.md") }
    /// 修正履歴
    public func correctionsLogPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("paper.corrections.json") }
    public func doclingJSONPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("paper.docling.json") }
    public func metaJSONPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("meta.json") }
    public func notesPath(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("notes.md") }
}

/// library.json
public struct LibraryDescriptor: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var libraryId: String
    public var createdAt: String

    public init(formatVersion: Int = 1, libraryId: String = UUID().uuidString.lowercased(), createdAt: String = PaperdDates.nowString()) {
        self.formatVersion = formatVersion
        self.libraryId = libraryId
        self.createdAt = createdAt
    }
}
