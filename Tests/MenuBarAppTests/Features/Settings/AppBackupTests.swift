import Foundation
import Testing
@testable import MenuBarApp

struct AppBackupTests {
    private let oldMac = ScratchDirectory(prefix: "backup-old-mac")
    private let newMac = ScratchDirectory(prefix: "backup-new-mac")
    private let oldDomain = "code-station-backup-old-\(UUID().uuidString)"
    private let newDomain = "code-station-backup-new-\(UUID().uuidString)"

    private func preferences(_ domain: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: domain))
    }

    private func writeIndex(_ index: ProjectPersistence.Index, to url: URL) throws {
        try PersistentFile.write(try PersistentFile.makeEncoder().encode(index), to: url)
    }

    private func readIndex(_ url: URL) throws -> ProjectPersistence.Index {
        try PersistentFile.makeDecoder().decode(ProjectPersistence.Index.self,
                                                from: Data(contentsOf: url))
    }

    private func export() throws -> AppBackup {
        let data = try AppBackup.make(configuration: Data("{}\n".utf8),
                                      support: oldMac.url,
                                      projectsURL: oldMac.path("projects.json"),
                                      defaults: try preferences(oldDomain),
                                      domain: oldDomain).encoded()
        let file = oldMac.path("backup.json")
        try data.write(to: file)
        return try AppBackup.read(file)
    }

    private func apply(_ backup: AppBackup) throws {
        try backup.apply(support: newMac.url, projectsURL: newMac.path("projects.json"),
                         defaults: try preferences(newDomain))
    }

    @Test func carriesChoicesAndFilesButNotWhatBelongsToThisMac() throws {
        let old = try preferences(oldDomain)
        defer {
            old.removePersistentDomain(forName: oldDomain)
            UserDefaults().removePersistentDomain(forName: newDomain)
        }
        old.set("dark", forKey: "appearance")
        old.set(UUID().uuidString, forKey: "selectedSessionID")
        old.set("/Users/old/site.json", forKey: "siteDefaultsPath")
        old.set("{0, 0, 10, 10}", forKey: "NSWindow Frame settings")
        try Data("shortcuts".utf8).write(to: oldMac.path("shortcuts.json"))
        try Data("requests".utf8).write(to: oldMac.path("dispatch.json"))
        try Data("bot".utf8).write(to: oldMac.path("agent-avatar-2.png"))
        try Data("transcript".utf8).write(to: oldMac.path("review-comments.json"))

        let project = Project(name: "api", path: "/Users/me/api")
        let task = Project(name: "Nightly", path: "/tmp/ad-hoc", kind: .adHoc)
        let workspace = ProjectWorkspace(name: "Both", projectIDs: [project.id, task.id],
                                         leadProjectID: project.id)
        try writeIndex(.init(projects: [project, task],
                             sessions: [ChatSession(projectID: project.id)],
                             workspaces: [workspace]),
                       to: oldMac.path("projects.json"))

        let backup = try export()
        #expect(backup.parts == AppBackup.Part.allCases)
        #expect(backup.files["review-comments.json"] == nil)

        let new = try preferences(newDomain)
        new.set("/Users/new/site.json", forKey: "siteDefaultsPath")
        try apply(backup)

        #expect(new.string(forKey: "appearance") == "dark")
        #expect(new.object(forKey: "selectedSessionID") == nil)
        #expect(new.object(forKey: "NSWindow Frame settings") == nil)
        #expect(new.object(forKey: "siteDefaultsPath") == nil)
        #expect(try Data(contentsOf: newMac.path("shortcuts.json")) == Data("shortcuts".utf8))
        #expect(try Data(contentsOf: newMac.path("dispatch.json")) == Data("requests".utf8))
        #expect(try Data(contentsOf: newMac.path("agent-avatar-2.png")) == Data("bot".utf8))
        #expect(FileManager.default.fileExists(atPath: newMac.path(SiteDefaults.fileName).path))

        let index = try readIndex(newMac.path("projects.json"))
        #expect(index.projects.map(\.id) == [project.id])
        #expect(index.sessions.isEmpty)
        #expect(index.workspaces?.first?.projectIDs == [project.id])
    }

    @Test func projectsJoinTheOnesAlreadyOnTheNewMac() throws {
        let existing = Project(name: "api", path: "/Users/me/api")
        let session = ChatSession(projectID: existing.id)
        try writeIndex(.init(projects: [existing], sessions: [session], workspaces: []),
                       to: newMac.path("projects.json"))

        let sameFolder = Project(name: "api", path: "/Users/me/api/")
        let other = Project(name: "web", path: "/Users/me/web")
        let workspace = ProjectWorkspace(name: "Stack", projectIDs: [sameFolder.id, other.id],
                                         leadProjectID: sameFolder.id)
        let incoming = try PersistentFile.makeEncoder().encode(
            ProjectPersistence.Index(projects: [sameFolder, other], sessions: [],
                                     workspaces: [workspace]))

        try AppBackup.mergeProjects(incoming, into: newMac.path("projects.json"))

        let index = try readIndex(newMac.path("projects.json"))
        #expect(index.projects.map(\.id) == [existing.id, other.id])
        #expect(index.sessions.map(\.id) == [session.id])
        let merged = try #require(index.workspaces?.first)
        #expect(merged.leadProjectID == existing.id)
        #expect(merged.projectIDs == [existing.id, other.id])
    }

    @Test func importingBotsReplacesTheOnesOnTheNewMac() throws {
        try Data("old".utf8).write(to: newMac.path("agent-avatar-5.png"))
        let backup = AppBackup(createdAt: .now, files: ["agent-avatar.png": Data("new".utf8)])

        try apply(backup)

        #expect(!FileManager.default.fileExists(atPath: newMac.path("agent-avatar-5.png").path))
        #expect(try Data(contentsOf: newMac.path("agent-avatar.png")) == Data("new".utf8))
    }

    @Test func onlyTheChosenPartsAreKept() {
        let backup = AppBackup(createdAt: .now,
                               preferences: Data(),
                               files: ["shortcuts.json": Data(), "dispatch.json": Data(),
                                       "dispatch-auth.json": Data()])

        let kept = backup.keeping([.requests])

        #expect(kept.parts == [.requests])
        #expect(Set(kept.files.keys) == ["dispatch.json", "dispatch-auth.json"])
    }

    @Test func aFileNameCannotReachOutsideTheDataFolder() throws {
        let backup = AppBackup(createdAt: .now, files: ["../escaped.json": Data("x".utf8)])

        try apply(backup)

        #expect(!FileManager.default.fileExists(
            atPath: newMac.url.deletingLastPathComponent().appendingPathComponent("escaped.json").path))
    }

    @Test func refusesFilesItCannotUnderstand() throws {
        let other = newMac.path("other.json")
        try Data(#"{"projects": []}"#.utf8).write(to: other)
        #expect(throws: ImportError.self) { try AppBackup.read(other) }

        var newer = AppBackup(createdAt: .now, files: [:])
        newer.version = AppBackup.currentVersion + 1
        let future = newMac.path("future.json")
        try newer.encoded().write(to: future)
        #expect(throws: ImportError.self) { try AppBackup.read(future) }
    }

    @Test func aStagedImportIsAppliedOnceAtLaunch() throws {
        defer { UserDefaults().removePersistentDomain(forName: newDomain) }
        let backup = AppBackup(createdAt: .now, files: ["shortcuts.json": Data("saved".utf8)])
        try AppBackup.stage(backup, support: newMac.url)
        #expect(AppBackup.pending(support: newMac.url)?.files == backup.files)

        AppBackup.applyPending(support: newMac.url, projectsURL: newMac.path("projects.json"),
                               defaults: try preferences(newDomain))

        #expect(try Data(contentsOf: newMac.path("shortcuts.json")) == Data("saved".utf8))
        #expect(AppBackup.pending(support: newMac.url) == nil)
    }
}
