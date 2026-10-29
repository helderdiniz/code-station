import Foundation
import Testing
@testable import MenuBarApp

// Copying a project folder's uncommitted work into a new worktree. A wrong answer either
// loses work the user expected to find in the session, promises a clean copy that
// arrives with conflicts, or changes the folder the work was copied from.
struct GitCarryOverTests {

    @Test func previewSeesNoClashWhenTheBaseLeftTheFilesAlone() async throws {
        let repo = try Fixture()
        try repo.folder.write("README.md", "edited")
        try repo.folder.write("notes.txt", "new")

        #expect(await GitCarryOver.preview(at: repo.folder.path, onto: "main") == .clean)
    }

    @Test func previewNamesTrackedAndUntrackedClashes() async throws {
        let repo = try Fixture()
        try repo.folder.write("shared.txt", "a\nFEATURE\nc\n")
        try repo.folder.write("added.txt", "mine")
        try repo.folder.write("only-mine.txt", "mine")

        let preview = await GitCarryOver.preview(at: repo.folder.path, onto: "main")
        #expect(preview == .clashes(["shared.txt", "added.txt"]))
        // The check leaves no trace in the shared stash list.
        #expect(try repo.folder.git("stash", "list").isEmpty)
    }

    @Test func copiesTrackedAndUntrackedWorkAndLeavesTheFolderAlone() async throws {
        let repo = try Fixture()
        try repo.folder.write("README.md", "edited")
        try repo.folder.git("add", "README.md")
        try repo.folder.write("nested/notes.txt", "new")
        let statusBefore = try repo.folder.git("status", "--porcelain")
        let worktree = try repo.worktree(from: "feature")

        let outcome = await GitCarryOver.apply(from: repo.folder.path, to: worktree.path)

        #expect(outcome == GitCarryOver.Outcome())
        #expect(worktree.read("README.md") == "edited")
        #expect(worktree.read("nested/notes.txt") == "new")
        #expect(try repo.folder.git("status", "--porcelain") == statusBefore)
        #expect(try repo.folder.git("stash", "list").isEmpty)
    }

    @Test func leavesConflictMarkersAndNamesTheFiles() async throws {
        let repo = try Fixture()
        try repo.folder.write("shared.txt", "a\nFEATURE\nc\n")
        try repo.folder.write("added.txt", "mine")
        let worktree = try repo.worktree(from: "main")

        let outcome = await GitCarryOver.apply(from: repo.folder.path, to: worktree.path)

        #expect(outcome.conflicts == ["shared.txt", "added.txt"])
        #expect(outcome.failure == nil)
        #expect(worktree.read("shared.txt")?.contains("<<<<<<<") == true)
        // The base's copy is still in git, so the folder's copy can take its place.
        #expect(worktree.read("added.txt") == "mine")
        #expect(repo.folder.read("shared.txt") == "a\nFEATURE\nc\n")
    }

    @Test func noteAsksTheAgentToResolveOnlyWhenSomethingIsLeft() {
        #expect(GitCarryOver.Outcome().agentNote(projectPath: "/work/app", base: "origin/main") == nil)

        let note = GitCarryOver.Outcome(conflicts: ["a.txt", "b.txt"])
            .agentNote(projectPath: "/work/app", base: "origin/main")
        #expect(note?.contains("starts from origin/main") == true)
        #expect(note?.contains("- a.txt\n- b.txt") == true)
        #expect(note?.contains("still in /work/app") == true)

        let failed = GitCarryOver.Outcome(failure: "Disk full.")
            .agentNote(projectPath: "/work/app", base: nil)
        #expect(failed?.contains("did not finish: Disk full.") == true)
    }

    // A folder on a feature branch, written before main gained a change to one shared
    // file and a new file of its own.
    private struct Fixture {
        let folder: GitRepo
        private let scratch = ScratchDirectory(prefix: "carry-worktrees")

        init() throws {
            folder = try GitRepo()
            try folder.write("shared.txt", "a\nb\nc\n")
            try folder.commit("shared")
            try folder.git("checkout", "-q", "-b", "feature")
            try folder.git("checkout", "-q", "main")
            try folder.write("shared.txt", "a\nMAIN\nc\n")
            try folder.write("added.txt", "theirs")
            try folder.commit("main moves on")
            try folder.git("checkout", "-q", "feature")
        }

        func worktree(from base: String) throws -> GitRepo.Checkout {
            let path = scratch.path("tree-\(UUID().uuidString.prefix(6))").path
            try folder.git("worktree", "add", "-q", path, "-b", "carry-\(UUID().uuidString.prefix(6))", base)
            return GitRepo.Checkout(path: path)
        }
    }
}

private extension GitRepo {
    struct Checkout {
        let path: String

        func read(_ name: String) -> String? {
            try? String(contentsOfFile: path + "/" + name, encoding: .utf8)
        }
    }
}
