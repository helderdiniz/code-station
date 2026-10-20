import Foundation

// A proposal owns the difference between two trees, not every edit in the files it names.
// These trees use a spare index so recording a draft never changes staged work.
@MainActor
final class PullRequestReviewChanges: Equatable {
    struct Baseline: Sendable {
        let root: String
        let head: String
        let index: String
        let tree: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let baseline: Baseline
    let tree: String
    let files: [String]
    private var committedHead: String?
    private var discarded = false
    private var applying = false

    nonisolated static func == (lhs: PullRequestReviewChanges, rhs: PullRequestReviewChanges) -> Bool { lhs === rhs }

    private init(baseline: Baseline, tree: String, files: [String]) {
        self.baseline = baseline
        self.tree = tree
        self.files = files
    }

    static func begin(at root: String) async throws -> Baseline {
        guard let git = GitInspector.tool() else { throw Failure(message: "Could not find git on PATH.") }
        return try await GitInspector.offMain { Result { try Self.snapshot(at: root, using: git) } }.get()
    }

    static func finish(_ baseline: Baseline) async throws -> PullRequestReviewChanges {
        guard let git = GitInspector.tool() else { throw Failure(message: "Could not find git on PATH.") }
        let (tree, files) = try await GitInspector.offMain {
            Result {
                let current = try Self.snapshot(at: baseline.root, using: git)
                let paths = try Self.checked(git, ["diff-tree", "-r", "--no-renames", "--name-only", "-z",
                                              baseline.tree, current.tree], at: baseline.root)
                return (current.tree, paths.split(separator: "\0").map(String.init))
            }
        }.get()
        return PullRequestReviewChanges(baseline: baseline, tree: tree, files: files)
    }

    func commit(message: String) async -> String? {
        guard !applying else { return "This proposal is already being applied." }
        guard !discarded else { return "This proposal has already been discarded." }
        guard !files.isEmpty else { return nil }
        guard let git = GitInspector.tool() else { return "Could not find git on PATH." }
        applying = true
        defer { applying = false }
        let baseline = baseline, tree = tree, committedHead = committedHead
        let paths = files.map { ":(literal)" + $0 }
        let result = await GitInspector.offMain {
            Result {
                let current = try Self.snapshot(at: baseline.root, using: git)
                try Self.requireEqual(git, current.tree, tree, paths: paths, at: baseline.root)
                if let committedHead {
                    guard current.head == committedHead else {
                        throw Failure(message: "The branch moved after this proposal was committed. Review it in Changes before pushing.")
                    }
                    try Self.requireEqual(git, current.index, current.head, paths: paths, at: baseline.root)
                    return committedHead
                }
                try Self.requireEqual(git, current.head, baseline.head, paths: paths, at: baseline.root)
                try Self.requireEqual(git, current.index, baseline.index, paths: paths, at: baseline.root)
                do {
                    try Self.requireEqual(git, baseline.tree, baseline.head, paths: paths, at: baseline.root)
                    try Self.requireEqual(git, baseline.index, baseline.head, paths: paths, at: baseline.root)
                } catch {
                    throw Failure(message: "These files already had changes before the draft. Commit the intended changes in the Changes tab, then reply here.")
                }
                _ = try Self.checked(git, ["add", "-A", "--"] + paths, at: baseline.root)
                _ = try Self.checked(git, ["commit", "-m", message, "--"] + paths, at: baseline.root)
                return try Self.checked(git, ["rev-parse", "HEAD"], at: baseline.root).trimmed
            }
        }
        do {
            self.committedHead = try result.get()
            return nil
        } catch { return error.localizedDescription }
    }

    func discard() async -> String? {
        guard !applying else { return "This proposal is already being applied." }
        guard committedHead == nil else { return "This proposal has already been committed. Review it in Changes first." }
        guard !discarded, !files.isEmpty else { return nil }
        guard let git = GitInspector.tool() else { return "Could not find git on PATH." }
        applying = true
        defer { applying = false }
        let baseline = baseline, tree = tree
        let paths = files.map { ":(literal)" + $0 }
        let result = await GitInspector.offMain {
            Result {
                let current = try Self.snapshot(at: baseline.root, using: git)
                try Self.requireEqual(git, current.head, baseline.head, paths: paths, at: baseline.root)
                try Self.requireEqual(git, current.tree, tree, paths: paths, at: baseline.root)
                try Self.requireEqual(git, current.index, baseline.index, paths: paths, at: baseline.root)
                let patch = try Self.checked(git, ["diff-tree", "-r", "-p", "--binary", "--no-ext-diff", "--no-textconv",
                                               "--no-renames", "--no-color", tree, baseline.tree, "--"] + paths,
                                        at: baseline.root)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("review-discard-\(UUID()).patch")
                defer { try? FileManager.default.removeItem(at: file) }
                try patch.write(to: file, atomically: true, encoding: .utf8)
                _ = try Self.checked(git, ["apply", "--check", file.path], at: baseline.root)
                _ = try Self.checked(git, ["apply", file.path], at: baseline.root)
            }
        }
        do {
            try result.get()
            discarded = true
            return nil
        } catch { return error.localizedDescription }
    }

    nonisolated private static func snapshot(at root: String, using git: GitInspector.GitTool) throws -> Baseline {
        guard !GitBranches.blocksOtherActions(git, URL(fileURLWithPath: root)) else {
            throw Failure(message: "Finish or abort the current operation in Branches first.")
        }
        let head = try Self.checked(git, ["rev-parse", "HEAD"], at: root).trimmed
        let index = try Self.checked(git, ["write-tree"], at: root).trimmed
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("review-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let environment = ["GIT_INDEX_FILE": file.path]
        _ = try Self.checked(git, ["read-tree", "HEAD"], at: root, environment: environment)
        _ = try Self.checked(git, ["add", "-A"], at: root, environment: environment)
        let tree = try Self.checked(git, ["write-tree"], at: root, environment: environment).trimmed
        return Baseline(root: root, head: head, index: index, tree: tree)
    }

    nonisolated private static func requireEqual(_ git: GitInspector.GitTool, _ first: String, _ second: String,
                                                 paths: [String], at root: String) throws {
        let diff = GitInspector.run(git, ["diff-tree", "-r", "--quiet", first, second, "--"] + paths,
                                    in: URL(fileURLWithPath: root))
        guard diff.ok else {
            throw Failure(message: "The proposal's files changed since drafting. Review them in Changes before committing or discarding.")
        }
    }

    nonisolated private static func checked(_ git: GitInspector.GitTool, _ arguments: [String], at root: String,
                                            environment: [String: String] = [:]) throws -> String {
        let result = GitInspector.run(git, arguments, in: URL(fileURLWithPath: root), environment: environment)
        guard result.ok else { throw Failure(message: result.failureMessage) }
        guard !result.truncated else { throw Failure(message: "The draft changes were too large to read.") }
        return result.text
    }
}
