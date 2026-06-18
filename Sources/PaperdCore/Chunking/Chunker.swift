import Foundation

/// セクション境界を尊重したチャンキング（→ docs/06-search-rag.md 2節）。
/// - 目安512トークン、オーバーラップ15%
/// - 参考文献・謝辞セクションは除外
/// - タイトル+アブストラクトは独立チャンクとして必ず索引化
/// - 表は1チャンクに収め、超過時のみ行単位で分割
public struct Chunker: Sendable {
    public var targetTokens: Int
    public var overlapRatio: Double

    public init(targetTokens: Int = 512, overlapRatio: Double = 0.15) {
        self.targetTokens = targetTokens
        self.overlapRatio = overlapRatio
    }

    public struct Piece: Equatable, Sendable {
        public var sectionPath: String?
        public var text: String
        public var tokenCount: Int

        public init(sectionPath: String?, text: String, tokenCount: Int) {
            self.sectionPath = sectionPath
            self.text = text
            self.tokenCount = tokenCount
        }
    }

    /// embeddingモデル非依存の近似。単語数と文字数/4の大きい方（CJK・長英単語の双方をカバー）
    public static func estimateTokens(_ text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let chars = text.count
        return max(words, chars / 4, 1)
    }

    static let excludedSectionPattern = /(?i)\b(references|bibliography|acknowledg)/

    /// 書誌からのタイトル+アブストラクトチャンク（→ docs/06 2節。metadata_only論文もsemantic検索にヒットさせる）
    public func titleAbstractPiece(title: String, abstract: String?) -> Piece {
        var text = title
        if let abstract, !abstract.isEmpty {
            text += "\n\n" + abstract
        }
        return Piece(sectionPath: "Title & Abstract", text: text, tokenCount: Self.estimateTokens(text))
    }

    /// DoclingItem列からの本文チャンク生成
    public func chunk(items: [DoclingItem]) -> [Piece] {
        var pieces: [Piece] = []
        var sectionStack: [(level: Int, title: String)] = []
        var buffer: [String] = []
        var bufferTokens = 0
        var currentPath: String? = nil

        func sectionPath() -> String? {
            sectionStack.isEmpty ? nil : sectionStack.map(\.title).joined(separator: " > ")
        }

        func isExcluded() -> Bool {
            guard let path = sectionPath() else { return false }
            return path.firstMatch(of: Self.excludedSectionPattern) != nil
        }

        func flush(carryOverlap: Bool) {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n\n")
            pieces.append(Piece(sectionPath: currentPath, text: text, tokenCount: Self.estimateTokens(text)))
            if carryOverlap {
                // 末尾から約15%のトークン分を次チャンク冒頭に引き継ぐ
                let overlapTokens = Int(Double(targetTokens) * overlapRatio)
                let tail = Self.tailText(of: text, approximateTokens: overlapTokens)
                buffer = tail.isEmpty ? [] : [tail]
                bufferTokens = Self.estimateTokens(tail)
            } else {
                buffer = []
                bufferTokens = 0
            }
        }

        for item in items {
            switch item.kind {
            case .title:
                continue  // タイトルはtitleAbstractPieceで扱う
            case .sectionHeader(let level):
                flush(carryOverlap: false)
                while let last = sectionStack.last, last.level >= level {
                    sectionStack.removeLast()
                }
                sectionStack.append((level, item.text))
                currentPath = sectionPath()
            case .table:
                guard !isExcluded() else { continue }
                flush(carryOverlap: false)
                pieces.append(contentsOf: tablePieces(item.text, sectionPath: sectionPath()))
            case .paragraph, .formula, .other:
                guard !isExcluded() else { continue }
                if currentPath != sectionPath() {
                    flush(carryOverlap: false)
                    currentPath = sectionPath()
                }
                let tokens = Self.estimateTokens(item.text)
                if bufferTokens + tokens > targetTokens && !buffer.isEmpty {
                    flush(carryOverlap: true)
                    currentPath = sectionPath()
                }
                buffer.append(item.text)
                bufferTokens += tokens
            }
        }
        flush(carryOverlap: false)
        // ハードキャップ: 段落境界で分割できない巨大ブロックを強制分割（→ docs/06 2節）
        return pieces.flatMap { Self.splitOversized($0, cap: hardCapTokens) }
    }

