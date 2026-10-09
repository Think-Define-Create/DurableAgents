import Foundation

public protocol Embedder: Sendable {
    var id: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Deterministic stand-in for a sentence embedder. Tests do not need NaturalLanguage.
public struct HashEmbedder: Embedder {
    public var id: String
    public var dimensions: Int

    public init(id: String = "hash-v1", dimensions: Int = 8) {
        self.id = id
        self.dimensions = max(1, dimensions)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { Self.vector(for: $0, dimensions: dimensions) }
    }

    public static func vector(for text: String, dimensions: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !tokens.isEmpty else { return vector }
        for token in tokens {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            let index = Int(hash % UInt64(dimensions))
            let sign: Float = (hash & 1) == 0 ? 1 : -1
            vector[index] += sign
        }
        return RetrievalMath.normalize(vector)
    }
}

public enum RetrievalMath {
    public static func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    public static func cosine(_ left: [Float], _ right: [Float]) -> Float {
        let count = min(left.count, right.count)
        var dot: Float = 0
        for index in 0..<count {
            dot += left[index] * right[index]
        }
        return dot
    }

    /// Reciprocal rank fusion. Rank 1 is the first element of each list.
    public static func fuse(_ rankings: [[String]], k: Double = 60) -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        for ranking in rankings {
            for (offset, id) in ranking.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(offset + 1))
            }
        }
        return scores.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
            return lhs.1 > rhs.1
        }
    }
}

public struct VectorHit: Sendable, Equatable {
    public var id: String
    public var score: Float
    public var modelID: String
}

public struct BruteForceVectors: Sendable {
    public var modelID: String
    public var rows: [String: [Float]]

    public init(modelID: String, rows: [String: [Float]] = [:]) {
        self.modelID = modelID
        self.rows = rows
    }

    public func nearest(_ query: [Float], limit: Int) -> [VectorHit] {
        rows.map { id, vector in
            VectorHit(id: id, score: RetrievalMath.cosine(query, vector), modelID: modelID)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }
}
