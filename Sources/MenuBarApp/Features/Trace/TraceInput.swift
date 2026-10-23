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

    static func isTraceID(_ text: String) -> Bool {
        (text.count == 16 || text.count == 32) && text.allSatisfy(\.isHexDigit)
    }
}
