import Foundation

/// `paperd://` カスタムURLスキームの解釈（→ docs/01 6節）。
/// 外部起源の取り込みは即時実行せず、UIの確認ポップアップを経てenqueueする（→ docs/11 6節）。
public enum URLSchemeRequest: Equatable, Sendable {
    /// `paperd://import?url=` / `?arxiv=` / `?doi=` — 取り込み入力（確認後にjobsへ）
    case importInput(String)
    /// `paperd://paper/<uuid>` — 該当論文を開く（検索結果からのディープリンク用）
    case openPaper(id: String)

    public static func parse(_ url: URL) -> URLSchemeRequest? {
        guard url.scheme == "paperd" else { return nil }
        let host = url.host ?? ""
        switch host {
        case "import":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let items = components.queryItems
            else { return nil }
            for key in ["arxiv", "doi", "url"] {
                if let value = items.first(where: { $0.name == key })?.value, !value.isEmpty {
                    return .importInput(value)
                }
            }
            return nil
        case "paper":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !id.isEmpty else { return nil }
            return .openPaper(id: id)
        default:
            return nil
        }
    }
}
