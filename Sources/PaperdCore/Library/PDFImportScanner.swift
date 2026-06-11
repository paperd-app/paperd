import Foundation

/// 取り込み対象PDFの列挙（→ docs/09 7節）。
/// ファイル/フォルダ混在の入力を受け、フォルダは**再帰的に走査**してPDFを集める。
public enum PDFImportScanner {
    /// - Returns: 重複除去・パス順ソート済みのPDFファイルURL
    public static func pdfs(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        // 重複判定はシンボリックリンク解決後のパスで行う
        //（/var と /private/var の表記差で同一ファイルが二重になるのを防ぐ）
        func add(_ url: URL) {
            let key = url.resolvingSymlinksInPath().path
            if seen.insert(key).inserted { found.append(url) }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let file as URL in enumerator where file.pathExtension.lowercased() == "pdf" {
                    add(file)
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                add(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
