import DurableCore
import Foundation

public protocol TokenVault: Sendable {
    func token(for plaintext: String, kind: String) async -> String
    func plaintext(for token: String) async -> String?
}

public actor MemoryTokenVault: TokenVault {
    private var byPlain: [String: String] = [:]
    private var byToken: [String: String] = [:]
    private var next = 1

    public init() {}

    public func token(for plaintext: String, kind: String) async -> String {
        let key = kind + "\u{0}" + plaintext
        if let existing = byPlain[key] {
            return existing
        }
        let issued = "tok_\(kind)_\(next)"
        next += 1
        byPlain[key] = issued
        byToken[issued] = plaintext
        return issued
    }

    public func plaintext(for token: String) async -> String? {
        byToken[token]
    }
}

public struct RedactionPattern: Sendable, Equatable {
    public var name: String
    public var regex: String

    public init(name: String, regex: String) {
        self.name = name
        self.regex = regex
    }
}

public protocol PayloadRedactor: Sendable {
    func redact(_ payload: JSONValue) async -> JSONValue
}

public struct PassThroughRedactor: PayloadRedactor {
    public init() {}

    public func redact(_ payload: JSONValue) async -> JSONValue { payload }
}

/// Replaces SSN, card, account, routing, email, phone, and credential strings before they are stored.
public struct BuiltInRedactor: PayloadRedactor {
    public var tokenize: Bool
    public var vault: (any TokenVault)?
    public var extra: [RedactionPattern]

    public init(tokenize: Bool = false, vault: (any TokenVault)? = nil, extra: [RedactionPattern] = []) {
        self.tokenize = tokenize
        self.vault = vault
        self.extra = extra
    }

    public func redact(_ payload: JSONValue) async -> JSONValue {
        await rewrite(payload)
    }

    private func rewrite(_ value: JSONValue) async -> JSONValue {
        switch value {
        case .string(let text):
            return .string(await redactText(text))
        case .array(let items):
            var rewritten: [JSONValue] = []
            for item in items {
                rewritten.append(await rewrite(item))
            }
            return .array(rewritten)
        case .object(let fields):
            var rewritten: [String: JSONValue] = [:]
            for (key, item) in fields {
                rewritten[key] = await rewrite(item)
            }
            return .object(rewritten)
        default:
            return value
        }
    }

    private func redactText(_ text: String) async -> String {
        var edited = text
        for pattern in Self.builtins + extra {
            edited = await replace(pattern, in: edited)
        }
        edited = await replaceCards(in: edited)
        return edited
    }

    private func replace(_ pattern: RedactionPattern, in text: String) async -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        var edited = text
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: edited) else { continue }
            let secret = String(edited[swiftRange])
            let replacement = await placeholder(secret, kind: pattern.name)
            edited.replaceSubrange(swiftRange, with: replacement)
        }
        return edited
    }

    private func replaceCards(in text: String) async -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?:\d[ -]?){13,19}"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        var edited = text
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: edited) else { continue }
            let raw = String(edited[swiftRange])
            let digits = raw.filter(\.isNumber)
            guard (13...19).contains(digits.count), Self.luhn(digits) else { continue }
            let replacement = await placeholder(raw, kind: "card")
            edited.replaceSubrange(swiftRange, with: replacement)
        }
        return edited
    }

    private func placeholder(_ secret: String, kind: String) async -> String {
        if tokenize, let vault {
            return await vault.token(for: secret, kind: kind)
        }
        return "[redacted:\(kind)]"
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        let reversed = digits.reversed().map { Int(String($0)) ?? 0 }
        for (offset, digit) in reversed.enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return !digits.isEmpty && sum % 10 == 0
    }

    static let builtins: [RedactionPattern] = [
        RedactionPattern(name: "ssn", regex: #"\b\d{3}-\d{2}-\d{4}\b"#),
        RedactionPattern(name: "email", regex: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#),
        RedactionPattern(name: "phone", regex: #"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}\b"#),
        RedactionPattern(
            name: "routing",
            regex: #"\brouting(?:\s+number)?[:\s#]*\d{9}\b"#
        ),
        RedactionPattern(
            name: "account",
            regex: #"\baccount(?:\s+number)?[:\s#]*\d{6,17}\b"#
        ),
        RedactionPattern(
            name: "authorization",
            regex: #"\bauthorization\s*:\s*bearer\s+[A-Z0-9._\-]+"#
        ),
        RedactionPattern(name: "secret", regex: #"\bsk-[A-Za-z0-9_\-]{8,}\b"#),
        RedactionPattern(name: "api-key", regex: #"\bx-api-key\s*[:=]\s*\S+"#),
    ]
}
