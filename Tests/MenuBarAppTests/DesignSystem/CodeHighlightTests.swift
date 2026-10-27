import SwiftUI
import Testing
@testable import MenuBarApp

// The tokenizer scans line by line, so what matters is that each token lands in the
// right kind, that markers inside strings and comments do not fool it, and that the
// state carried between lines keeps multi-line constructs whole.
struct CodeHighlightTests {

    private func tokens(_ code: String,
                        _ language: CodeLanguage) -> [(text: String, kind: CodeHighlight.Kind)] {
        var state = CodeHighlight.State.normal
        var out: [(String, CodeHighlight.Kind)] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            for token in CodeHighlight.tokens(in: line, language: language, state: &state) {
                out.append((String(line[token.range]), token.kind))
            }
        }
        return out
    }

    private func kind(of text: String, in code: String,
                      _ language: CodeLanguage) -> CodeHighlight.Kind? {
        tokens(code, language).first { $0.text == text }?.kind
    }

    // MARK: - Kinds

    @Test func tellsKeywordsTypesAndNumbersApart() {
        let code = "let count: Int = 42"
        #expect(kind(of: "let", in: code, .swift) == .keyword)
        #expect(kind(of: "Int", in: code, .swift) == .type)
        #expect(kind(of: "42", in: code, .swift) == .number)
        #expect(kind(of: "count", in: code, .swift) == nil)
    }

    @Test func stringHoldingACommentMarkerStaysAString() {
        let code = #"let s = "not // a comment""#
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == #""not // a comment""# && $0.kind == .string })
        #expect(!found.contains { $0.kind == .comment })
    }

    @Test func commentHoldingQuotesStaysAComment() {
        let code = #"// it's all "quoted" here"#
        let found = tokens(code, .swift)
        #expect(found.count == 1)
        #expect(found.first?.kind == .comment)
        #expect(found.first?.text == code)
    }

    @Test func escapedQuotesDoNotEndTheString() {
        let code = #"let s = "say \"hi\"" + tail"#
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == #""say \"hi\""# + "\"" && $0.kind == .string })
        // The identifier after the string is back outside it.
        #expect(!found.contains { $0.text.contains("tail") && $0.kind == .string })
    }

    @Test func digitsInsideIdentifiersAreNotNumbers() {
        let code = "let utf8 = file9"
        #expect(!tokens(code, .swift).contains { $0.kind == .number })
    }

    @Test func numberShapes() {
        #expect(kind(of: "0xFF", in: "mask = 0xFF", .python) == .number)
        #expect(kind(of: "1_000", in: "let n = 1_000", .swift) == .number)
        #expect(kind(of: "1.5e3", in: "x = 1.5e3", .python) == .number)
    }

    // MARK: - Multi-line state

    @Test func blockCommentSpansLines() {
        let code = "/* first\nstill inside\n*/ let x = 1"
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == "still inside" && $0.kind == .comment })
        #expect(found.contains { $0.text == "let" && $0.kind == .keyword })
    }

    @Test func nestedBlockCommentsNeedEveryClose() {
        let code = "/* outer /* inner */ still */ let x = 1"
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == "let" && $0.kind == .keyword })
        #expect(found.first?.kind == .comment)
        #expect(found.first?.text.contains("still") == true)
    }

    @Test func swiftMultilineStringSpansLines() {
        let code = "let s = \"\"\"\nlet not = keyword\n\"\"\"\nreturn s"
        let found = tokens(code, .swift)
        // The middle line is string, not code.
        #expect(found.contains { $0.text == "let not = keyword" && $0.kind == .string })
        #expect(found.contains { $0.text == "return" && $0.kind == .keyword })
    }

    @Test func pythonTripleQuotesSpanLines() {
        let code = "s = '''start\n# not a comment\n''' # real comment"
        let found = tokens(code, .python)
        #expect(found.contains { $0.text == "# not a comment" && $0.kind == .string })
        #expect(found.contains { $0.text == "# real comment" && $0.kind == .comment })
    }

    @Test func goRawStringSpansLinesWithoutEscapes() {
        // In a raw string the backslash is a plain character, so `a\` closes at the tick.
        let closing = tokens(#"s := `a\` + b"#, .go)
        #expect(closing.contains { $0.text == #"`a\`"# && $0.kind == .string })

        let spanning = tokens("s := `first\nsecond` + done", .go)
        #expect(spanning.contains { $0.text == "second`" && $0.kind == .string })
    }

    @Test func javascriptTemplateLiteralSpansLines() {
        let code = "const s = `line one\nline two`; return s"
        let found = tokens(code, .javascript)
        #expect(found.contains { $0.text == "line two`" && $0.kind == .string })
        #expect(found.contains { $0.text == "return" && $0.kind == .keyword })
    }

    @Test func unterminatedPlainStringLetsGoAtLineEnd() {
        let code = "let a = \"unterminated\nlet b = 2"
        let found = tokens(code, .swift)
        #expect(found.contains { $0.text == "b" } == false)
        #expect(found.count { $0.text == "let" && $0.kind == .keyword } == 2)
        #expect(found.contains { $0.text == "2" && $0.kind == .number })
    }

    @Test func lineStartStatesFollowOpenConstructs() {
        let states = CodeHighlight.lineStartStates(["/* open", "inside", "*/ done"],
                                                   language: .swift)
        #expect(states == [.normal, .blockComment(depth: 1), .blockComment(depth: 1)])
    }

    // MARK: - Per-language quirks

    @Test func hashCommentsNeedAWordBoundary() {
        let found = tokens("echo a#b # trailing", .shell)
        #expect(found.contains { $0.text == "# trailing" && $0.kind == .comment })
        #expect(!found.contains { $0.text.contains("a#b") && $0.kind == .comment })
    }

    @Test func shellKeywordsAndStrings() {
        let code = "if [ -f x ]; then echo 'done'; fi"
        #expect(kind(of: "if", in: code, .shell) == .keyword)
        #expect(kind(of: "fi", in: code, .shell) == .keyword)
        #expect(kind(of: "'done'", in: code, .shell) == .string)
    }

    @Test func yamlLiteralsIgnoreCase() {
        let code = "enabled: True\ncount: 3 # note"
        #expect(kind(of: "True", in: code, .yaml) == .keyword)
        #expect(kind(of: "3", in: code, .yaml) == .number)
        #expect(kind(of: "# note", in: code, .yaml) == .comment)
    }

    @Test func sqlKeywordsIgnoreCase() {
        let code = "SELECT id FROM users where name = 'ann' -- lookup"
        #expect(kind(of: "SELECT", in: code, .sql) == .keyword)
        #expect(kind(of: "where", in: code, .sql) == .keyword)
        #expect(kind(of: "'ann'", in: code, .sql) == .string)
        #expect(kind(of: "-- lookup", in: code, .sql) == .comment)
    }

    @Test func jsonColoursLiteralsAndStrings() {
        let code = #"{"name": "ada", "ok": true, "n": 12}"#
        #expect(kind(of: #""name""#, in: code, .json) == .string)
        #expect(kind(of: "true", in: code, .json) == .keyword)
        #expect(kind(of: "12", in: code, .json) == .number)
    }

    @Test func jsonnetColoursKeywordsCommentsAndStrings() {
        let code = "local name = 'ada'; # who\n{ [name]: if self.ok then 1 else null } // done"
        #expect(kind(of: "local", in: code, .jsonnet) == .keyword)
        #expect(kind(of: "'ada'", in: code, .jsonnet) == .string)
        #expect(kind(of: "# who", in: code, .jsonnet) == .comment)
        #expect(kind(of: "self", in: code, .jsonnet) == .keyword)
        #expect(kind(of: "null", in: code, .jsonnet) == .keyword)
        #expect(kind(of: "// done", in: code, .jsonnet) == .comment)
    }

    @Test func jsonnetTextBlockSpansLinesAndKeepsApostrophes() {
        let code = "{ text: |||\n  it's a \\ block\n|||, ok: a || b }"
        let found = tokens(code, .jsonnet)
        #expect(found.contains { $0.text == "|||" && $0.kind == .string })
        #expect(found.contains { $0.text == "  it's a \\ block" && $0.kind == .string })
        #expect(found.filter { $0.kind == .string }.count == 3)
    }

    @Test func jsonnetColoursFieldNamesAndTheRootObject() {
        let code = "{ name: $._config.name, hidden:: 1, base+: { x::: 2 }, n: f(a, b) }"
        #expect(kind(of: "name", in: code, .jsonnet) == .type)
        #expect(kind(of: "hidden", in: code, .jsonnet) == .type)
        #expect(kind(of: "base", in: code, .jsonnet) == .type)
        #expect(kind(of: "x", in: code, .jsonnet) == .type)
        #expect(kind(of: "$", in: code, .jsonnet) == .keyword)
        #expect(kind(of: "f", in: code, .jsonnet) == nil)
        #expect(kind(of: "_config", in: code, .jsonnet) == nil)
    }

    @Test func jsonnetColonsOutsideFieldsDoNotMakeFieldNames() {
        let code = "assert valid : 'bad config';\nlocal head = list[start:end];\n  indented: 1"
        #expect(kind(of: "valid", in: code, .jsonnet) == nil)
        #expect(kind(of: "start", in: code, .jsonnet) == nil)
        #expect(kind(of: "indented", in: code, .jsonnet) == .type)
    }

    @Test func jsonnetHashOpensACommentWithoutASpace() {
        let code = "{ a: 1,# trailing }"
        #expect(kind(of: "# trailing }", in: code, .jsonnet) == .comment)
    }

    @Test func jsonnetTextBlockEndsOnlyAtALessIndentedMarker() {
        let code = "  x: |||-\n    a ||| b\n    |||\n    it's\n\n  |||,\n  y: 'after'"
        let found = tokens(code, .jsonnet)
        #expect(found.contains { $0.text == "    a ||| b" && $0.kind == .string })
        #expect(found.contains { $0.text == "    |||" && $0.kind == .string })
        #expect(found.contains { $0.text == "    it's" && $0.kind == .string })
        #expect(found.contains { $0.text == "  |||" && $0.kind == .string })
        #expect(found.contains { $0.text == "'after'" && $0.kind == .string })
        #expect(found.contains { $0.text == "y" && $0.kind == .type })
    }

    @Test func jsonnetClosingMarkerAloneDoesNotOpenATextBlock() {
        let code = "|||,\n  name: 'x',"
        let found = tokens(code, .jsonnet)
        #expect(found.contains { $0.text == "name" && $0.kind == .type })
        #expect(found.contains { $0.text == "'x'" && $0.kind == .string })
    }

    @Test func jsonnetVerbatimStringsHaveNoEscapes() {
        let code = #"local p = @'C:\dir\'; local q = @"say ""hi"""; local x = 1"#
        let found = tokens(code, .jsonnet)
        #expect(found.contains { $0.text == #"@'C:\dir\'"# && $0.kind == .string })
        #expect(found.contains { $0.text == #"@"say ""hi""""# && $0.kind == .string })
        #expect(found.contains { $0.text == "1" && $0.kind == .number })
    }

    @Test func jsonnetStringsSpanLines() {
        let code = "msg: 'line one\n  # line two', next: 1"
        let found = tokens(code, .jsonnet)
        #expect(found.contains { $0.text == "  # line two'" && $0.kind == .string })
        #expect(!found.contains { $0.kind == .comment })
        #expect(found.contains { $0.text == "next" && $0.kind == .type })
    }

    @Test func rustLifetimesAreNotStrings() {
        let code = "fn get<'a>(x: &'a str) -> &'a str { x }"
        let found = tokens(code, .rust)
        #expect(!found.contains { $0.kind == .string })
        #expect(found.contains { $0.text == "fn" && $0.kind == .keyword })
    }

    // MARK: - Markup

    @Test func markupColoursTagsAndAttributeStrings() {
        let code = #"<div class="wide">it's 5 < 6 in here</div>"#
        let found = tokens(code, .markup)
        #expect(found.contains { $0.text == "div" && $0.kind == .keyword })
        #expect(found.contains { $0.text == #""wide""# && $0.kind == .string })
        // Prose between tags stays prose: no string from the apostrophe, no number.
        #expect(!found.contains { $0.text.contains("s 5 < 6") })
        #expect(!found.contains { $0.text == "5" })
    }

    @Test func markupCommentSpansLines() {
        let code = "<!-- first\nsecond -->\n<p>done</p>"
        let found = tokens(code, .markup)
        #expect(found.contains { $0.text == "second -->" && $0.kind == .comment })
        #expect(found.contains { $0.text == "p" && $0.kind == .keyword })
    }

    // MARK: - Make

    @Test func makeColoursAssignmentsRulesAndDirectives() {
        let code = """
        CFLAGS := -O2 -Wall # tuned
        .PHONY: all clean
        ifeq ($(OS),Darwin)
        endif
        build: main.o util.o
        """
        #expect(kind(of: "CFLAGS", in: code, .makefile) == .type)
        #expect(kind(of: "# tuned", in: code, .makefile) == .comment)
        #expect(kind(of: ".PHONY", in: code, .makefile) == .keyword)
        #expect(kind(of: "ifeq", in: code, .makefile) == .keyword)
        #expect(kind(of: "$(OS)", in: code, .makefile) == .type)
        #expect(kind(of: "endif", in: code, .makefile) == .keyword)
        #expect(kind(of: "build", in: code, .makefile) == .type)
        // Prerequisites and the 2 in -O2 stay plain.
        #expect(kind(of: "clean", in: code, .makefile) == nil)
        #expect(kind(of: "main.o", in: code, .makefile) == nil)
        #expect(!tokens(code, .makefile).contains { $0.kind == .number })
    }

    @Test func makeRecipeIsShellWithReferencesOnTop() {
        let code = "build:\n\t@echo \"building $(TARGET)\" && $(CC) -o $@ $^"
        let found = tokens(code, .makefile)
        #expect(found.contains { $0.text == "@" && $0.kind == .keyword })
        #expect(found.contains { $0.text == "echo" && $0.kind == .keyword })
        // The reference cuts the string around it.
        #expect(found.contains { $0.text == "\"building " && $0.kind == .string })
        #expect(found.contains { $0.text == "$(TARGET)" && $0.kind == .type })
        #expect(found.contains { $0.text == "\"" && $0.kind == .string })
        #expect(found.contains { $0.text == "$(CC)" && $0.kind == .type })
        #expect(found.contains { $0.text == "$@" && $0.kind == .keyword })
        #expect(found.contains { $0.text == "$^" && $0.kind == .keyword })
    }

    @Test func makeFunctionsMarkOnlyTheirHeadAndClose() {
        let code = "OBJS = $(patsubst %.c,%.o,$(SRCS))"
        let found = tokens(code, .makefile)
        #expect(found.contains { $0.text == "$(patsubst" && $0.kind == .keyword })
        #expect(found.contains { $0.text == "$(SRCS)" && $0.kind == .type })
        #expect(found.contains { $0.text == ")" && $0.kind == .keyword })
        #expect(!found.contains { $0.text.contains("%.c") })
    }

    @Test func makeTellsIndentedAssignmentsFromShellVariables() {
        let code = "ifeq ($(OS),Linux)\n\tLDFLAGS += -lrt\nendif\nrun:\n\tGOOS=linux go build"
        #expect(kind(of: "LDFLAGS", in: code, .makefile) == .type)
        // A one-command shell variable is not a Make assignment.
        #expect(kind(of: "GOOS", in: code, .makefile) == nil)
    }

    @Test func makeLeavesAnUnclosedApostropheAlone() {
        let code = "MESSAGE = don't panic"
        #expect(!tokens(code, .makefile).contains { $0.kind == .string })
    }

    @Test func makeSurvivesBrokenLines() {
        let lines = ["", "\t", "$", "$(", "$(shell echo \"$(X", "a: ;", "\t@", "x := $(a)$(b)",
                     "\techo \"$(A)\"$(B)'$(C)'", "#", "\\# not a comment", "::", "\t$$HOME"]
        for line in lines {
            var state = CodeHighlight.State.normal
            let found = CodeHighlight.tokens(in: line[...], language: .makefile, state: &state)
            #expect(zip(found, found.dropFirst()).allSatisfy {
                $0.range.upperBound <= $1.range.lowerBound
            })
        }
    }

    @Test func makefilesAreKnownByName() {
        #expect(CodeLanguage(path: "Makefile") == .makefile)
        #expect(CodeLanguage(path: "makefile") == .makefile)
        #expect(CodeLanguage(path: "GNUmakefile") == .makefile)
        #expect(CodeLanguage(path: "Makefile.in") == .makefile)
        #expect(CodeLanguage(path: "rules.mk") == .makefile)
        #expect(CodeLanguage(path: "main.swift") == .swift)
        #expect(CodeLanguage(path: "README") == nil)
        #expect(CodeLanguage(tag: "make") == .makefile)
    }

    @Test func pathsAreReadByTheirLastComponent() {
        #expect(CodeLanguage(path: "tools/build/Makefile") == .makefile)
        #expect(CodeLanguage(path: "Sources/App/main.swift") == .swift)
        // A directory named like a Makefile does not make its files Make.
        #expect(CodeLanguage(path: "makefile.d/notes") == nil)
    }

    @Test func aKnownExtensionOrProseBeatsTheMakefilePrefix() {
        #expect(CodeLanguage(path: "Makefile.py") == .python)
        #expect(CodeLanguage(path: "Makefile.md") == nil)
        #expect(CodeLanguage(path: "Makefile.TXT") == nil)
        #expect(CodeLanguage(path: "Makefile.local") == .makefile)
    }

    // MARK: - Language resolution

    @Test func unknownFenceTagsFallBackToCLike() {
        #expect(CodeLanguage(tag: "mystery") == .cLike)
        #expect(CodeLanguage(tag: "swift") == .swift)
        #expect(CodeLanguage(tag: nil) == nil)
        #expect(CodeLanguage(tag: "") == nil)
        let code = #"return "text" // done"#
        #expect(kind(of: "return", in: code, .cLike) == .keyword)
        #expect(kind(of: #""text""#, in: code, .cLike) == .string)
        #expect(kind(of: "// done", in: code, .cLike) == .comment)
    }

    @Test func unknownFileExtensionsStayPlain() {
        #expect(CodeLanguage(fileExtension: "txt") == nil)
        #expect(CodeLanguage(fileExtension: "md") == nil)
        #expect(CodeLanguage(fileExtension: "swift") == .swift)
        #expect(CodeLanguage(fileExtension: "kts") == .kotlin)
        #expect(CodeLanguage(fileExtension: "YML") == .yaml)
        #expect(CodeLanguage(fileExtension: "jsonnet") == .jsonnet)
        #expect(CodeLanguage(fileExtension: "libsonnet") == .jsonnet)
    }

    // MARK: - Rendering

    @Test func untaggedCodeStaysOneRun() {
        let highlighted = CodeHighlight.highlight("let x = 1", tag: nil)
        #expect(highlighted.runs.count == 1)
    }

    // Whatever the colouring does, it must never change the text itself.
    @Test func neverAltersTheText() {
        let samples: [(String, CodeLanguage)] = [
            ("let s = \"broken\nfunc x() { /* open", .swift),
            ("'''\nhalf a docstring", .python),
            ("<div class=\"open", .markup),
            ("select ' from -- \"", .sql),
            ("emoji 🎉 in \"a 🎉 string\" // and 🎉 comments", .swift)
        ]
        for (code, language) in samples {
            let highlighted = CodeHighlight.highlight(code, language: language)
            #expect(String(highlighted.characters) == code)
        }
    }

    @Test func hugeInputSkipsColouring() {
        let code = String(repeating: "let x = 1\n", count: 12_000)
        #expect(code.utf8.count > CodeHighlight.sizeLimit)
        #expect(CodeHighlight.highlight(code, language: .swift).runs.count == 1)
    }
}
