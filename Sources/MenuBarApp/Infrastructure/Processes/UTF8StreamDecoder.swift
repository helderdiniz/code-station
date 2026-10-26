import Foundation

struct UTF8StreamDecoder {
    private var pending = Data()

    mutating func append(_ data: Data) -> String {
        pending.append(data)
        var end = pending.endIndex
        // A pipe read may end inside a character. Keep only that unfinished suffix.
        if let start = pending.indices.reversed().prefix(4).first(where: {
            pending[$0] & 0xC0 != 0x80
        }) {
            let length = switch pending[start] {
            case 0xC2...0xDF: 2
            case 0xE0...0xEF: 3
            case 0xF0...0xF4: 4
            default: 1
            }
            if pending.distance(from: start, to: end) < length { end = start }
        }
        let text = String(decoding: pending[..<end], as: UTF8.self)
        pending.removeSubrange(..<end)
        return text
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
