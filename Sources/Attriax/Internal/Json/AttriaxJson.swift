import Foundation

/// A tiny, dependency-free JSON encoder/decoder for the SDK's simple wire shapes
/// (mirrors the Android `internal.json.Json`).
///
/// Rationale (PARITY constraint): the wire shapes are flat maps/lists of
/// strings/numbers/bools/null. Keeping serialization hand-rolled makes queue
/// serialization, batching, and legacy normalization PURE Swift so they are
/// fully unit-testable off-device, and gives us deterministic key ordering
/// (`JSONSerialization` does not guarantee order) plus the integral-double
/// trimming the Android reference relies on for tight batch byte accounting.
///
/// Values in a decoded/encoded tree are one of:
///   [String: Any], [Any], String, Int64, Double, Bool, NSNull/nil.
enum AttriaxJson {

    struct ParseError: Error { let message: String }

    // MARK: - Encoding

    static func encode(_ value: Any?) -> String {
        var out = String()
        encodeInto(&out, value)
        return out
    }

    /// UTF-8 byte length of the encoded `value` — used for the batch size limit.
    static func encodedByteSize(_ value: Any?) -> Int {
        encode(value).utf8.count
    }

    private static func encodeInto(_ out: inout String, _ value: Any?) {
        switch value {
        case nil, is NSNull:
            out.append("null")
        case let s as String:
            encodeString(&out, s)
        case let b as Bool:
            out.append(b ? "true" : "false")
        case let i as Int:
            out.append(String(i))
        case let i as Int64:
            out.append(String(i))
        case let d as Double:
            encodeDouble(&out, d)
        case let f as Float:
            encodeDouble(&out, Double(f))
        case let n as NSNumber:
            encodeNSNumber(&out, n)
        default:
            // Dictionaries and arrays are matched structurally so that a value
            // typed as e.g. `[String: String]` or `[Any]` (not exactly
            // `[String: Any?]`) still encodes correctly rather than falling
            // through to a stringified representation. Any other type is a scalar
            // we do not model → encode its description as a string.
            if let map = value as? [String: Any] {
                encodeMap(&out, map)
            } else if let map = value as? [String: Any?] {
                encodeMap(&out, map.mapValues { $0 as Any? })
            } else if let list = value as? [Any?] {
                encodeList(&out, list)
            } else if let list = value as? [Any] {
                encodeList(&out, list.map { $0 as Any? })
            } else {
                encodeString(&out, String(describing: value!))
            }
        }
    }

    private static func encodeMap(_ out: inout String, _ map: [String: Any?]) {
        out.append("{")
        var first = true
        // Sorted keys give deterministic output (Swift dictionaries are unordered).
        // The API validates by field name not order, and the batch byte-size check
        // is a `<=` bound, so ordering is not wire-significant — but determinism
        // makes tests reproducible.
        for key in map.keys.sorted() {
            if !first { out.append(",") }
            first = false
            encodeString(&out, key)
            out.append(":")
            encodeInto(&out, map[key] ?? nil)
        }
        out.append("}")
    }

    private static func encodeList(_ out: inout String, _ list: [Any?]) {
        out.append("[")
        var first = true
        for v in list {
            if !first { out.append(",") }
            first = false
            encodeInto(&out, v)
        }
        out.append("]")
    }

    private static func encodeDouble(_ out: inout String, _ value: Double) {
        guard value.isFinite else { out.append("null"); return }
        // Emit integral doubles without a trailing ".0" to keep bytes tight
        // (matches the Android encoder so batch byte-size math agrees).
        if value == value.rounded(.towardZero), abs(value) < 9.007199254740992e15 {
            out.append(String(Int64(value)))
        } else {
            out.append(String(value))
        }
    }

