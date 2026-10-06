import Foundation

/// Views into one bounded wire frame. Unused values are validated and skipped,
/// never materialized as dictionaries, arrays, transcripts or tool output.
struct JSONFieldView {
    enum Failure: Error { case malformed, limit }
    private let data: Data
    private let range: Range<Int>
    static func document(_ data: Data, maximumBytes: Int = 16 * 1024 * 1024) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.limit }
        let range = try data.withUnsafeBytes { raw -> Range<Int> in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self), position: 0, end: data.count)
            cursor.whitespace(); let start = cursor.position
            try cursor.skipValue(depth: 0); let end = cursor.position
            cursor.whitespace()
            guard cursor.position == data.count else { throw Failure.malformed }
            return start..<end
        }
        return Self(data: data, range: range)
    }
    var isObject: Bool { data[range.lowerBound] == 123 }
    var isArray: Bool { data[range.lowerBound] == 91 }
    var isNull: Bool { range.count == 4 && data[range.lowerBound] == 110 }

    func fields(_ allowed: Set<String>? = nil, maximumCount: Int = 512) throws -> [String: Self] {
        try data.withUnsafeBytes { raw in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self), position: range.lowerBound, end: range.upperBound)
            try cursor.require(123); cursor.whitespace()
            var fields: [String: Self] = [:], count = 0
            if cursor.consume(125) { return fields }
            repeat {
                cursor.whitespace(); let start = cursor.position
                try cursor.skipString(); let keyRange = start..<cursor.position
                cursor.whitespace(); try cursor.require(58); cursor.whitespace()
                let valueStart = cursor.position
                try cursor.skipValue(depth: 0)
                if keyRange.count <= 1538,
                   let key = try? JSONDecoder().decode(String.self, from: data.subdata(in: keyRange)),
                   key.count <= 256, allowed?.contains(key) ?? true {
                    fields[key] = Self(data: data, range: valueStart..<cursor.position)
                    count += 1
                    guard count <= maximumCount else { throw Failure.limit }
                }
                cursor.whitespace()
                if cursor.consume(125) { return fields }
                try cursor.require(44)
            } while true
        }
    }
    func elements(maximumCount: Int = 8192) throws -> [Self] {
        var result: [Self] = []
        try forEachElement(maximumCount: maximumCount) { result.append($0) }
        return result
    }
    func forEachElement(maximumCount: Int = 8192, _ body: (Self) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self), position: range.lowerBound, end: range.upperBound)
            try cursor.require(91); cursor.whitespace()
            if cursor.consume(93) { return }
            var count = 0
            repeat {
                cursor.whitespace(); let start = cursor.position
                try cursor.skipValue(depth: 0); count += 1
                guard count <= maximumCount else { throw Failure.limit }
                try body(Self(data: data, range: start..<cursor.position))
                cursor.whitespace()
                if cursor.consume(93) { return }
                try cursor.require(44)
            } while true
        }
    }
    func countElements(maximumCount: Int = 8192) throws -> Int {
        var count = 0
        try forEachElement(maximumCount: maximumCount) { _ in count += 1 }
        return count
    }
    func forEachField(maximumCount: Int = 512, _ body: (String, Self) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self), position: range.lowerBound, end: range.upperBound)
            try cursor.require(123); cursor.whitespace()
            if cursor.consume(125) { return }
            var count = 0
            repeat {
                cursor.whitespace(); let start = cursor.position
                try cursor.skipString(); let keyRange = start..<cursor.position
                guard keyRange.count <= 1538,
                      let key = try? JSONDecoder().decode(String.self, from: data.subdata(in: keyRange)),
                      key.count <= 256 else { throw Failure.limit }
                cursor.whitespace(); try cursor.require(58); cursor.whitespace()
                let valueStart = cursor.position; try cursor.skipValue(depth: 0)
                count += 1; guard count <= maximumCount else { throw Failure.limit }
                try body(key, Self(data: data, range: valueStart..<cursor.position))
                cursor.whitespace(); if cursor.consume(125) { return }
                try cursor.require(44)
            } while true
        }
    }
    func string(limit: Int = 256) -> String? {
        guard data[range.lowerBound] == 34, range.count <= limit * 6 + 2,
              let value = try? JSONDecoder().decode(String.self, from: data.subdata(in: range)) else { return nil }
        return String(value.prefix(limit))
    }
    func integer() -> Int? {
        guard range.count <= 24, let text = String(data: data.subdata(in: range), encoding: .utf8),
              !text.contains(".") && !text.contains("e") && !text.contains("E") else { return nil }
        return Int(text)
    }
    func number() -> Double? {
        guard range.count <= 64, let text = String(data: data.subdata(in: range), encoding: .utf8),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }
    func boolean() -> Bool? {
        if range.count == 4 && data[range.lowerBound] == 116 { return true }
        if range.count == 5 && data[range.lowerBound] == 102 { return false }
        return nil
    }
    func scalarIdentifier() -> String? { string() ?? integer().map(String.init) }

    private struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var position: Int
        let end: Int
        mutating func whitespace() {
            while position < end && [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard position < end && bytes[position] == byte else { return false }
            position += 1; return true
        }
        mutating func require(_ byte: UInt8) throws {
            guard consume(byte) else { throw Failure.malformed }
        }
        mutating func skipValue(depth: Int) throws {
            guard depth <= 128, position < end else { throw Failure.malformed }
            switch bytes[position] {
            case 34: try skipString()
            case 123:
                position += 1; whitespace()
                if consume(125) { return }
                repeat {
                    whitespace(); try skipString(); whitespace(); try require(58); whitespace()
                    try skipValue(depth: depth + 1); whitespace()
                    if consume(125) { return }
                    try require(44)
                } while true
            case 91:
                position += 1; whitespace()
                if consume(93) { return }
                repeat {
                    whitespace(); try skipValue(depth: depth + 1); whitespace()
                    if consume(93) { return }
                    try require(44)
                } while true
            case 116: try literal([116, 114, 117, 101])
            case 102: try literal([102, 97, 108, 115, 101])
            case 110: try literal([110, 117, 108, 108])
            default: try skipNumber()
            }
        }
        mutating func literal(_ value: [UInt8]) throws {
            for byte in value { try require(byte) }
        }
        mutating func digits() -> Int {
            let start = position
            while position < end && bytes[position] >= 48 && bytes[position] <= 57 { position += 1 }
            return position - start
        }
        mutating func skipNumber() throws {
            _ = consume(45)
            if consume(48) {
                guard position == end || !(48...57).contains(bytes[position]) else { throw Failure.malformed }
            } else {
                guard position < end && (49...57).contains(bytes[position]), digits() > 0 else { throw Failure.malformed }
            }
            if consume(46), digits() == 0 { throw Failure.malformed }
            if consume(101) || consume(69) {
                if !consume(43) { _ = consume(45) }
                guard digits() > 0 else { throw Failure.malformed }
            }
        }
        mutating func hex() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard position < end else { throw Failure.malformed }
                let byte = bytes[position]; position += 1
                let digit: UInt32
                switch byte {
                case 48...57: digit = UInt32(byte - 48)
                case 65...70: digit = UInt32(byte - 55)
                case 97...102: digit = UInt32(byte - 87)
                default: throw Failure.malformed
                }
                value = value * 16 + digit
            }
            return value
        }
        mutating func skipString() throws {
            try require(34)
            while position < end {
                let byte = bytes[position]; position += 1
                if byte == 34 { return }
                if byte == 92 {
                    guard position < end else { throw Failure.malformed }
                    let escape = bytes[position]; position += 1
                    if escape == 117 {
                        let code = try hex()
                        if (0xD800...0xDBFF).contains(code) {
                            try require(92); try require(117)
                            guard (0xDC00...0xDFFF).contains(try hex()) else { throw Failure.malformed }
                        } else if (0xDC00...0xDFFF).contains(code) { throw Failure.malformed }
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw Failure.malformed }
                } else if byte < 32 { throw Failure.malformed }
                else if byte >= 128 {
                    let count: Int
                    switch byte {
                    case 0xC2...0xDF: count = 1
                    case 0xE0...0xEF: count = 2
                    case 0xF0...0xF4: count = 3
                    default: throw Failure.malformed
                    }
                    guard position + count <= end else { throw Failure.malformed }
                    let next = bytes[position]
                    guard (byte != 0xE0 || next >= 0xA0) && (byte != 0xED || next <= 0x9F) &&
                          (byte != 0xF0 || next >= 0x90) && (byte != 0xF4 || next <= 0x8F) else { throw Failure.malformed }
                    for _ in 0..<count {
                        guard (0x80...0xBF).contains(bytes[position]) else { throw Failure.malformed }
                        position += 1
                    }
                }
            }
            throw Failure.malformed
        }
    }
}
