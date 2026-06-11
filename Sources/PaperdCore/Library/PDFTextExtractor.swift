import Foundation
import PDFKit

/// PDFテキスト層の直接読み取り（→ docs/04 4節 先行解決）。
/// Doclingを介さずにミリ秒オーダーで先頭ページのテキストを得る。
/// テキスト層がないPDF（スキャン）はnil → 呼び出し側がconvert先行フローへフォールバックする。
public enum PDFTextExtractor {
    /// 先頭ページのテキスト（OCRなし）。テキスト層がなければnil
    public static func headText(of url: URL, pages: Int = 2, maxLength: Int = 8000) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        for index in 0..<min(pages, document.pageCount) {
            if let pageText = document.page(at: index)?.string {
                text += pageText + "\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxLength))
    }
}
