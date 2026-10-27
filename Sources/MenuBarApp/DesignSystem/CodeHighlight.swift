import AppKit
import SwiftUI

// The grammar family a piece of code is read as. It comes from a fence tag in chat or
// from a file extension elsewhere. A fence tag we do not know still gets the generic
// C-like reading, because most languages people paste look enough like C for comments,
// strings and numbers to land right. An unknown file extension gets nothing: a random
// text file coloured as code looks broken.
enum CodeLanguage: Sendable, Equatable {
    case swift, json, jsonnet, yaml, shell, python, javascript, java, kotlin, go, rust, markup, sql,
         makefile, cLike

    init?(tag: String?) {
        guard let tag, !tag.isEmpty else { return nil }
        self = CodeLanguage(name: tag.lowercased()) ?? .cLike
    }

    init?(fileExtension: String) {
        guard let language = CodeLanguage(name: fileExtension.lowercased()) else { return nil }
        self = language
    }

    // Takes a whole path or just a file name. Some files are known by name rather than
    // extension: a Makefile has none, and a Makefile.in or Makefile.am is still a
    // Makefile. A known extension still wins, and so does prose, so Makefile.py reads as
    // Python and Makefile.md as plain text.
    init?(path: String) {
        let fileName = (path as NSString).lastPathComponent
        let name = fileName.lowercased()
        let fileExtension = (fileName as NSString).pathExtension
        if ["makefile", "gnumakefile", "bsdmakefile"].contains(name) {
            self = .makefile
        } else if let language = CodeLanguage(fileExtension: fileExtension) {
            self = language
        } else if name.hasPrefix("makefile."),
                  !["md", "markdown", "txt", "rst"].contains(fileExtension.lowercased()) {
            self = .makefile
        } else {
            return nil
        }
    }

    private init?(name: String) {
        switch name {
        case "swift": self = .swift
        case "json", "jsonc", "json5": self = .json
        case "jsonnet", "libsonnet": self = .jsonnet
        case "yaml", "yml": self = .yaml
        case "bash", "sh", "zsh", "shell", "fish", "shellscript": self = .shell
        case "python", "py", "python3": self = .python
        case "javascript", "js", "mjs", "cjs", "typescript", "ts", "jsx", "tsx": self = .javascript
        case "java": self = .java
        case "kotlin", "kt", "kts": self = .kotlin
        case "go", "golang": self = .go
        case "rust", "rs": self = .rust
        case "html", "htm", "xml", "svg", "xhtml", "plist", "xib", "storyboard": self = .markup
        case "sql", "postgres", "postgresql", "mysql", "sqlite", "psql": self = .sql
        case "make", "makefile", "mk", "mak": self = .makefile
        case "c", "h", "cpp", "hpp", "cc", "hh", "cxx", "m", "mm", "cs", "scala",
             "groovy", "gradle", "php", "dart", "proto": self = .cLike
        default: return nil
        }
    }
}

// The token colours, kept adaptive so they read on both the light and dark canvas. The
// hues are borrowed from colours already in the app - the response pane's amber and
// green, the project wheel's plum and teal - so highlighted code sits in the same family
// as everything around it.
enum CodeStyle {
    static let comment = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.44, green: 0.46, blue: 0.42, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.57, blue: 0.52, alpha: 1))
    static let string = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.541, green: 0.365, blue: 0.063, alpha: 1),
        dark: NSColor(srgbRed: 0.878, green: 0.690, blue: 0.290, alpha: 1))
    static let number = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.184, green: 0.420, blue: 0.227, alpha: 1),
        dark: NSColor(srgbRed: 0.498, green: 0.690, blue: 0.541, alpha: 1))
    static let keyword = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.420, green: 0.267, blue: 0.533, alpha: 1),
        dark: NSColor(srgbRed: 0.643, green: 0.482, blue: 0.753, alpha: 1))
    static let type = Theme.adaptiveNSColor(
        light: NSColor(srgbRed: 0.118, green: 0.431, blue: 0.431, alpha: 1),
        dark: NSColor(srgbRed: 0.247, green: 0.647, blue: 0.647, alpha: 1))

    static func nsColor(for kind: CodeHighlight.Kind) -> NSColor {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        }
    }

    static func color(for kind: CodeHighlight.Kind) -> Color {
        Color(nsColor: nsColor(for: kind))
    }
}

// A line-friendly tokenizer, not a grammar. Each line is scanned on its own, and the only
// thing carried from one line to the next is whether it ended inside a block comment, a
// multi-line string, or a markup tag. That keeps the work linear and lets a caller start
// anywhere in a file, as long as it knows the state that line starts in.
enum CodeHighlight {

    enum Kind: Sendable, Equatable {
        case comment, string, number, keyword, type
    }

