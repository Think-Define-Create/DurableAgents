import Foundation

/// JSON value kept as an exact integer when the literal has no fraction.
///
/// The event log stores the canonical form of this value. Readers parse it
/// back with `JSONValue.parse`, so integers stay integers across a restart.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public func canonicalJSON() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return JSONValue.canonicalDouble(value)
        case .string(let value):
            return JSONValue.escape(value)
        case .array(let values):
            return "[" + values.map { $0.canonicalJSON() }.joined(separator: ",") + "]"
        case .object(let fields):
            let body = fields.keys.sorted().map { key in
                JSONValue.escape(key) + ":" + (fields[key] ?? .null).canonicalJSON()
            }.joined(separator: ",")
            return "{" + body + "}"
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text)
        let value = try parser.parseValue()
        try parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw DurableError.invariant("trailing data in JSON payload")
        }
        return value
    }

    private static func canonicalDouble(_ value: Double) -> String {
        if value.isNaN || value.isInfinite {
            return "null"
        }
        var text = String(format: "%.17g", value)
        if !text.contains(".") && !text.contains("e") && !text.contains("E") {
            text += ".0"
        }
        return text
    }

    private static func escape(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

private struct JSONParser {
    let scalars: [Unicode.Scalar]
    var index: Int = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool { index >= scalars.count }

    mutating func parseValue() throws -> JSONValue {
        try skipWhitespace()
        guard let scalar = peek() else {
            throw DurableError.invariant("unexpected end of JSON")
        }
        switch scalar {
        case "n":
            try consumeLiteral("null")
            return .null
        case "t":
            try consumeLiteral("true")
            return .bool(true)
        case "f":
            try consumeLiteral("false")
            return .bool(false)
        case "\"":
            return .string(try parseString())
        case "[":
            return try parseArray()
        case "{":
            return try parseObject()
        case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return try parseNumber()
        default:
            throw DurableError.invariant("unexpected JSON character")
        }
    }

    mutating func skipWhitespace() throws {
        while let scalar = peek(), scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
            index += 1
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try consume("[")
        try skipWhitespace()
        var values: [JSONValue] = []
        if peek() == "]" {
            index += 1
            return .array(values)
        }
        while true {
            values.append(try parseValue())
            try skipWhitespace()
            if peek() == "," {
                index += 1
                continue
            }
            if peek() == "]" {
                index += 1
                return .array(values)
            }
            throw DurableError.invariant("malformed JSON array")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try consume("{")
        try skipWhitespace()
        var fields: [String: JSONValue] = [:]
        if peek() == "}" {
            index += 1
            return .object(fields)
        }
        while true {
            try skipWhitespace()
            let key = try parseString()
            try skipWhitespace()
            try consume(":")
            let value = try parseValue()
            fields[key] = value
            try skipWhitespace()
            if peek() == "," {
                index += 1
                continue
            }
            if peek() == "}" {
                index += 1
                return .object(fields)
            }
            throw DurableError.invariant("malformed JSON object")
        }
    }

    private mutating func parseString() throws -> String {
        try consume("\"")
        var out = ""
        while let scalar = peek() {
            if scalar == "\"" {
                index += 1
                return out
            }
            if scalar == "\\" {
                index += 1
                guard let escaped = peek() else {
                    throw DurableError.invariant("truncated JSON string escape")
                }
                index += 1
                switch escaped {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0c}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let unit = try parseHex4()
                    if UTF16.isLeadSurrogate(unit) {
                        guard peek() == "\\", scalars.indices.contains(index + 1), scalars[index + 1] == "u" else {
                            throw DurableError.invariant("lone UTF-16 surrogate in JSON string")
                        }
                        index += 2
                        let trail = try parseHex4()
                        guard UTF16.isTrailSurrogate(trail),
                              let encoded = Unicode.Scalar(UTF16.decodeSurrogatePair(lead: unit, trail: trail))
                        else {
                            throw DurableError.invariant("bad UTF-16 surrogate pair in JSON string")
                        }
                        out.unicodeScalars.append(encoded)
                    } else if let encoded = Unicode.Scalar(unit) {
                        out.unicodeScalars.append(encoded)
                    } else {
                        throw DurableError.invariant("bad unicode escape in JSON string")
                    }
                default:
                    throw DurableError.invariant("unknown JSON string escape")
                }
                continue
            }
            if scalar.value < 0x20 {
                throw DurableError.invariant("raw control character in JSON string")
            }
            out.unicodeScalars.append(scalar)
            index += 1
        }
        throw DurableError.invariant("unterminated JSON string")
    }

    private mutating func parseHex4() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let scalar = peek() else {
                throw DurableError.invariant("truncated unicode escape")
            }
            index += 1
            let digit: UInt16
            switch scalar {
            case "0"..."9":
                digit = UInt16(scalar.value - Unicode.Scalar("0").value)
            case "a"..."f":
                digit = UInt16(scalar.value - Unicode.Scalar("a").value) + 10
            case "A"..."F":
                digit = UInt16(scalar.value - Unicode.Scalar("A").value) + 10
            default:
                throw DurableError.invariant("bad hex in unicode escape")
            }
            value = value << 4 | digit
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek() == "-" {
            index += 1
        }
        if peek() == "0" {
            index += 1
        } else if let scalar = peek(), scalar >= "1", scalar <= "9" {
            while let scalar = peek(), scalar >= "0", scalar <= "9" {
                index += 1
            }
        } else {
            throw DurableError.invariant("malformed JSON number")
        }
        var isDouble = false
        if peek() == "." {
            isDouble = true
            index += 1
            guard let scalar = peek(), scalar >= "0", scalar <= "9" else {
                throw DurableError.invariant("malformed JSON fraction")
            }
            while let scalar = peek(), scalar >= "0", scalar <= "9" {
                index += 1
            }
        }
        if peek() == "e" || peek() == "E" {
            isDouble = true
            index += 1
            if peek() == "+" || peek() == "-" {
                index += 1
            }
            guard let scalar = peek(), scalar >= "0", scalar <= "9" else {
                throw DurableError.invariant("malformed JSON exponent")
            }
            while let scalar = peek(), scalar >= "0", scalar <= "9" {
                index += 1
            }
        }
        let literal = String(String.UnicodeScalarView(scalars[start..<index]))
        if !isDouble, let integer = Int64(literal) {
            return .int(integer)
        }
        guard let double = Double(literal) else {
            throw DurableError.invariant("JSON number out of range")
        }
        return .double(double)
    }

    private func peek() -> Unicode.Scalar? {
        guard index < scalars.count else { return nil }
        return scalars[index]
    }

    private mutating func consume(_ expected: Unicode.Scalar) throws {
        guard peek() == expected else {
            throw DurableError.invariant("expected JSON delimiter")
        }
        index += 1
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            try consume(scalar)
        }
    }
}

private enum UTF16 {
    static func isLeadSurrogate(_ value: UInt16) -> Bool {
        value >= 0xD800 && value <= 0xDBFF
    }

    static func isTrailSurrogate(_ value: UInt16) -> Bool {
        value >= 0xDC00 && value <= 0xDFFF
    }

    static func decodeSurrogatePair(lead: UInt16, trail: UInt16) -> UInt32 {
        let high = UInt32(lead - 0xD800)
        let low = UInt32(trail - 0xDC00)
        return (high << 10 | low) + 0x10000
    }
}