    private static func encodeNSNumber(_ out: inout String, _ number: NSNumber) {
        // Distinguish a boxed Bool from a numeric NSNumber (Foundation bridges
        // Bool to NSNumber with the __NSCFBoolean class).
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            out.append(number.boolValue ? "true" : "false")
            return
        }
        let objcType = String(cString: number.objCType)
        if objcType == "d" || objcType == "f" {
            encodeDouble(&out, number.doubleValue)
        } else {
            out.append(String(number.int64Value))
        }
    }

    private static func encodeString(_ out: inout String, _ s: String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append("\\u")
                    out.append(String(format: "%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }

    // MARK: - Decoding

    static func decode(_ text: String) throws -> Any? {
        var parser = Parser(text)
        return try parser.parseTopLevel()
    }

    /// Decode and require a JSON object at the root.
    static func decodeObject(_ text: String) throws -> [String: Any?] {
        let value = try decode(text)
        guard let map = value as? [String: Any?] else {
            throw ParseError(message: "expected JSON object at root")
        }
        return map
    }

    /// Decode and require a JSON array at the root.
    static func decodeArray(_ text: String) throws -> [Any?] {
        let value = try decode(text)
        guard let list = value as? [Any?] else {
            throw ParseError(message: "expected JSON array at root")
        }
        return list
    }

    private struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ src: String) { chars = Array(src) }

        mutating func parseTopLevel() throws -> Any? {
            skipWs()
            let value = try parseValue()
            skipWs()
            if pos != chars.count { throw ParseError(message: "trailing content at \(pos)") }
            return value
        }

        private mutating func parseValue() throws -> Any? {
            skipWs()
            guard pos < chars.count else { throw ParseError(message: "unexpected end of input") }
            let c = chars[pos]
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return try parseString()
            case "t", "f": return try parseBool()
            case "n": return try parseNull()
            default:
                if c == "-" || (c >= "0" && c <= "9") { return try parseNumber() }
                throw ParseError(message: "unexpected char '\(c)' at \(pos)")
            }
        }

        private mutating func parseObject() throws -> [String: Any?] {
            try expect("{")
            var map = [String: Any?]()
            skipWs()
            if peek() == "}" { pos += 1; return map }
            while true {
                skipWs()
                let key = try parseString()
                skipWs()
                try expect(":")
                let value = try parseValue()
                map[key] = value
                skipWs()
                let c = try next()
                if c == "," { continue }
                if c == "}" { break }
                throw ParseError(message: "expected ',' or '}' at \(pos - 1), got '\(c)'")
            }
            return map
        }

        private mutating func parseArray() throws -> [Any?] {
            try expect("[")
            var list = [Any?]()
            skipWs()
            if peek() == "]" { pos += 1; return list }
            while true {
                list.append(try parseValue())
                skipWs()
                let c = try next()
                if c == "," { continue }
                if c == "]" { break }
                throw ParseError(message: "expected ',' or ']' at \(pos - 1), got '\(c)'")
            }
            return list
        }

        private mutating func parseString() throws -> String {
            try expect("\"")
            var sb = String()
            while true {
                guard pos < chars.count else { throw ParseError(message: "unterminated string") }
                let c = chars[pos]; pos += 1
                if c == "\"" { return sb }
                if c == "\\" {
                    guard pos < chars.count else { throw ParseError(message: "bad escape") }
                    let e = chars[pos]; pos += 1
                    switch e {
                    case "\"": sb.append("\"")
                    case "\\": sb.append("\\")
                    case "/": sb.append("/")
                    case "n": sb.append("\n")
                    case "r": sb.append("\r")
                    case "t": sb.append("\t")
                    case "b": sb.append("\u{08}")
                    case "f": sb.append("\u{0C}")
                    case "u":
                        guard pos + 4 <= chars.count else { throw ParseError(message: "bad unicode escape") }
                        let hex = String(chars[pos..<pos + 4])
                        pos += 4
                        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw ParseError(message: "bad unicode escape")
                        }
                        sb.unicodeScalars.append(scalar)
                    default:
                        throw ParseError(message: "bad escape '\\\(e)'")
                    }
                } else {
                    sb.append(c)
                }
            }
        }

        private mutating func parseNumber() throws -> Any {
            let start = pos
            if peek() == "-" { pos += 1 }
            while pos < chars.count, chars[pos] >= "0", chars[pos] <= "9" { pos += 1 }
            var isDouble = false
            if pos < chars.count, chars[pos] == "." {
                isDouble = true
                pos += 1
                while pos < chars.count, chars[pos] >= "0", chars[pos] <= "9" { pos += 1 }
            }
            if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
                isDouble = true
                pos += 1
                if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
                while pos < chars.count, chars[pos] >= "0", chars[pos] <= "9" { pos += 1 }
            }
            let token = String(chars[start..<pos])
            if isDouble {
                guard let d = Double(token) else { throw ParseError(message: "bad number \(token)") }
                return d
            }
            if let i = Int64(token) { return i }
            guard let d = Double(token) else { throw ParseError(message: "bad number \(token)") }
            return d
        }

        private mutating func parseBool() throws -> Bool {
            if matches("true") { pos += 4; return true }
            if matches("false") { pos += 5; return false }
            throw ParseError(message: "invalid literal at \(pos)")
        }

        private mutating func parseNull() throws -> Any? {
            if matches("null") { pos += 4; return NSNull() }
            throw ParseError(message: "invalid literal at \(pos)")
        }

        private func matches(_ literal: String) -> Bool {
            let lit = Array(literal)
            guard pos + lit.count <= chars.count else { return false }
            for (i, ch) in lit.enumerated() where chars[pos + i] != ch { return false }
            return true
        }

        private mutating func skipWs() {
            while pos < chars.count, chars[pos] == " " || chars[pos] == "\n" || chars[pos] == "\r" || chars[pos] == "\t" {
                pos += 1
            }
        }

        private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        private mutating func next() throws -> Character {
            guard pos < chars.count else { throw ParseError(message: "unexpected end of input") }
            let c = chars[pos]; pos += 1
            return c
        }

        private mutating func expect(_ c: Character) throws {
            let actual = try next()
            if actual != c { throw ParseError(message: "expected '\(c)' at \(pos - 1), got '\(actual)'") }
        }
    }
}