    // What a line can leave open for the next one. A plain quote never spans lines: an
    // unterminated string colours its own line and lets go, so one stray quote cannot
    // poison the rest of a file.
    enum State: Sendable, Equatable {
        case normal
        case blockComment(depth: Int)
        case string(quote: Character, triple: Bool)
        // A string where a doubled quote stands for the quote and a backslash is just a
        // backslash, like Jsonnet's @'...'.
        case verbatimString(quote: Character)
        // A Jsonnet ||| block. The indent is that of its first line of text, nil until
        // that line is seen.
        case textBlock(indent: String?)
        case tag
    }

    struct Token: Sendable, Equatable {
        let range: Range<String.Index>
        let kind: Kind
    }

    // Colouring is for code a person reads; past this size plain text is also much
    // cheaper to lay out.
    static let sizeLimit = 100_000

    // MARK: - Rendering

    static func highlight(_ code: String, tag: String?) -> AttributedString {
        guard let language = CodeLanguage(tag: tag) else { return AttributedString(code) }
        return highlight(code, language: language)
    }

    static func highlight(_ code: String, language: CodeLanguage) -> AttributedString {
        guard code.utf8.count <= sizeLimit else { return AttributedString(code) }
        var state = State.normal
        return highlight(code, language: language, state: &state)
    }

