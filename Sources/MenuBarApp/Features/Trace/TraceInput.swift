import Foundation

// A traceId as typed, or pulled out of a pasted Grafana link: 32 hex characters, or the 16
// an older tracer writes. A link carries other ids as well, a datasource uid among them, so
// a full 32-character run is preferred to a short one. Tempo search drops the leading zero
// of an id that has one, so 31 characters are read as the 32 they stand for.
enum TraceInput {
    static func traceID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTraceID(trimmed) { return trimmed.lowercased() }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let runs = decoded.split(whereSeparator: { !$0.isHexDigit }).map(String.init)
        let found = runs.first { $0.count == 32 }
            ?? runs.first { $0.count == 31 }.map { "0" + $0 }
            ?? runs.first { $0.count == 16 }
        return found?.lowercased()
    }

    // Every traceId named in free text such as a problem description, bare or inside a
    // Grafana link, in the order they appear. Only whole words count, so a hex run inside
    // a longer id or a datasource uid is not mistaken for one. A 16-character id is only
    // taken when no full one is named, because a link that holds a traceId often holds
    // a spanId of that length too, and it needs a letter, so a card or account number
    // is not read as a trace.
    static func traceIDs(in text: String) -> [String] {
        var long: [String] = []
        var short: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            let decoded = word.removingPercentEncoding ?? String(word)
            for token in decoded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                guard token.allSatisfy(\.isHexDigit) else { continue }
                let id = token.lowercased()
                switch id.count {
                case 32: long.append(id)
                case 31: long.append("0" + id)
                case 16 where id.contains(where: \.isLetter): short.append(id)
                default: continue
                }
            }
        }
        var seen = Set<String>()
        return (long.isEmpty ? short : long).filter { seen.insert($0).inserted }
    }

    static func isTraceID(_ text: String) -> Bool {
        (text.count == 16 || text.count == 32) && text.allSatisfy(\.isHexDigit)
    }
}
