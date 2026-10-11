import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Picks the best embedder this device has.
public enum Embedders {
    /// Used when no sentence model is available. 256 buckets keep word collisions rare.
    public static let fallback: any Embedder = HashEmbedder(dimensions: 256)

    /// Apple's contextual sentence model for `language` (BCP 47, such as "en"), or `fallback`.
    /// With `requestAssets`, a missing model is downloaded first. That can take a while, so call
    /// this off the launch path and hand the result to `MemoryIndex.use(_:)`.
    public static func preferred(
        language: String? = nil,
        requestAssets: Bool = true,
        fallback: any Embedder = Embedders.fallback
    ) async -> any Embedder {
        #if canImport(NaturalLanguage)
        if let embedder = await ContextualEmbedder.load(language: language, requestAssets: requestAssets) {
            return embedder
        }
        #endif
        return fallback
    }
}

#if canImport(NaturalLanguage)
/// Sentence vectors from `NLContextualEmbedding`: token vectors mean-pooled, then normalized.
/// The id names the model and its revision, so a model update re-embeds the memory index.
public struct ContextualEmbedder: Embedder {
    public let id: String
    public let dimensions: Int
    private let model: Model

    /// Nil when there is no model for the language or its assets are not on the device.
    public init?(language: String? = nil) {
        guard let embedding = Self.embedding(for: language), embedding.hasAvailableAssets else { return nil }
        do {
            try embedding.load()
        } catch {
            return nil
        }
        model = Model(embedding)
        id = "nl-contextual:\(embedding.modelIdentifier):r\(embedding.revision)"
        dimensions = embedding.dimension
    }

    /// Like `init`, but first asks the system to download missing assets when `requestAssets` is set.
    public static func load(language: String? = nil, requestAssets: Bool = true) async -> ContextualEmbedder? {
        if let ready = ContextualEmbedder(language: language) { return ready }
        guard requestAssets, let embedding = embedding(for: language), !embedding.hasAvailableAssets else { return nil }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<NLContextualEmbedding.AssetsResult, Never>) in
            embedding.requestAssets { result, _ in continuation.resume(returning: result) }
        }
        guard result == .available else { return nil }
        return ContextualEmbedder(language: language)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try texts.map { try model.vector(for: $0, dimensions: dimensions) }
    }

    /// The language model first, then the model for that language's script, then Latin.
    private static func embedding(for language: String?) -> NLContextualEmbedding? {
        let code = language ?? Locale.current.language.languageCode?.identifier ?? "en"
        let nlLanguage = NLLanguage(rawValue: code)
        if let embedding = NLContextualEmbedding(language: nlLanguage) { return embedding }
        if let script = Locale.Language(identifier: code).script?.identifier,
           let embedding = NLContextualEmbedding(script: NLScript(rawValue: script)) {
            return embedding
        }
        return NLContextualEmbedding(script: .latin)
    }

    /// The Objective-C model is not Sendable. One lock serializes every call into it.
    private final class Model: @unchecked Sendable {
        private let embedding: NLContextualEmbedding
        private let lock = NSLock()
        private let languages: Set<NLLanguage>

        init(_ embedding: NLContextualEmbedding) {
            self.embedding = embedding
            languages = Set(embedding.languages)
        }

        func vector(for text: String, dimensions: Int) throws -> [Float] {
            // Tokens past the model's sequence length are dropped by the model. Clip the text
            // so a long note does not pay for work that is thrown away.
            let clipped = String(text.prefix(max(64, embedding.maximumSequenceLength * 4)))
            var sum = [Double](repeating: 0, count: dimensions)
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return [Float](repeating: 0, count: dimensions)
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(clipped)
            let language = recognizer.dominantLanguage.flatMap { languages.contains($0) ? $0 : nil }
            lock.lock()
            defer { lock.unlock() }
            let result = try embedding.embeddingResult(for: clipped, language: language)
            var count = 0
            result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
                for index in 0..<min(dimensions, vector.count) {
                    sum[index] += vector[index]
                }
                count += 1
                return true
            }
            guard count > 0 else { return [Float](repeating: 0, count: dimensions) }
            return RetrievalMath.normalize(sum.map { Float($0 / Double(count)) })
        }
    }
}
#endif