    static func highlight(_ code: String, language: CodeLanguage,
                          state: inout State) -> AttributedString {
        var result = AttributedString()
        var first = true
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { result += AttributedString("\n") }
            first = false
            result += highlightedLine(line, language: language, state: &state)
        }
        return result
    }

    private static func highlightedLine(_ line: Substring, language: CodeLanguage,
                                        state: inout State) -> AttributedString {
        let tokens = tokens(in: line, language: language, state: &state)
        guard !tokens.isEmpty else { return AttributedString(String(line)) }
        var result = AttributedString()
        var i = line.startIndex
        for token in tokens {
            if i < token.range.lowerBound {
                result += AttributedString(String(line[i..<token.range.lowerBound]))
            }
            var run = AttributedString(String(line[token.range]))
            run.foregroundColor = CodeStyle.color(for: token.kind)
            result += run
            i = token.range.upperBound
        }
        if i < line.endIndex {
            result += AttributedString(String(line[i...]))
        }
        return result
    }

    // The state each line starts in, for callers that draw a file in chunks and need to
    // pick up colouring mid-document without scanning from the top every time.
    static func lineStartStates(_ lines: [String], language: CodeLanguage) -> [State] {
        var states: [State] = []
        states.reserveCapacity(lines.count)
        var state = State.normal
        for line in lines {
            states.append(state)
            _ = tokens(in: line[...], language: language, state: &state)
        }
        return states
    }

    // MARK: - Tokenizing

    static func tokens(in line: Substring, language: CodeLanguage,
                       state: inout State) -> [Token] {
        if language == .markup { return markupTokens(in: line, state: &state) }
        if language == .makefile { return makeTokens(in: line, state: &state) }
        let rules = rules(for: language)
        var tokens: [Token] = []
        var i = line.startIndex

        // Finish whatever the previous line left open before reading fresh code.
        switch state {
        case .blockComment(let depth):
            let start = i
            scanBlockComment(line, from: &i, depth: depth, rules: rules, state: &state)
            if start < i { tokens.append(Token(range: start..<i, kind: .comment)) }
        case .string(let quote, let triple):
            let start = i
            scanString(line, from: &i, quote: quote, triple: triple, rules: rules, state: &state)
            if start < i { tokens.append(Token(range: start..<i, kind: .string)) }
        case .verbatimString(let quote):
            let start = i
            scanVerbatimString(line, from: &i, quote: quote, rules: rules, state: &state)
            if start < i { tokens.append(Token(range: start..<i, kind: .string)) }
        case .textBlock(let indent):
            let start = i
            scanTextBlockLine(line, from: &i, indent: indent, state: &state)
            if start < i { tokens.append(Token(range: start..<i, kind: .string)) }
        case .tag, .normal:
            state = .normal
        }

        while i < line.endIndex {
            let c = line[i]

            if rules.lineComments.contains(where: { matches(line, at: i, $0) }),
               c != "#" || !rules.hashNeedsBoundary || hashCommentStarts(line, at: i) {
                tokens.append(Token(range: i..<line.endIndex, kind: .comment))
                i = line.endIndex
                break
            }

            if let (open, _) = rules.blockComment, matches(line, at: i, open) {
                let start = i
                i = line.index(i, offsetBy: open.count)
                scanBlockComment(line, from: &i, depth: 1, rules: rules, state: &state)
                tokens.append(Token(range: start..<i, kind: .comment))
                continue
            }

            // A ||| opens a text block only when nothing but a - follows it on the line,
            // as Jsonnet requires. That keeps the closing ||| at the top of a diff hunk
            // from opening a block that colours the rest of the hunk as text.
            if rules.textBlocks, c == "|", matches(line, at: i, "|||") {
                var j = line.index(i, offsetBy: 3)
                if j < line.endIndex, line[j] == "-" { j = line.index(after: j) }
                if line[j...].allSatisfy({ $0 == " " || $0 == "\t" }) {
                    tokens.append(Token(range: i..<line.endIndex, kind: .string))
                    state = .textBlock(indent: nil)
                    i = line.endIndex
                    break
                }
            }

            if rules.verbatimStrings, c == "@" {
                let quoteIndex = line.index(after: i)
                if quoteIndex < line.endIndex, rules.quotes.contains(line[quoteIndex]) {
                    let start = i
                    i = line.index(after: quoteIndex)
                    scanVerbatimString(line, from: &i, quote: line[quoteIndex], rules: rules,
                                       state: &state)
                    tokens.append(Token(range: start..<i, kind: .string))
                    continue
                }
            }

            if rules.quotes.contains(c) {
                let start = i
                var triple = false
                if rules.tripleQuotes, matches(line, at: i, String(repeating: c, count: 3)) {
                    triple = true
                    i = line.index(i, offsetBy: 3)
                } else {
                    i = line.index(after: i)
                }
                scanString(line, from: &i, quote: c, triple: triple, rules: rules, state: &state)
                tokens.append(Token(range: start..<i, kind: .string))
                continue
            }

            // A digit here is a literal: identifiers below swallow their own digits, so
            // the 9 in file9 never reaches this branch.
            if c.isNumber {
                let start = i
                scanNumber(line, from: &i)
                tokens.append(Token(range: start..<i, kind: .number))
                continue
            }

            if rules.keywordSymbols.contains(c) {
                let next = line.index(after: i)
                tokens.append(Token(range: i..<next, kind: .keyword))
                i = next
                continue
            }

            if c.isLetter || c == "_" {
                let start = i
                var j = line.index(after: i)
                while j < line.endIndex,
                      line[j].isLetter || line[j].isNumber || line[j] == "_" {
                    j = line.index(after: j)
                }
                let word = line[start..<j]
                let key = rules.caseInsensitiveKeywords ? word.lowercased() : String(word)
                if rules.keywords.contains(key) {
                    tokens.append(Token(range: start..<j, kind: .keyword))
                } else if rules.typesByCase, c.isUppercase {
                    tokens.append(Token(range: start..<j, kind: .type))
                } else if rules.fieldNames, fieldStartPrecedes(line, at: start),
                          fieldColonFollows(line, at: j) {
                    tokens.append(Token(range: start..<j, kind: .type))
                }
                i = j
                continue
            }

            i = line.index(after: i)
        }
        return tokens
    }

    // MARK: - Scanners

    private static func matches(_ line: Substring, at start: String.Index, _ token: String) -> Bool {
        var i = start
        for ch in token {
            guard i < line.endIndex, line[i] == ch else { return false }
            i = line.index(after: i)
        }
        return true
    }

    // A # opens a comment only on a word boundary, so a colour code or ${#name} in shell
    // and yaml keeps its own reading.
    private static func hashCommentStarts(_ line: Substring, at i: String.Index) -> Bool {
        i == line.startIndex || line[line.index(before: i)].isWhitespace
    }

    // A Jsonnet field name starts a line or comes right after the { or , before it. Other
    // names followed by a colon are not fields: the condition in `assert ok : msg`, or
    // the bound in a slice like `x[start:end]`.
    private static func fieldStartPrecedes(_ line: Substring, at start: String.Index) -> Bool {
        var i = start
        while i > line.startIndex {
            i = line.index(before: i)
            let c = line[i]
            if c == " " || c == "\t" { continue }
            return c == "{" || c == ","
        }
        return true
    }

    // A Jsonnet field name is followed by :, :: or :::, or by +: and its kin when the
    // field adds to an inherited one.
    private static func fieldColonFollows(_ line: Substring, at start: String.Index) -> Bool {
        var i = start
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        if i < line.endIndex, line[i] == "+" { i = line.index(after: i) }
        return i < line.endIndex && line[i] == ":"
    }

    private static func scanBlockComment(_ line: Substring, from i: inout String.Index,
                                         depth: Int, rules: Rules, state: inout State) {
        guard let (open, close) = rules.blockComment else {
            i = line.endIndex
            state = .normal
            return
        }
        var depth = depth
        while i < line.endIndex {
            if rules.nestsBlockComments, matches(line, at: i, open) {
                depth += 1
                i = line.index(i, offsetBy: open.count)
            } else if matches(line, at: i, close) {
                depth -= 1
                i = line.index(i, offsetBy: close.count)
                if depth == 0 {
                    state = .normal
                    return
                }
            } else {
                i = line.index(after: i)
            }
        }
        state = .blockComment(depth: depth)
    }

    // Called with i just past the opening quote or quotes.
    private static func scanString(_ line: Substring, from i: inout String.Index,
                                   quote: Character, triple: Bool,
                                   rules: Rules, state: inout State) {
        let escapes = !rules.rawQuotes.contains(quote)
        let terminator = String(repeating: quote, count: triple ? 3 : 1)
        while i < line.endIndex {
            if escapes, line[i] == "\\" {
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
            } else if matches(line, at: i, terminator) {
                i = line.index(i, offsetBy: terminator.count)
                state = .normal
                return
            } else {
                i = line.index(after: i)
            }
        }
        state = triple || rules.multilineQuotes.contains(quote)
            ? .string(quote: quote, triple: triple)
            : .normal
    }

    // Called with i just past the opening quote.
    private static func scanVerbatimString(_ line: Substring, from i: inout String.Index,
                                           quote: Character, rules: Rules, state: inout State) {
        while i < line.endIndex {
            guard line[i] == quote else {
                i = line.index(after: i)
                continue
            }
            i = line.index(after: i)
            guard i < line.endIndex, line[i] == quote else {
                state = .normal
                return
            }
            i = line.index(after: i)
        }
        state = rules.multilineQuotes.contains(quote) ? .verbatimString(quote: quote) : .normal
    }

    // A text block ends at the first line indented less than its first line of text, and
    // that line starts with the closing |||. A ||| at the body's own indent is still text.
    private static func scanTextBlockLine(_ line: Substring, from i: inout String.Index,
                                          indent: String?, state: inout State) {
        let text = line.drop { $0 == " " || $0 == "\t" }
        let lead = line[..<text.startIndex]
        // Blank lines belong to the block whatever their indent.
        if text.isEmpty {
            i = line.endIndex
            return
        }
        if let indent, line.hasPrefix(indent) {
            i = line.endIndex
            return
        }
        // Jsonnet needs the first line of text to be indented, and takes that indent for
        // the whole block.
        if indent == nil, !lead.isEmpty {
            state = .textBlock(indent: String(lead))
            i = line.endIndex
            return
        }
        // A line that leaves the block without a ||| is broken code. Ending the block
        // there still reads the rest of the file as code.
        state = .normal
        if text.hasPrefix("|||") { i = line.index(text.startIndex, offsetBy: 3) }
    }

    private static func scanNumber(_ line: Substring, from i: inout String.Index) {
        let start = i
        i = line.index(after: i)
        // A based literal carries its letters: 0xFF or 0b1010 is one number.
        if line[start] == "0", i < line.endIndex, "xXbBoO".contains(line[i]) {
            i = line.index(after: i)
            while i < line.endIndex, line[i].isHexDigit || line[i] == "_" {
                i = line.index(after: i)
            }
            return
        }
        var seenDot = false
        while i < line.endIndex {
            let c = line[i]
            if c.isNumber || c == "_" {
                i = line.index(after: i)
            } else if c == ".", !seenDot {
                let next = line.index(after: i)
                guard next < line.endIndex, line[next].isNumber else { break }
                seenDot = true
                i = line.index(after: next)
            } else if c == "e" || c == "E" {
                var j = line.index(after: i)
                if j < line.endIndex, line[j] == "+" || line[j] == "-" { j = line.index(after: j) }
                guard j < line.endIndex, line[j].isNumber else { break }
                i = j
            } else {
                break
            }
        }
    }

    // Markup is its own little machine: strings and numbers only mean anything inside a
    // tag, so prose with an apostrophe in it stays prose.
    private static func markupTokens(in line: Substring, state: inout State) -> [Token] {
        var tokens: [Token] = []
        var i = line.startIndex

        // Runs to the close of an open comment and files it from `start`, so the `<!--`
        // that opened it on this line lands in the same token.
        func scanCommentClose(from start: Substring.Index) {
            while i < line.endIndex, !matches(line, at: i, "-->") { i = line.index(after: i) }
            if i < line.endIndex {
                i = line.index(i, offsetBy: 3)
                state = .normal
            } else {
                state = .blockComment(depth: 1)
            }
            if start < i { tokens.append(Token(range: start..<i, kind: .comment)) }
        }

        switch state {
        case .blockComment:
            scanCommentClose(from: i)
        case .string(let quote, _):
            let start = i
            while i < line.endIndex, line[i] != quote { i = line.index(after: i) }
            if i < line.endIndex {
                i = line.index(after: i)
                state = .tag
            }
            if start < i { tokens.append(Token(range: start..<i, kind: .string)) }
        case .tag, .normal, .verbatimString, .textBlock:
            break
        }

        while i < line.endIndex {
            let c = line[i]
            if state == .tag {
                if c == "\"" || c == "'" {
                    let start = i
                    i = line.index(after: i)
                    while i < line.endIndex, line[i] != c { i = line.index(after: i) }
                    if i < line.endIndex {
                        i = line.index(after: i)
                    } else {
                        state = .string(quote: c, triple: false)
                    }
                    tokens.append(Token(range: start..<i, kind: .string))
                } else if c == ">" {
                    state = .normal
                    i = line.index(after: i)
                } else if c.isNumber {
                    let start = i
                    scanNumber(line, from: &i)
                    tokens.append(Token(range: start..<i, kind: .number))
                } else {
                    i = line.index(after: i)
                }
                continue
            }

            if matches(line, at: i, "<!--") {
                let start = i
                i = line.index(i, offsetBy: 4)
                scanCommentClose(from: start)
                continue
            }

            // Only a < that actually opens a tag counts, so "a < b" in text stays text.
            if c == "<" {
                var j = line.index(after: i)
                if j < line.endIndex, line[j] == "/" || line[j] == "!" || line[j] == "?" {
                    j = line.index(after: j)
                }
                let nameStart = j
                while j < line.endIndex,
                      line[j].isLetter || line[j].isNumber
                        || line[j] == "-" || line[j] == ":" || line[j] == "_" {
                    j = line.index(after: j)
                }
                if nameStart < j {
                    tokens.append(Token(range: nameStart..<j, kind: .keyword))
                    state = .tag
                    i = j
                    continue
                }
            }

            i = line.index(after: i)
        }
        return tokens
    }

    // Make is two languages on one page. A line that starts with a tab is a recipe, which
    // is shell; every other line is Make's own: a directive, an assignment or a rule.
    // Both carry $(VAR) references, which Make expands before the shell sees the line,
    // so those are coloured over whatever the shell reading put there. Nothing is carried
    // from one line to the next, so a continued line is read on its own.
    private static func makeTokens(in line: Substring, state: inout State) -> [Token] {
        state = .normal
        let text = line.drop { $0 == " " || $0 == "\t" }
        if line.first == "\t", !makeLineInRecipePosition(text) {
            return makeRecipeTokens(in: text)
        }

        var commentStart = text.endIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "#", i == text.startIndex || text[text.index(before: i)] != "\\" {
                commentStart = i
                break
            }
            i = text.index(after: i)
        }
        let code = text[..<commentStart]
        var tokens: [Token] = []
        var rest = code

        // Directives lead the line, and some stack: `export override NAME := value`.
        var lastDirective: String?
        while let word = makeLeadingWord(rest), makeDirectives.contains(String(word)) {
            tokens.append(Token(range: word.startIndex..<word.endIndex, kind: .keyword))
            lastDirective = String(word)
            rest = rest[word.endIndex...].drop { $0 == " " || $0 == "\t" }
        }

        if let name = makeAssignment(in: rest)?.name {
            tokens.append(Token(range: name, kind: .type))
            tokens += makeValueTokens(in: rest[name.upperBound...])
        } else if let lastDirective, makeNamingDirectives.contains(lastDirective),
                  let name = makeLeadingWord(rest), !name.contains("$") {
            tokens.append(Token(range: name.startIndex..<name.endIndex, kind: .type))
        } else if lastDirective == nil, text.startIndex == line.startIndex,
                  let colon = makeRuleColon(in: rest) {
            for target in rest[..<colon].split(whereSeparator: { $0 == " " || $0 == "\t" })
            where !target.contains("$") && target != "&" {
                let special = target.count > 1 && target.first == "."
                    && target.dropFirst().allSatisfy { $0.isUppercase || $0 == "_" }
                tokens.append(Token(range: target.startIndex..<target.endIndex,
                                    kind: special ? .keyword : .type))
            }
            // A ; ends the prerequisites and starts a recipe on the same line.
            let after = rest[colon...]
            if let semicolon = after.firstIndex(of: ";") {
                tokens += makeRecipeTokens(in: after[after.index(after: semicolon)...])
            }
        } else {
            // What is left is a value: an include list, a condition, or a value
            // continued from the line above. An indented line is never read as a rule,
            // since it is most likely such a continuation.
            tokens += makeValueTokens(in: rest)
        }

        tokens = overlay(makeReferences(in: code), on: tokens)
        if commentStart < text.endIndex {
            tokens.append(Token(range: commentStart..<text.endIndex, kind: .comment))
        }
        return tokens
    }

    // A tab-led line is a recipe only inside a rule, which a single line cannot tell. A
    // directive or an assignment written the way Make writes them is read as Make, so a
    // block indented under an ifeq keeps its colours. `NAME=value cmd` with no spaces is
    // the shell setting a variable for one command, and stays shell.
    private static func makeLineInRecipePosition(_ text: Substring) -> Bool {
        if let word = makeLeadingWord(text), makeDirectives.contains(String(word)) { return true }
        guard let assignment = makeAssignment(in: text) else { return false }
        return assignment.op != "=" || assignment.spaced
    }

    private static func makeLeadingWord(_ text: Substring) -> Substring? {
        let word = text.prefix { !$0.isWhitespace && $0 != "(" }
        return word.isEmpty ? nil : word
    }

    // The name and operator of `NAME = value` and its kin: :=, ::=, :::=, ?=, += and !=.
    private static func makeAssignment(
        in text: Substring
    ) -> (name: Range<String.Index>, op: String, spaced: Bool)? {
        let name = text.prefix { !$0.isWhitespace && !"=:?+!#$(){}".contains($0) }
        guard !name.isEmpty else { return nil }
        let afterName = text[name.endIndex...]
        let rest = afterName.drop { $0 == " " || $0 == "\t" }
        for op in [":::=", "::=", ":=", "?=", "+=", "!=", "="] where rest.hasPrefix(op) {
            return (name.startIndex..<name.endIndex, op, rest.startIndex > afterName.startIndex)
        }
        return nil
    }

    // The colon that ends a rule's targets. One inside a reference, as in $(SRC:.c=.o),
    // belongs to the reference.
    private static func makeRuleColon(in text: Substring) -> String.Index? {
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            switch text[i] {
            case "(", "{": depth += 1
            case ")", "}": depth = max(0, depth - 1)
            case ":" where depth == 0: return i
            default: break
            }
            i = text.index(after: i)
        }
        return nil
    }

    // A recipe is shell, with Make's own marks in front: @ hides the command, - ignores
    // its failure and + runs it even under make -n.
    private static func makeRecipeTokens(in text: Substring) -> [Token] {
        let marks = text.prefix { "@-+".contains($0) }
        var tokens: [Token] = []
        if !marks.isEmpty {
            tokens.append(Token(range: marks.startIndex..<marks.endIndex, kind: .keyword))
        }
        let command = text[marks.endIndex...]
        var state = State.normal
        tokens += CodeHighlight.tokens(in: command, language: .shell, state: &state)
        return overlay(makeReferences(in: command), on: tokens)
    }

    // Make gives quotes no meaning, so only a string that closes on its line is coloured.
    // An apostrophe in `MESSAGE = don't` stays text.
    private static func makeValueTokens(in text: Substring) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" || c == "'" {
                let open = i
                if let close = text[text.index(after: i)...].firstIndex(of: c) {
                    i = text.index(after: close)
                    tokens.append(Token(range: open..<i, kind: .string))
                } else {
                    i = text.index(after: i)
                }
            } else if c.isNumber {
                let start = i
                scanNumber(text, from: &i)
                tokens.append(Token(range: start..<i, kind: .number))
            } else if c.isLetter || c == "_" || c == "-" || c == "." {
                // Words swallow their own digits, so the 2 in -O2 is not a number.
                i = text.index(after: i)
                while i < text.endIndex,
                      text[i].isLetter || text[i].isNumber || "_-.".contains(text[i]) {
                    i = text.index(after: i)
                }
            } else {
                i = text.index(after: i)
            }
        }
        return tokens
    }

    // Every $ reference on the line, nested ones included, in order. A variable is
    // coloured as a type; a function such as $(patsubst ...) and an automatic variable
    // such as $@ as a keyword. When a reference holds more than a name, only its head and
    // closing bracket are marked, so its arguments keep their own colours.
    private static func makeReferences(in text: Substring) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        scanMakeReferences(text, from: &i, until: nil, into: &tokens)
        return tokens
    }

    // Stops at the `close` bracket that ends the reference being read, or at the end of
    // the line.
    private static func scanMakeReferences(_ text: Substring, from i: inout String.Index,
                                           until close: Character?, into tokens: inout [Token]) {
        var depth = 0
        while i < text.endIndex {
            let c = text[i]
            if let close, c == close {
                if depth == 0 { return }
                depth -= 1
            } else if let close, c == (close == ")" ? "(" : "{") {
                depth += 1
            }
            guard c == "$" else {
                i = text.index(after: i)
                continue
            }
            let start = i
            i = text.index(after: i)
            guard i < text.endIndex else { return }
            let next = text[i]
            if next == "(" || next == "{" {
                let closer: Character = next == "(" ? ")" : "}"
                i = text.index(after: i)
                let name = text[i...].prefix { !$0.isWhitespace && !":=,$(){}".contains($0) }
                i = name.endIndex
                let isFunction = i < text.endIndex && text[i].isWhitespace
                    && makeFunctions.contains(String(name))
                let isAutomatic = name.count <= 2 && name.first.map { makeAutomatic.contains($0) } == true
                let kind: Kind = isFunction || isAutomatic ? .keyword : .type
                let headEnd = i
                var inner: [Token] = []
                scanMakeReferences(text, from: &i, until: closer, into: &inner)
                guard i < text.endIndex else {
                    tokens.append(Token(range: start..<headEnd, kind: kind))
                    tokens += inner
                    return
                }
                let end = text.index(after: i)
                if headEnd == i {
                    tokens.append(Token(range: start..<end, kind: kind))
                } else {
                    tokens.append(Token(range: start..<headEnd, kind: kind))
                    tokens += inner
                    tokens.append(Token(range: i..<end, kind: kind))
                }
                i = end
            } else if makeAutomatic.contains(next) {
                i = text.index(after: i)
                tokens.append(Token(range: start..<i, kind: .keyword))
            } else if next.isLetter || next.isNumber || next == "_" {
                i = text.index(after: i)
                tokens.append(Token(range: start..<i, kind: .type))
            } else if next == "$" {
                // $$ is a literal $ handed to the shell.
                i = text.index(after: i)
            }
        }
    }

    // Lays `top` over `base`, cutting a base token wherever a top token covers it. Both
    // come in order without overlaps of their own.
    private static func overlay(_ top: [Token], on base: [Token]) -> [Token] {
        guard !top.isEmpty else { return base }
        var out: [Token] = []
        for token in base {
            var lower = token.range.lowerBound
            for cover in top {
                guard lower < token.range.upperBound else { break }
                guard cover.range.overlaps(lower..<token.range.upperBound) else { continue }
                if lower < cover.range.lowerBound {
                    out.append(Token(range: lower..<cover.range.lowerBound, kind: token.kind))
                }
                lower = cover.range.upperBound
            }
            if lower < token.range.upperBound {
                out.append(Token(range: lower..<token.range.upperBound, kind: token.kind))
            }
        }
        return (out + top).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static let makeDirectives: Set<String> = [
        "define", "endef", "undefine", "ifdef", "ifndef", "ifeq", "ifneq", "else", "endif",
        "include", "-include", "sinclude", "override", "export", "unexport", "private",
        "vpath", "load", "-load"
    ]

    // Directives whose next word is a variable name.
    private static let makeNamingDirectives: Set<String> = [
        "define", "undefine", "ifdef", "ifndef", "export", "unexport"
    ]

    private static let makeFunctions: Set<String> = [
        "abspath", "addprefix", "addsuffix", "and", "basename", "call", "dir", "error",
        "eval", "file", "filter", "filter-out", "findstring", "firstword", "flavor",
        "foreach", "guile", "if", "info", "intcmp", "join", "lastword", "let", "notdir",
        "or", "origin", "patsubst", "realpath", "shell", "sort", "strip", "subst",
        "suffix", "value", "warning", "wildcard", "word", "wordlist", "words"
    ]

    // The automatic variables, which also come as $(@D), $(<F) and the like.
    private static let makeAutomatic: Set<Character> = ["@", "<", "^", "+", "?", "*", "%", "|"]

    // MARK: - Rules

    private struct Rules: Sendable {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var nestsBlockComments = false
        var quotes: [Character] = ["\""]
        var tripleQuotes = false
        // Jsonnet's ||| text blocks and @'...' verbatim strings.
        var textBlocks = false
        var verbatimStrings = false
        // Whether a # needs a word boundary to open a comment. Where # means nothing
        // else, as in Jsonnet, it opens one anywhere.
        var hashNeedsBoundary = true
        // Quotes whose strings run across lines even without tripling: raw strings in Go,
        // template literals in JavaScript.
        var multilineQuotes: [Character] = []
        // Quotes with no escape character, so a backslash inside is just a backslash.
        var rawQuotes: [Character] = []
        var keywords: Set<String> = []
        var caseInsensitiveKeywords = false
        var typesByCase = false
        // Single characters read as keywords, like Jsonnet's $ for the outermost object.
        var keywordSymbols: [Character] = []
        // Whether a name followed by a colon is an object field, coloured like a type.
        var fieldNames = false
    }

    private static func rules(for language: CodeLanguage) -> Rules {
        switch language {
        case .swift: swiftRules
        case .json: jsonRules
        case .jsonnet: jsonnetRules
        case .yaml: yamlRules
        case .shell, .makefile: shellRules
        case .python: pythonRules
        case .javascript: javascriptRules
        case .java: javaRules
        case .kotlin: kotlinRules
        case .go: goRules
        case .rust: rustRules
        case .sql: sqlRules
        case .markup, .cLike: cLikeRules
        }
    }

    private static let swiftRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        nestsBlockComments: true,
        quotes: ["\""],
        tripleQuotes: true,
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
            "catch", "class", "continue", "convenience", "default", "defer", "deinit",
            "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false",
            "fileprivate", "final", "for", "func", "guard", "if", "import", "in",
            "indirect", "infix", "init", "inout", "internal", "is", "lazy", "let",
            "mutating", "nil", "nonisolated", "open", "operator", "override", "postfix",
            "prefix", "private", "protocol", "public", "repeat", "required", "rethrows",
            "return", "self", "some", "static", "struct", "subscript", "super", "switch",
            "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
            "where", "while", "willSet"
        ],
        typesByCase: true)

    private static let jsonRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\""],
        keywords: ["true", "false", "null"])

    // Jsonnet strings may run across lines, so both quotes are multi-line. Field names
    // are coloured, as in the Grafana grammar for VS Code, because they carry the shape
    // of the object the file builds.
    private static let jsonnetRules = Rules(
        lineComments: ["//", "#"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'"],
        textBlocks: true,
        verbatimStrings: true,
        hashNeedsBoundary: false,
        multilineQuotes: ["\"", "'"],
        keywords: [
            "assert", "else", "error", "false", "for", "function", "if", "import",
            "importbin", "importstr", "in", "local", "null", "self", "super",
            "tailstrict", "then", "true"
        ],
        keywordSymbols: ["$"],
        fieldNames: true)

    private static let yamlRules = Rules(
        lineComments: ["#"],
        quotes: ["\"", "'"],
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        caseInsensitiveKeywords: true)

    private static let shellRules = Rules(
        lineComments: ["#"],
        quotes: ["\"", "'"],
        keywords: [
            "alias", "break", "case", "cd", "continue", "do", "done", "echo", "elif",
            "else", "esac", "exit", "export", "fi", "for", "function", "if", "in",
            "local", "readonly", "return", "select", "set", "shift", "source", "then",
            "trap", "unset", "until", "while"
        ])

    private static let pythonRules = Rules(
        lineComments: ["#"],
        quotes: ["\"", "'"],
        tripleQuotes: true,
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
            "if", "import", "in", "is", "lambda", "match", "None", "nonlocal", "not",
            "or", "pass", "raise", "return", "self", "True", "try", "while", "with",
            "yield"
        ],
        typesByCase: true)

    private static let javascriptRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'", "`"],
        multilineQuotes: ["`"],
        keywords: [
            "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
            "extends", "false", "finally", "for", "from", "function", "get", "if",
            "implements", "import", "in", "instanceof", "interface", "let", "new",
            "null", "of", "private", "protected", "public", "readonly", "return", "set",
            "static", "super", "switch", "this", "throw", "true", "try", "type",
            "typeof", "undefined", "var", "void", "while", "with", "yield"
        ],
        typesByCase: true)

    private static let javaRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'"],
        tripleQuotes: true,
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
            "class", "const", "continue", "default", "do", "double", "else", "enum",
            "extends", "false", "final", "finally", "float", "for", "if", "implements",
            "import", "instanceof", "int", "interface", "long", "native", "new", "null",
            "package", "permits", "private", "protected", "public", "record", "return",
            "sealed", "short", "static", "strictfp", "super", "switch", "synchronized",
            "this", "throw", "throws", "transient", "true", "try", "var", "void",
            "volatile", "while", "yield"
        ],
        typesByCase: true)

    private static let kotlinRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        nestsBlockComments: true,
        quotes: ["\"", "'"],
        tripleQuotes: true,
        keywords: [
            "abstract", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "data", "do", "else", "enum", "false", "final",
            "finally", "for", "fun", "if", "import", "in", "init", "inline", "interface",
            "internal", "is", "it", "lateinit", "null", "object", "open", "operator",
            "out", "override", "package", "private", "protected", "public", "return",
            "sealed", "super", "suspend", "this", "throw", "true", "try", "typealias",
            "val", "var", "when", "where", "while"
        ],
        typesByCase: true)

    private static let goRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'", "`"],
        multilineQuotes: ["`"],
        rawQuotes: ["`"],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "false", "for", "func", "go", "goto", "if", "import",
            "interface", "iota", "map", "nil", "package", "range", "return", "select",
            "struct", "switch", "true", "type", "var"
        ],
        typesByCase: true)

    // Rust has no ' in its quote list: a lifetime like 'a would read as a string that
    // never closes and take the rest of the line with it.
    private static let rustRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        nestsBlockComments: true,
        quotes: ["\""],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
            "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
            "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static",
            "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"
        ],
        typesByCase: true)

    private static let sqlRules = Rules(
        lineComments: ["--"],
        blockComment: ("/*", "*/"),
        quotes: ["'", "\""],
        keywords: [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case",
            "check", "column", "commit", "constraint", "create", "cross", "database",
            "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
            "false", "foreign", "from", "full", "group", "having", "in", "index",
            "inner", "insert", "into", "is", "join", "key", "left", "like", "limit",
            "not", "null", "offset", "on", "or", "order", "outer", "primary",
            "references", "returning", "right", "rollback", "select", "set", "table",
            "then", "transaction", "true", "union", "unique", "update", "values",
            "view", "when", "where", "with"
        ],
        caseInsensitiveKeywords: true)

    private static let cLikeRules = Rules(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'"],
        keywords: [
            "auto", "bool", "break", "case", "catch", "char", "class", "const",
            "continue", "default", "delete", "do", "double", "else", "enum", "extern",
            "false", "final", "finally", "float", "for", "goto", "if", "import",
            "include", "inline", "int", "interface", "long", "namespace", "new", "null",
            "nullptr", "operator", "override", "private", "protected", "public",
            "return", "short", "signed", "sizeof", "static", "struct", "switch",
            "template", "this", "throw", "true", "try", "typedef", "typename", "union",
            "unsigned", "using", "var", "virtual", "void", "volatile", "while"
        ],
        typesByCase: true)
}
