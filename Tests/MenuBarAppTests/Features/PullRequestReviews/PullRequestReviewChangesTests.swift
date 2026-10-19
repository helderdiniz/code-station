import Foundation
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct PullRequestReviewChangesTests {
    @Test func discardPreservesEarlierEditsAndTheIndex() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "staged edit\n")
        try repo.git("add", "README.md")
        let earlier = "staged edit\nunstaged edit\n"
        try repo.write("README.md", earlier)
        try repo.write("notes.txt", "existing untracked file\n")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", earlier + "agent fix\n")
        try repo.write("notes.txt", "agent rewrote the notes\n")
        let proposal = try await PullRequestReviewChanges.finish(baseline)

        #expect(await proposal.discard() == nil)
        #expect(repo.read("README.md") == earlier)
        #expect(repo.read("notes.txt") == "existing untracked file\n")
        #expect(try repo.git("write-tree") == baseline.index)
        #expect(await proposal.discard() == nil)
    }

    @Test func discardRestoresTrackedDeletedAndNewFilesTogether() async throws {
        let repo = try GitRepo()
        try repo.write("deleted.txt", "keep me")
        try repo.commit("Add fixture")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "agent fix")
        try repo.write("new/fix.txt", "new file")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("deleted.txt"))
        let proposal = try await PullRequestReviewChanges.finish(baseline)

        #expect(await proposal.discard() == nil)
        #expect(repo.read("README.md") == "hello")
        #expect(repo.read("deleted.txt") == "keep me")
        #expect(repo.read("new/fix.txt") == nil)
        #expect(try repo.git("status", "--porcelain").isEmpty)
    }

    @Test func discardRestoresBinaryContentsAndFileModes() async throws {
        let repo = try GitRepo()
        let bytes = Data([0, 1, 2, 255])
        try repo.write("image.bin", bytes: bytes)
        try repo.write("script", "echo hi\n")
        try repo.commit("Add fixture")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("image.bin", bytes: Data([0, 4, 5, 6]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.url.appendingPathComponent("script").path)
        let proposal = try await PullRequestReviewChanges.finish(baseline)

        #expect(await proposal.discard() == nil)
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("image.bin")) == bytes)
        #expect(try repo.git("status", "--porcelain").isEmpty)
    }

    @Test func approvalDoesNotIncludeChangesThatPredateTheDraft() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "user edit\n")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "user edit\nagent fix\n")
        let proposal = try await PullRequestReviewChanges.finish(baseline)

        #expect(await proposal.commit(message: "Address review") != nil)
        #expect(repo.head == baseline.head)
        #expect(try repo.git("write-tree") == baseline.index)
        #expect(repo.read("README.md") == "user edit\nagent fix\n")
    }

    @Test func approvalRejectsPreexistingStagedWorkEvenWhenTheWorkingFileMatchesHead() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "staged user edit")
        try repo.git("add", "README.md")
        try repo.write("README.md", "hello")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "agent fix")
        let proposal = try await PullRequestReviewChanges.finish(baseline)

        #expect(await proposal.commit(message: "Address review") != nil)
        #expect(repo.head == baseline.head)
        #expect(try repo.git("write-tree") == baseline.index)
    }

    @Test func laterEditsBlockBothApprovalAndDiscardWithoutChangingAnyFiles() async throws {
        let repo = try GitRepo()
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "first proposal")
        try repo.write("new.txt", "new file")
        let first = try await PullRequestReviewChanges.finish(baseline)
        let nextBaseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "second proposal")
        let second = try await PullRequestReviewChanges.finish(nextBaseline)

        #expect(await first.discard() != nil)
        #expect(await first.commit(message: "Address review") != nil)
        #expect(repo.read("README.md") == "second proposal")
        #expect(repo.read("new.txt") == "new file")
        #expect(await second.commit(message: "Address review") != nil)
        #expect(await second.discard() == nil)
        #expect(repo.read("README.md") == "first proposal")
        #expect(await first.discard() == nil)
        #expect(repo.read("README.md") == "hello")
    }

    @Test func laterStagingBlocksDiscard() async throws {
        let repo = try GitRepo()
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "agent fix")
        let proposal = try await PullRequestReviewChanges.finish(baseline)
        try repo.git("add", "README.md")
        let index = try repo.git("write-tree")

        #expect(await proposal.discard() != nil)
        #expect(try repo.git("write-tree") == index)
        #expect(repo.read("README.md") == "agent fix")
    }

    @Test func approvalUsesLiteralPathsAndPreservesUnrelatedStagedWork() async throws {
        let repo = try GitRepo()
        try repo.write("route[ab].swift", "base")
        try repo.write("routea.swift", "base")
        try repo.commit("Add fixture")
        try repo.write("routea.swift", "user edit")
        try repo.git("add", "routea.swift")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("route[ab].swift", "agent fix")
        try repo.write("new file.txt", "agent file")
        let proposal = try await PullRequestReviewChanges.finish(baseline)

        #expect(await proposal.commit(message: "Address review") == nil)
        #expect(try repo.git("show", "HEAD:routea.swift") == "base")
        #expect(try repo.git("show", "HEAD:route[ab].swift") == "agent fix")
        #expect(try repo.git("show", "HEAD:new file.txt") == "agent file")
        #expect(try repo.git("diff", "--cached", "--name-only") == "routea.swift")
        let committed = repo.head
        #expect(await proposal.commit(message: "Retry after failed push") == nil)
        #expect(repo.head == committed)
        #expect(await proposal.discard() != nil)
    }

    @Test func discardTreatsGlobCharactersLiterally() async throws {
        let repo = try GitRepo()
        try repo.write("route[ab].swift", "base")
        try repo.write("routea.swift", "base")
        try repo.commit("Add fixture")
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("route[ab].swift", "agent fix")
        let proposal = try await PullRequestReviewChanges.finish(baseline)
        try repo.write("routea.swift", "later user edit")

        #expect(await proposal.discard() == nil)
        #expect(repo.read("route[ab].swift") == "base")
        #expect(repo.read("routea.swift") == "later user edit")
    }

    @Test func committingTheDraftElsewhereBlocksBothActions() async throws {
        let repo = try GitRepo()
        let baseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "agent fix")
        let proposal = try await PullRequestReviewChanges.finish(baseline)
        try repo.commit("Save draft outside the review")

        #expect(await proposal.commit(message: "Address review") != nil)
        #expect(await proposal.discard() != nil)
        #expect(repo.read("README.md") == "agent fix")
    }

    @Test func independentDraftsCanBeApprovedInSequence() async throws {
        let repo = try GitRepo()
        let firstBaseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("README.md", "first fix")
        let first = try await PullRequestReviewChanges.finish(firstBaseline)
        let secondBaseline = try await PullRequestReviewChanges.begin(at: repo.path)
        try repo.write("new.txt", "second fix")
        let second = try await PullRequestReviewChanges.finish(secondBaseline)

        #expect(await first.commit(message: "First review") == nil)
        #expect(await second.commit(message: "Second review") == nil)
        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(try repo.git("show", "HEAD:README.md") == "first fix")
        #expect(try repo.git("show", "HEAD:new.txt") == "second fix")
    }
}