    /// 1チャンクの上限（targetTokensの1.25倍）。
    /// 数式エンリッチ由来の巨大な1行LaTeX等はembeddingが系列長の2乗で重くなるため強制分割する
    var hardCapTokens: Int { Int(Double(targetTokens) * 1.25) }

    static func splitOversized(_ piece: Piece, cap: Int) -> [Piece] {
        guard piece.tokenCount > cap else { return [piece] }
        // ピース自身のトークン密度（空白の多いLaTeXは単語数支配で密度が低い）から
        // 文字数ウィンドウを決める。安全側に0.9を掛けてcap超過の再発を防ぐ
        let charsPerToken = max(1.0, Double(piece.text.count) / Double(piece.tokenCount))
        let charLimit = max(Int(Double(cap) * charsPerToken * 0.9), 64)
        var result: [Piece] = []
        var remaining = Substring(piece.text)
        while !remaining.isEmpty {
            let part = String(remaining.prefix(charLimit))
            result.append(Piece(
                sectionPath: piece.sectionPath,
                text: part,
                tokenCount: estimateTokens(part)))
            remaining = remaining.dropFirst(part.count)
        }
        return result
    }

    /// 表は1チャンク。targetTokens超過時のみ行単位で分割（ヘッダ行は各分割に複製）
    func tablePieces(_ markdown: String, sectionPath: String?) -> [Piece] {
        let tokens = Self.estimateTokens(markdown)
        if tokens <= targetTokens {
            return [Piece(sectionPath: sectionPath, text: markdown, tokenCount: tokens)]
        }
        let lines = markdown.components(separatedBy: "\n")
        guard lines.count > 2 else {
            return [Piece(sectionPath: sectionPath, text: markdown, tokenCount: tokens)]
        }
        let header = Array(lines.prefix(2))
        var pieces: [Piece] = []
        var current = header
        var currentTokens = Self.estimateTokens(header.joined(separator: "\n"))
        for line in lines.dropFirst(2) {
            let lineTokens = Self.estimateTokens(line)
            if currentTokens + lineTokens > targetTokens && current.count > 2 {
                let text = current.joined(separator: "\n")
                pieces.append(Piece(sectionPath: sectionPath, text: text, tokenCount: Self.estimateTokens(text)))
                current = header
                currentTokens = Self.estimateTokens(header.joined(separator: "\n"))
            }
            current.append(line)
            currentTokens += lineTokens
        }
        if current.count > 2 {
            let text = current.joined(separator: "\n")
            pieces.append(Piece(sectionPath: sectionPath, text: text, tokenCount: Self.estimateTokens(text)))
        }
        return pieces
    }

    /// ノート（notes.md）のチャンク化（→ docs/06 2節「ノートもチャンク対象」）
    public func chunkNote(_ content: String) -> [Piece] {
        let items = [DoclingItem(kind: .paragraph, text: content)]
        let pieces = chunk(items: items)
        return pieces.map { Piece(sectionPath: "Notes", text: $0.text, tokenCount: $0.tokenCount) }
    }

    /// 文境界を考慮して末尾から約N トークン分のテキストを取り出す
    static func tailText(of text: String, approximateTokens: Int) -> String {
        guard approximateTokens > 0 else { return "" }
        let sentences = text.components(separatedBy: ". ")
        var collected: [String] = []
        var tokens = 0
        for sentence in sentences.reversed() {
            let t = estimateTokens(sentence)
            if tokens + t > approximateTokens && !collected.isEmpty { break }
            collected.insert(sentence, at: 0)
            tokens += t
            if tokens >= approximateTokens { break }
        }
        return collected.joined(separator: ". ")
    }
}
