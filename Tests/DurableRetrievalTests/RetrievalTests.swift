import DurableRetrieval
import Testing

@Test func hashEmbedderIsStableAndFusionPrefersAgreement() async throws {
    let embedder = HashEmbedder(dimensions: 8)
    let first = try await embedder.embed(["likes tea"])
    let second = try await embedder.embed(["likes tea"])
    #expect(first == second)
    #expect(embedder.id == "hash-v1")
    let vectors = BruteForceVectors(modelID: embedder.id, rows: [
        "tea": first[0],
        "other": try await embedder.embed(["engine lease"])[0],
    ])
    let hits = vectors.nearest(first[0], limit: 2)
    #expect(hits.first?.id == "tea")
    let fused = RetrievalMath.fuse([["tea", "other"], ["other", "tea"]])
    #expect(fused.map(\.id).sorted() == ["other", "tea"])
    #expect(fused[0].score == fused[1].score)
}

@Test func hashEmbeddersOfDifferentSizesHaveDifferentIDs() {
    #expect(HashEmbedder().id == "hash-v1")
    #expect(HashEmbedder(dimensions: 256).id == "hash-v1-256")
    #expect(Embedders.fallback.id == "hash-v1-256")
}
