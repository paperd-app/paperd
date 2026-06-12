import Foundation

/// メタデータ解決の結果（→ docs/04-ingest-pipeline.md 3節）
public struct ResolvedMetadata: Equatable, Sendable {
    public struct AuthorInfo: Equatable, Sendable {
        public var displayName: String
        public var s2AuthorId: String?
        public var orcid: String?

        public init(displayName: String, s2AuthorId: String? = nil, orcid: String? = nil) {
            self.displayName = displayName
            self.s2AuthorId = s2AuthorId
            self.orcid = orcid
        }
    }

    public var title: String
    public var abstract: String?
    public var year: Int?
    public var venue: String?
    public var doi: String?
    public var arxivId: String?
    public var arxivVersion: String?
    public var s2PaperId: String?
    public var openalexId: String?
    public var bibtexType: String
    public var journal: String?
    public var booktitle: String?
    public var volume: String?
    public var number: String?
    public var pages: String?
    public var publisher: String?
    public var url: String?
    public var bibtexCached: String?
    public var authors: [AuthorInfo]
    /// arXivのPDFダウンロードURL等、fetchステージのヒント
    public var pdfURL: String?

    public init(
        title: String,
        abstract: String? = nil,
        year: Int? = nil,
        venue: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        arxivVersion: String? = nil,
        s2PaperId: String? = nil,
        openalexId: String? = nil,
        bibtexType: String = BibtexType.misc.rawValue,
        journal: String? = nil,
        booktitle: String? = nil,
        volume: String? = nil,
        number: String? = nil,
        pages: String? = nil,
        publisher: String? = nil,
        url: String? = nil,
        bibtexCached: String? = nil,
        authors: [AuthorInfo] = [],
        pdfURL: String? = nil
    ) {
        self.title = title
        self.abstract = abstract
        self.year = year
        self.venue = venue
        self.doi = doi
        self.arxivId = arxivId
        self.arxivVersion = arxivVersion
        self.s2PaperId = s2PaperId
        self.openalexId = openalexId
        self.bibtexType = bibtexType
        self.journal = journal
        self.booktitle = booktitle
        self.volume = volume
        self.number = number
        self.pages = pages
        self.publisher = publisher
        self.url = url
        self.bibtexCached = bibtexCached
        self.authors = authors
        self.pdfURL = pdfURL
    }

    /// 既存のPaper行へ解決結果を適用する（既存値が空のフィールドのみ補完）
    public func apply(to paper: inout Paper) {
        // タイトル・誌名はマークアップ混入があるためサニタイズして適用（→ docs/04 3節）
        paper.title = MetadataSanitizer.clean(title)
        if let abstract { paper.abstract = MetadataSanitizer.clean(abstract) }
        if let year { paper.year = year }
        if let venue { paper.venue = MetadataSanitizer.clean(venue) }
        if let doi { paper.doi = doi }
        if let arxivId { paper.arxivId = arxivId }
        if let arxivVersion { paper.arxivVersion = arxivVersion }
        if let s2PaperId { paper.s2PaperId = s2PaperId }
        if let openalexId { paper.openalexId = openalexId }
        paper.bibtexType = bibtexType
        if let journal { paper.journal = MetadataSanitizer.clean(journal) }
        if let booktitle { paper.booktitle = MetadataSanitizer.clean(booktitle) }
        if let volume { paper.volume = volume }
        if let number { paper.number = number }
        if let pages { paper.pages = pages }
        if let publisher { paper.publisher = publisher }
        if let url { paper.url = url }
        if let bibtexCached { paper.bibtexCached = bibtexCached }
    }
}

public enum MetadataError: Error, Equatable, CustomStringConvertible {
    case notFound(source: String, identifier: String)
    case network(source: String, message: String)
    case parse(source: String, message: String)

    public var description: String {
        switch self {
        case .notFound(let source, let id): return "\(source): \(id) not found"
        case .network(let source, let message): return "\(source): network error (\(message))"
        case .parse(let source, let message): return "\(source): response parse error (\(message))"
        }
    }
}
