import Foundation
import Testing
import PaperdCore

/// PDFファイル/フォルダの列挙（→ docs/09 7節）
@Suite("PDFImportScanner")
struct PDFImportScannerTests {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("%PDF a".utf8).write(to: root.appendingPathComponent("a.pdf"))
        try Data("%PDF b".utf8).write(to: root.appendingPathComponent("B.PDF"))  // 大文字拡張子
        try Data("not pdf".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("%PDF c".utf8).write(to: sub.appendingPathComponent("c.pdf"))
        try Data("%PDF h".utf8).write(to: root.appendingPathComponent(".hidden.pdf"))  // 隠しファイル
        return root
    }

    @Test("フォルダの再帰走査: PDFのみ・隠しファイル除外・大文字拡張子対応")
    func recursiveFolderScan() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfs = PDFImportScanner.pdfs(in: [root])
        #expect(pdfs.map(\.lastPathComponent) == ["B.PDF", "a.pdf", "c.pdf"])
    }

    @Test("ファイル直接指定とフォルダの混在・重複除去")
    func mixedInputAndDedup() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let single = root.appendingPathComponent("a.pdf")
        // 同じPDFがフォルダ経由とファイル直接指定で重複しても1回だけ
        let pdfs = PDFImportScanner.pdfs(in: [single, root])
        #expect(pdfs.filter { $0.lastPathComponent == "a.pdf" }.count == 1)
        #expect(pdfs.count == 3)
    }

    @Test("非PDFファイル・存在しないパスは無視")
    func ignoresInvalidInputs() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfs = PDFImportScanner.pdfs(in: [
            root.appendingPathComponent("notes.txt"),
            URL(fileURLWithPath: "/nonexistent/path"),
        ])
        #expect(pdfs.isEmpty)
    }
}
