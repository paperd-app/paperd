import Foundation
import GRDB

/// papers行（→ docs/02-data-model.md）
public struct Paper: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "papers"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
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
    public var pdfHash: String?
    /// 変換品質検知の警告数（→ docs/05 4.1節）。nil=未計算。paper.mdから再計算可能
    public var conversionWarnings: Int?
    /// お気に入り（正本はmeta.json → docs/02, 03）
    public var isFavorite: Bool
    /// 自著論文（正本はmeta.json → docs/02, 03）
    public var isOwn: Bool
    public var status: String
    public var isStub: Bool
    public var addedAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
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
        pdfHash: String? = nil,
        conversionWarnings: Int? = nil,
        isFavorite: Bool = false,
        isOwn: Bool = false,
        status: PaperStatus = .stub,
        isStub: Bool = false,
        addedAt: String = PaperdDates.nowString(),
        updatedAt: String = PaperdDates.nowString()
    ) {
        self.id = id
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
        self.pdfHash = pdfHash
        self.conversionWarnings = conversionWarnings
        self.isFavorite = isFavorite
        self.isOwn = isOwn
        self.status = status.rawValue
        self.isStub = isStub
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public var paperStatus: PaperStatus {
        get { PaperStatus(rawValue: status) ?? .stub }
        set { status = newValue.rawValue }
    }

    /// 論文のWebページ（→ docs/09 4節）。
    /// DOI（出版社ページへ解決される恒久リンク）→ arXiv absページ → url の優先順
    public var webURL: URL? {
        if let doi {
            return URL(string: "https://doi.org/\(doi)")
        }
        if let arxivId {
            return URL(string: "https://arxiv.org/abs/\(arxivId)")
        }
        return url.flatMap(URL.init(string:))
    }
}

public struct Author: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "authors"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var displayName: String
    public var s2AuthorId: String?
    public var orcid: String?

    public init(id: String = UUID().uuidString.lowercased(), displayName: String, s2AuthorId: String? = nil, orcid: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.s2AuthorId = s2AuthorId
        self.orcid = orcid
    }
}

public struct PaperAuthor: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "paper_authors"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var paperId: String
    public var authorId: String
    public var position: Int

    public init(paperId: String, authorId: String, position: Int) {
        self.paperId = paperId
        self.authorId = authorId
        self.position = position
    }
}

public struct Citation: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "citations"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var citingId: String
    public var citedId: String
    public var source: String
    public var fetchedAt: String

    public init(citingId: String, citedId: String, source: CitationSource, fetchedAt: String = PaperdDates.nowString()) {
        self.citingId = citingId
        self.citedId = citedId
        self.source = source.rawValue
        self.fetchedAt = fetchedAt
    }
}

/// RAGチャンク（→ docs/06-search-rag.md）。id = vec_chunks.rowid = fts_chunks.rowid
public struct Chunk: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chunks"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var paperId: String
    public var chunkIndex: Int
    public var sectionPath: String?
    public var text: String
    public var tokenCount: Int

    public init(id: Int64? = nil, paperId: String, chunkIndex: Int, sectionPath: String?, text: String, tokenCount: Int) {
        self.id = id
        self.paperId = paperId
        self.chunkIndex = chunkIndex
        self.sectionPath = sectionPath
        self.text = text
        self.tokenCount = tokenCount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Note: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notes"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var paperId: String
    public var content: String
    public var pageAnchor: Int?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        paperId: String,
        content: String,
        pageAnchor: Int? = nil,
        createdAt: String = PaperdDates.nowString(),
        updatedAt: String = PaperdDates.nowString()
    ) {
        self.id = id
        self.paperId = paperId
        self.content = content
        self.pageAnchor = pageAnchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Job: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jobs"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var kind: String
    public var paperId: String?
    public var payload: String
    public var status: String
    public var stage: String?
    public var retryCount: Int
    public var lastError: String?
    public var origin: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: JobKind,
        paperId: String? = nil,
        payload: String,
        status: JobStatus = .queued,
        stage: JobStage? = nil,
        retryCount: Int = 0,
        lastError: String? = nil,
        origin: JobOrigin,
        createdAt: String = PaperdDates.nowString(),
        updatedAt: String = PaperdDates.nowString()
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.paperId = paperId
        self.payload = payload
        self.status = status.rawValue
        self.stage = stage?.rawValue
        self.retryCount = retryCount
        self.lastError = lastError
        self.origin = origin.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var jobStatus: JobStatus {
        get { JobStatus(rawValue: status) ?? .queued }
        set { status = newValue.rawValue }
    }

    public var jobStage: JobStage? {
        get { stage.flatMap(JobStage.init(rawValue:)) }
        set { stage = newValue?.rawValue }
    }
}

public struct EmbeddingMeta: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "embedding_meta"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var modelName: String
    public var dimensions: Int
    public var createdAt: String

    public init(modelName: String, dimensions: Int, createdAt: String = PaperdDates.nowString()) {
        self.modelName = modelName
        self.dimensions = dimensions
        self.createdAt = createdAt
    }
}
