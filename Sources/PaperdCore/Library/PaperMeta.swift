import Foundation

/// papers/{uuid}/meta.json — メタデータの正本（→ docs/03-library-layout.md 3節）
public struct PaperMeta: Codable, Equatable, Sendable {
    public struct AuthorEntry: Codable, Equatable, Sendable {
        public var displayName: String
        public var s2AuthorId: String?
        public var orcid: String?

        public init(displayName: String, s2AuthorId: String? = nil, orcid: String? = nil) {
            self.displayName = displayName
            self.s2AuthorId = s2AuthorId
            self.orcid = orcid
        }
    }

    public var formatVersion: Int
    public var id: String
    public var title: String
    public var abstract: String?
    public var year: Int?
    public var authors: [AuthorEntry]
    public var venue: String?
    public var bibtexType: String
    public var booktitle: String?
    public var journal: String?
    public var volume: String?
    public var number: String?
    public var pages: String?
    public var publisher: String?
    public var doi: String?
    public var arxivId: String?
    public var arxivVersion: String?
    public var s2PaperId: String?
    public var openalexId: String?
    public var url: String?
    public var bibtexCached: String?
    /// ユーザによるcitation key手動編集（DB列は追加しない → docs/02 2.2）
    public var citationKeyOverride: String?
    /// お気に入り（→ docs/02）。旧形式のmeta.jsonとの互換のためoptional（nil = false）
    public var isFavorite: Bool?
    /// 自著論文（→ docs/02）。同上
    public var isOwn: Bool?
    public var pdfHash: String?
    public var status: String
    public var addedAt: String
    public var updatedAt: String

    public init(
        formatVersion: Int = 1,
        id: String,
        title: String,
        abstract: String? = nil,
        year: Int? = nil,
        authors: [AuthorEntry] = [],
        venue: String? = nil,
        bibtexType: String = BibtexType.misc.rawValue,
        booktitle: String? = nil,
        journal: String? = nil,
        volume: String? = nil,
        number: String? = nil,
        pages: String? = nil,
        publisher: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        arxivVersion: String? = nil,
        s2PaperId: String? = nil,
        openalexId: String? = nil,
        url: String? = nil,
        bibtexCached: String? = nil,
        citationKeyOverride: String? = nil,
        isFavorite: Bool? = nil,
        isOwn: Bool? = nil,
        pdfHash: String? = nil,
        status: String = PaperStatus.metadataOnly.rawValue,
        addedAt: String = PaperdDates.nowString(),
        updatedAt: String = PaperdDates.nowString()
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.title = title
        self.abstract = abstract
        self.year = year
        self.authors = authors
        self.venue = venue
        self.bibtexType = bibtexType
        self.booktitle = booktitle
        self.journal = journal
        self.volume = volume
        self.number = number
        self.pages = pages
        self.publisher = publisher
        self.doi = doi
        self.arxivId = arxivId
        self.arxivVersion = arxivVersion
        self.s2PaperId = s2PaperId
        self.openalexId = openalexId
        self.url = url
        self.bibtexCached = bibtexCached
        self.citationKeyOverride = citationKeyOverride
        self.isFavorite = isFavorite
        self.isOwn = isOwn
        self.pdfHash = pdfHash
        self.status = status
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

extension PaperMeta {
    /// DB行（papers + 著者）からの構築
    public init(paper: Paper, authors: [Author], citationKeyOverride: String? = nil) {
        self.init(
            id: paper.id,
            title: paper.title,
            abstract: paper.abstract,
            year: paper.year,
            authors: authors.map { .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid) },
            venue: paper.venue,
            bibtexType: paper.bibtexType,
            booktitle: paper.booktitle,
            journal: paper.journal,
            volume: paper.volume,
            number: paper.number,
            pages: paper.pages,
            publisher: paper.publisher,
            doi: paper.doi,
            arxivId: paper.arxivId,
            arxivVersion: paper.arxivVersion,
            s2PaperId: paper.s2PaperId,
            openalexId: paper.openalexId,
            url: paper.url,
            bibtexCached: paper.bibtexCached,
            citationKeyOverride: citationKeyOverride,
            isFavorite: paper.isFavorite,
            isOwn: paper.isOwn,
            pdfHash: paper.pdfHash,
            status: paper.status,
            addedAt: paper.addedAt,
            updatedAt: paper.updatedAt
        )
    }

    /// meta.jsonからDB行を復元（インデックス再構築用 → docs/03 5節）
    public func toPaper() -> Paper {
        var paper = Paper(
            id: id,
            title: title,
            abstract: abstract,
            year: year,
            venue: venue,
            doi: doi,
            arxivId: arxivId,
            arxivVersion: arxivVersion,
            s2PaperId: s2PaperId,
            openalexId: openalexId,
            bibtexType: bibtexType,
            journal: journal,
            booktitle: booktitle,
            volume: volume,
            number: number,
            pages: pages,
            publisher: publisher,
            url: url,
            bibtexCached: bibtexCached,
            pdfHash: pdfHash,
            isFavorite: isFavorite ?? false,
            isOwn: isOwn ?? false,
            addedAt: addedAt,
            updatedAt: updatedAt
        )
        paper.status = status
        return paper
    }

    public static func decode(from data: Data) throws -> PaperMeta {
        try JSONDecoder().decode(PaperMeta.self, from: data)
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
