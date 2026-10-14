import Foundation

enum Bencode: Sendable, Equatable {
    case int(Int)
    case bytes(Data)
    case list([Bencode])
    case dict([String: Bencode])

    var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    var data: Data? { if case .bytes(let d) = self { return d }; return nil }
    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    var list: [Bencode]? { if case .list(let l) = self { return l }; return nil }
    var dict: [String: Bencode]? { if case .dict(let d) = self { return d }; return nil }
    subscript(key: String) -> Bencode? { dict?[key] }

    struct ParseError: Error { let msg: String }

    /// Decodes one value from the start of `data`. Returns the value and the number of bytes consumed.
    /// Never traps on malformed input; nesting depth is capped.
    static func decode(_ data: Data) throws -> (Bencode, Int) {
        let b = [UInt8](data)
        var i = 0
        let v = try parse(b, &i, depth: 0)
        return (v, i)
    }

    private static func parse(_ b: [UInt8], _ i: inout Int, depth: Int) throws -> Bencode {
        guard depth < 32 else { throw ParseError(msg: "nesting too deep") }
        guard i < b.count else { throw ParseError(msg: "unexpected end") }
        switch b[i] {
        case UInt8(ascii: "i"):
            i += 1
            let start = i
            while i < b.count, b[i] != UInt8(ascii: "e") { i += 1 }
            guard i < b.count, let s = String(bytes: b[start..<i], encoding: .ascii), let n = Int(s) else { throw ParseError(msg: "bad int") }
            i += 1
            return .int(n)
        case UInt8(ascii: "l"):
            i += 1
            var out: [Bencode] = []
            while true {
                guard i < b.count else { throw ParseError(msg: "unterminated list") }
                if b[i] == UInt8(ascii: "e") { i += 1; return .list(out) }
                out.append(try parse(b, &i, depth: depth + 1))
            }
        case UInt8(ascii: "d"):
            i += 1
            var out: [String: Bencode] = [:]
            while true {
                guard i < b.count else { throw ParseError(msg: "unterminated dict") }
                if b[i] == UInt8(ascii: "e") { i += 1; return .dict(out) }
                guard case .bytes(let k) = try parse(b, &i, depth: depth + 1) else { throw ParseError(msg: "bad dict key") }
                let key = String(decoding: k, as: UTF8.self)
                out[key] = try parse(b, &i, depth: depth + 1)
            }
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let start = i
            while i < b.count, b[i] != UInt8(ascii: ":") { i += 1 }
            guard i < b.count, let s = String(bytes: b[start..<i], encoding: .ascii), let n = Int(s), n >= 0 else { throw ParseError(msg: "bad length") }
            i += 1
            guard n <= b.count - i else { throw ParseError(msg: "string overruns buffer") }
            let d = Data(b[i..<(i + n)])
            i += n
            return .bytes(d)
        default:
            throw ParseError(msg: "unexpected byte \(b[i])")
        }
    }

    // MARK: encode (only needed for ut_metadata / extended handshake messages)
    func encode() -> Data {
        switch self {
        case .int(let n): return Data("i\(n)e".utf8)
        case .bytes(let d): return Data("\(d.count):".utf8) + d
        case .list(let l): return Data("l".utf8) + l.reduce(Data()) { $0 + $1.encode() } + Data("e".utf8)
        case .dict(let d):
            var out = Data("d".utf8)
            for k in d.keys.sorted() { out += Bencode.bytes(Data(k.utf8)).encode() + d[k]!.encode() }
            return out + Data("e".utf8)
        }
    }
}
