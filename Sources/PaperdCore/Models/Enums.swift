import Foundation

/// papers.status（→ docs/02-data-model.md, docs/04-ingest-pipeline.md）
public enum PaperStatus: String, Codable, Sendable, CaseIterable {
    case stub
    case metadataOnly = "metadata_only"
    case pdfOnly = "pdf_only"
    case converting
    case indexed
    case failed
}

/// bibtexエントリタイプ（→ docs/02-data-model.md 2.1）
public enum BibtexType: String, Codable, Sendable {
    case article
    case inproceedings
    case misc
}

/// jobs.status
public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

/// jobs.kind
public enum JobKind: String, Codable, Sendable {
    case ingest
    /// チャンク・embedding・FTSの再構築（修正Markdown反映・モデル変更時）
    case reindex
    /// 高精度再変換（force_ocr + formula_enrichment → docs/05 5.1節）
    case reconvert
    case refetchCitations = "refetch_citations"
}

/// jobs.stage（→ docs/04-ingest-pipeline.md 1）
public enum JobStage: String, Codable, Sendable, CaseIterable {
    case resolve
    case fetch
    case convert
    case chunk
    case embed
    case index

    /// ステージの実行順。再開時は失敗ステージから実行する
    public var next: JobStage? {
        let all = JobStage.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

/// jobs.origin
public enum JobOrigin: String, Codable, Sendable {
    case app
    case mcp
    case urlScheme = "url_scheme"
}

/// citations.source
public enum CitationSource: String, Codable, Sendable {
    case s2
    case openalex
}

public enum PaperdDates {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    public static func nowString() -> String {
        string(from: Date())
    }
}
