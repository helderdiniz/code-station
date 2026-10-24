import Foundation

struct DispatchResponseDocument {
    struct Table {
        let columns: [String]
        let rows: [[String]]
        let totalRows: Int
        let limited: Bool
    }

    static let structuredByteLimit = 1_048_576
    let isJSON: Bool
    let table: Table?
    let collapsedBody: String?
    let structuredLimitReached: Bool

    init(body: String, truncated: Bool = false) {
        structuredLimitReached = body.utf8.count > Self.structuredByteLimit
        guard !truncated, !structuredLimitReached,
              let value = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) else {
            isJSON = false
            table = nil
            collapsedBody = nil
            return
        }
        isJSON = true
        table = Self.makeTable(value)
        collapsedBody = Self.collapseArray(in: body)
    }

    private static func makeTable(_ value: Any) -> Table {
        let values: [Any]
        if let array = value as? [Any] {
            values = array
        } else if let object = value as? [String: Any], let array = object["data"] as? [Any] {
            values = array
        } else {
            values = [value]
        }
        let visible = Array(values.prefix(500))
        let objects = visible.map { ($0 as? [String: Any]) ?? ["value": $0] }
        let keys = Set(objects.flatMap(\.keys)).sorted()
        let columns = Array(keys.prefix(30))
        var limited = values.count > visible.count || keys.count > columns.count
        let rows = objects.map { object in
            columns.map { key -> String in
                guard let value = object[key] else { return "" }
                let text: String
                if let string = value as? String { text = string }
                else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                        let json = String(data: data, encoding: .utf8) { text = json }
                else { text = String(describing: value) }
                if text.count > 500 {
                    limited = true
                    return String(text.prefix(500)) + "…"
                }
                return text
            }
        }
        return Table(columns: columns, rows: rows, totalRows: values.count, limited: limited)
    }

    // Only folds a root array or an array directly inside the root object. The original
    // text around it is kept intact, including key order and exact number digits.
    private static func collapseArray(in body: String) -> String? {
        var depth = 0
        var quoted = false
        var escaped = false
        var start: String.Index?
        var arrayDepth = 0
        for index in body.indices {
            let character = body[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character == "\"" { quoted = true; continue }
            if character == "[" {
                if start == nil, depth <= 1 { start = index; arrayDepth = depth }
                depth += 1
            } else if character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
                if character == "]", let start, depth == arrayDepth {
                    let content = body[body.index(after: start)..<index]
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return String(body[...start]) + " … " + String(body[index...])
                }
            }
        }
        return nil
    }
}
