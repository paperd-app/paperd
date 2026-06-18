import Foundation
import Testing
import PaperdCore

@Suite("WorkerClient")
struct WorkerClientTests {
    @Test("warmUpEmbeddingModel: 未ロードならquery embeddingを実行する")
    func warmUpLoadsEmbeddingModel() async throws {
        let http = StubHTTPClient()
        http.add("health", body: #"{"status":"ok","model_loaded":false,"version":"0.2.1"}"#)
        http.add("embed", body: #"{"embeddings":[[0.0,1.0]],"model":"fake","dimensions":2}"#)
        let client = WorkerClient(baseURL: URL(string: "http://127.0.0.1:9999")!, token: "tok", http: http)

        try await client.warmUpEmbeddingModel()

        #expect(http.requests.map(\.url.path) == ["/health", "/embed"])
        let embedRequest = try #require(http.requests.last)
        #expect(embedRequest.method == .post)
        let body = try #require(embedRequest.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["task"] as? String == "query")
    }

    @Test("warmUpEmbeddingModel: ロード済みならembedしない")
    func warmUpSkipsLoadedModel() async throws {
        let http = StubHTTPClient()
        http.add("health", body: #"{"status":"ok","model_loaded":true,"version":"0.2.1"}"#)
        let client = WorkerClient(baseURL: URL(string: "http://127.0.0.1:9999")!, token: "tok", http: http)

        try await client.warmUpEmbeddingModel()

        #expect(http.requests.map(\.url.path) == ["/health"])
    }
}
