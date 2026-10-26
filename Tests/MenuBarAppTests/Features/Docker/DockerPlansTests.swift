import Testing
@testable import MenuBarApp

// The Docker sheet decides for itself what a deletion or a clean up will take, before
// docker is asked. Those guesses are what the user reads in the dialog, so they are
// covered here against small, made-up engines.
struct DockerReadingTests {
    @Test func readsAStoppedContainersExitCodeAndAge() throws {
        let container = try #require(DockerContainer(line:
            #"{"ID":"a","Names":"app","State":"exited","Status":"Exited (143) 2 days ago","Size":"18.6MB (virtual 300MB)"}"#))

        #expect(!container.isRunning)
        #expect(container.exitCode == 143)
        #expect(container.since == "2 days ago")
        #expect(container.bytes == 18_600_000)
    }

    @Test func readsARunningContainersHealth() throws {
        let container = try #require(DockerContainer(line:
            #"{"ID":"a","State":"running","Status":"Up 3 hours (healthy)","Ports":"0.0.0.0:8080->80/tcp, 0.0.0.0:8081->81/tcp"}"#))

        #expect(container.isRunning)
        #expect(container.since == "3 hours")
        #expect(container.health == "Healthy")
        #expect(container.exitCode == nil)
        #expect(container.hostPorts == ["8080", "8081"])
    }

    // An engine that leaves State out still says enough in its status line.
    @Test func fallsBackToTheStatusLineForState() {
        #expect(DockerContainer(line: #"{"ID":"a","Status":"Up 2 minutes"}"#)?.state == .running)
        #expect(DockerContainer(line: #"{"ID":"a","Status":"Restarting (1) 4 seconds ago"}"#)?.state == .restarting)
        #expect(DockerContainer(line: #"{"ID":"a","Status":"Exited (0) 1 hour ago"}"#)?.state == .exited)
    }

    @Test func readsDockersSizes() {
        #expect(DockerSize.bytes("0B") == 0)
        #expect(DockerSize.bytes("12kB (virtual 420MB)") == 12_000)
        #expect(DockerSize.bytes("1.2GB") == 1_200_000_000)
        #expect(DockerSize.bytes("3.5 MiB") == 3_670_016)
        #expect(DockerSize.bytes("N/A") == nil)
        #expect(DockerSize.bytes("") == nil)
        #expect(DockerSize.reclaimed(in: "Deleted Images:\nabc\n\nTotal reclaimed space: 2.3GB") == 2_300_000_000)
        #expect(DockerSize.reclaimed(in: "nothing here") == nil)
        #expect(DockerSize.text(26_679_000_000) == "26.7 GB")
        #expect(DockerSize.text(18_600_000) == "18.6 MB")
        #expect(DockerSize.text(41_000) == "41 kB")
        #expect(DockerSize.text(600_000_000) == "600 MB")
        #expect(DockerSize.text(2_000_000_000) == "2 GB")
    }

    @Test func readsDiskUsageByKind() {
        let usage = DockerDiskUsage(text: """
        {"Active":"9","Reclaimable":"5GB (33%)","Size":"15.1GB","TotalCount":"20","Type":"Images"}
        {"Active":"6","Reclaimable":"18MB (10%)","Size":"179MB","TotalCount":"10","Type":"Containers"}
        {"Active":"5","Reclaimable":"1GB","Size":"6.7GB","TotalCount":"11","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"4.5GB","Size":"4.7GB","TotalCount":"212","Type":"Build Cache"}
        """)

        #expect(usage.images == 15_100_000_000)
        #expect(usage.containers == 179_000_000)
        #expect(usage.volumes == 6_700_000_000)
        #expect(usage.buildCache == 4_700_000_000)
        #expect(usage.buildCacheReclaimable == 4_500_000_000)
        #expect(usage.buildCacheEntries == 212)
        #expect(usage.total == 26_679_000_000)
    }

    // `docker ps` names an image however the container was started with it.
    @Test func matchesAContainerToItsImage() throws {
        let tagged = try #require(DockerImage(line: #"{"ID":"sha256:aaaaaaaaaaaaaaaa","Repository":"postgres","Tag":"16"}"#))
        let latest = try #require(DockerImage(line: #"{"ID":"sha256:bbbbbbbbbbbbbbbb","Repository":"redis","Tag":"latest"}"#))
        let untagged = try #require(DockerImage(line: #"{"ID":"sha256:cccccccccccccccc","Repository":"<none>","Tag":"<none>"}"#))

        #expect(tagged.isUsed(by: try container(image: "postgres:16")))
        #expect(!tagged.isUsed(by: try container(image: "postgres:17")))
        #expect(latest.isUsed(by: try container(image: "redis")))
        #expect(untagged.isUsed(by: try container(image: "cccccccccccc")))
        #expect(!untagged.isUsed(by: try container(image: "postgres:16")))
    }
}

struct DockerDeletionTests {
    // A selection that includes an image still in use deletes the rest and names the one
    // that stays.
    @Test func keepsAnImageInUseAndNamesWhoUsesIt() throws {
        let used = try image("postgres", "16", id: "aaaaaaaaaaaaaaaa", size: "300MB")
        let free = try image("redis", "7", id: "bbbbbbbbbbbbbbbb", size: "40MB")
        let usage = DockerUsage(containers: [try container(name: "payments-gateway-api-1", image: "postgres:16")])

        let plan = DockerDeletion.images([used, free], usage: usage)

        #expect(plan.going.map(\.label) == ["redis:7"])
        #expect(plan.staying.map(\.label) == ["postgres:16"])
        #expect(plan.title == "Delete \"redis:7\"?")
        #expect(plan.action == "Delete 1 image")
        #expect(plan.bytes == 40_000_000)
        let kept = try #require(plan.rows.last)
        #expect(kept.kept)
        #expect(kept.title == "postgres:16 stays")
        #expect(kept.detail == "Used by payments-gateway-api-1. Delete that container first.")
    }

    @Test func refusesNothingButSaysWhenNothingCanGo() throws {
        let used = try image("postgres", "16", id: "aaaaaaaaaaaaaaaa", size: "300MB")
        let usage = DockerUsage(containers: [try container(name: "db", image: "postgres:16")])

        let plan = DockerDeletion.images([used], usage: usage)

        #expect(!plan.canDelete)
        #expect(plan.title == "Nothing here can be deleted")
    }

    @Test func namesTheRealCountOfSeveralImages() throws {
        let images = try (0..<6).map { try image("<none>", "<none>", id: "\($0)aaaaaaaaaaaaaaa", size: "100MB") }

        let plan = DockerDeletion.images(images, usage: DockerUsage(containers: []))

        #expect(plan.title == "Delete 6 images?")
        #expect(plan.action == "Delete 6 images")
        #expect(plan.rows.first?.title == "6 images, 600 MB")
    }

    @Test func leavesBuiltInNetworksAlone() throws {
        let bridge = try #require(DockerNetwork(line: #"{"ID":"n1","Name":"bridge"}"#))
        let mine = try #require(DockerNetwork(line: #"{"ID":"n2","Name":"app_default"}"#))

        let plan = DockerDeletion.networks([bridge, mine], usage: DockerUsage(containers: []))

        #expect(plan.going.map(\.label) == ["app_default"])
        #expect(plan.rows.last?.detail == "Built in to Docker, so it cannot be deleted.")
    }

    @Test func warnsThatVolumeDataIsGoneForGood() throws {
        let volume = try #require(DockerVolume(line: #"{"Name":"pg_data"}"#))

        let plan = DockerDeletion.volumes([volume], sizes: ["pg_data": 2_000_000_000],
                                          usage: DockerUsage(containers: []))

        #expect(plan.warning == "Volume data cannot be restored.")
        #expect(plan.bytes == 2_000_000_000)
    }

    // A running container is stopped on the way out rather than kept.
    @Test func deletesRunningContainersAfterStoppingThem() throws {
        let running = try #require(DockerContainer(line: #"{"ID":"a","Names":"api","State":"running"}"#))
        let stopped = try #require(DockerContainer(line: #"{"ID":"b","Names":"db","State":"exited"}"#))

        let plan = DockerDeletion.containers([running, stopped])

        #expect(plan.going.count == 2)
        #expect(plan.rows.first?.detail.contains("1 running container is stopped first.") == true)
        #expect(plan.rows.last?.title == "Images and volumes stay")
    }
}

struct DockerCleanUpTests {
    private func engine() throws -> (containers: [DockerContainer], images: [DockerImage],
                                     volumes: [DockerVolume], networks: [DockerNetwork]) {
        let running = try #require(DockerContainer(line:
            #"{"ID":"r","Names":"api","State":"running","Image":"api:1","Mounts":"api_data","Networks":"app_default","Size":"1MB"}"#))
        let stopped = try #require(DockerContainer(line:
            #"{"ID":"s","Names":"old","State":"exited","Image":"old:1","Mounts":"old_data","Networks":"old_default","Size":"20MB"}"#))
        let images = [try image("api", "1", id: "aaaaaaaaaaaaaaaa", size: "100MB"),
                      try image("old", "1", id: "bbbbbbbbbbbbbbbb", size: "200MB"),
                      try image("<none>", "<none>", id: "cccccccccccccccc", size: "50MB")]
        let volumes = [try #require(DockerVolume(line: #"{"Name":"api_data","Size":"1GB"}"#)),
                       try #require(DockerVolume(line: #"{"Name":"old_data","Size":"2GB"}"#))]
        let networks = [try #require(DockerNetwork(line: #"{"ID":"1","Name":"bridge"}"#)),
                        try #require(DockerNetwork(line: #"{"ID":"2","Name":"app_default"}"#)),
                        try #require(DockerNetwork(line: #"{"ID":"3","Name":"old_default"}"#))]
        return ([running, stopped], images, volumes, networks)
    }

    private func plan(removingStopped: Bool) throws -> DockerCleanUp {
        let engine = try engine()
        var disk = DockerDiskUsage()
        disk.buildCacheReclaimable = 4_000_000_000
        disk.buildCacheEntries = 212
        return DockerCleanUp(containers: engine.containers, images: engine.images, volumes: engine.volumes,
                             networks: engine.networks, volumeSizes: [:], disk: disk,
                             removingStopped: removingStopped)
    }

    // Removing the stopped container frees the image, volume and network only it used.
    @Test func countsWhatStoppedContainersFree() throws {
        let keeping = try plan(removingStopped: false)
        let removing = try plan(removingStopped: true)

        #expect(keeping.line(.unusedImages).count == 0)
        #expect(removing.line(.unusedImages).count == 1)
        #expect(removing.line(.unusedImages).freedByStopped == 1)
        #expect(removing.line(.unusedVolumes).bytes == 2_000_000_000)
        #expect(removing.line(.unusedVolumes).largest == "old_data")
        #expect(removing.line(.unusedNetworks).count == 1)
        #expect(keeping.line(.unusedNetworks).count == 0)
    }

    // The total changes as choices are ticked, and it includes what the stopped
    // containers free.
    @Test func totalFollowsTheChoices() throws {
        let removing = try plan(removingStopped: true)

        #expect(removing.total(DockerCleanUp.Choice.safe) == 20_000_000 + 50_000_000 + 4_000_000_000)
        // Pruning every unused image takes the untagged ones along.
        #expect(removing.total([.unusedImages]) == 200_000_000 + 50_000_000)
        #expect(removing.total(DockerCleanUp.Choice.safe.union([.unusedImages]))
                == 20_000_000 + 50_000_000 + 200_000_000 + 4_000_000_000)
        #expect(removing.total([.unusedVolumes]) == 2_000_000_000)
        #expect(removing.total([]) == 0)
    }

    @Test func neverPicksVolumesOrTaggedImagesByDefault() {
        #expect(!DockerCleanUp.Choice.safe.contains(.unusedVolumes))
        #expect(!DockerCleanUp.Choice.safe.contains(.unusedImages))
        #expect(DockerCleanUp.Choice.unusedVolumes.losesData)
    }

    // Pruning every unused image already removes the untagged ones, and a line with
    // nothing on it is not run at all.
    @Test func runsEachNeededPruneOnceInOrder() throws {
        let removing = try plan(removingStopped: true)

        let steps = removing.steps(Set(DockerCleanUp.Choice.allCases))

        #expect(steps == [.stoppedContainers, .unusedNetworks, .unusedImages, .buildCache, .unusedVolumes])
        #expect(steps.map(\.command).contains(["image", "prune", "--all", "--force"]))
        #expect(steps.map(\.command).last == ["volume", "prune", "--all", "--force"])
    }
}

@MainActor
struct DockerServiceBulkTests {
    // A refused item does not stop the rest, and its own complaint comes back by its ID.
    @Test func reportsEachFailureAndCarriesOn() async throws {
        let recorder = DockerScriptedRunner(failing: ["image", "rm", "postgres:16"],
                                            with: "conflict: image is being used by running container")
        let service = DockerService(runner: { await recorder.run($0) }, availability: { true })
        let used = try image("postgres", "16", id: "aaaaaaaaaaaaaaaa", size: "300MB")
        let free = try image("redis", "7", id: "bbbbbbbbbbbbbbbb", size: "40MB")

        let failures = await service.delete([used, free])

        #expect(failures == [used.id: "conflict: image is being used by running container"])
        let commands = await recorder.commands
        #expect(commands.prefix(2) == [["image", "rm", "postgres:16"], ["image", "rm", "redis:7"]])
        #expect(service.images.busy.isEmpty)
    }

    @Test func startsStopsAndRestartsAListOfContainers() async throws {
        let recorder = DockerScriptedRunner()
        let service = DockerService(runner: { await recorder.run($0) }, availability: { true })
        let first = try #require(DockerContainer(line: #"{"ID":"c1","State":"exited"}"#))
        let second = try #require(DockerContainer(line: #"{"ID":"c2","State":"exited"}"#))

        #expect(await service.perform(.start, on: [first, second]) == nil)
        #expect(await service.perform(.restart, on: [first]) == nil)
        #expect(await service.perform(.remove, on: [second]) == nil)

        let commands = await recorder.commands.filter { $0.first != "ps" && $0.first != "system" }
        #expect(commands == [["start", "c1", "c2"], ["restart", "c1"], ["rm", "--force", "c2"]])
        #expect(service.working.isEmpty)
    }

    @Test func startsAndStopsAComposeProjectThroughCompose() async throws {
        let recorder = DockerScriptedRunner()
        let service = DockerService(runner: { await recorder.run($0) }, availability: { true })
        let container = try #require(DockerContainer(line:
            #"{"ID":"c1","State":"running","Labels":"com.docker.compose.project=payments"}"#))

        #expect(await service.compose(.stop, project: "payments", containers: [container]) == nil)

        #expect(await recorder.commands.first == ["compose", "--project-name", "payments", "stop"])
    }

    @Test func usesTheComposePluginWhenDockerHasIt() async {
        let calls = ToolCalls()
        let result = await DockerService.runCompose(["--project-name", "payments", "stop"]) { tool, arguments in
            await calls.record(tool, arguments)
            return DockerService.Output(status: 0)
        }

        #expect(result.ok)
        #expect(await calls.all == [["docker", "compose", "--project-name", "payments", "stop"]])
    }

    @Test func fallsBackToStandaloneComposeWhenThePluginIsMissing() async {
        let calls = ToolCalls()
        let result = await DockerService.runCompose(["--project-name", "payments", "stop"]) { tool, arguments in
            await calls.record(tool, arguments)
            if tool == "docker" { return DockerService.Output(errorText: "unknown flag: --project-name", status: 125) }
            return DockerService.Output(status: 0)
        }

        #expect(result.ok)
        #expect(await calls.all.last == ["docker-compose", "--project-name", "payments", "stop"])
    }

    @Test func fallsBackToPodmanComposeWhenNoDockerComposeIsInstalled() async {
        let calls = ToolCalls()
        let result = await DockerService.runCompose(["--project-name", "payments", "stop"]) { tool, arguments in
            await calls.record(tool, arguments)
            return tool == "podman" ? DockerService.Output(status: 0) : nil
        }

        #expect(result.ok)
        #expect(await calls.all.last == ["podman", "compose", "--project-name", "payments", "stop"])
    }

    @Test func reportsAComposeFailureWhenThePluginWorks() async {
        let calls = ToolCalls()
        let result = await DockerService.runCompose(["--project-name", "payments", "stop"]) { tool, arguments in
            await calls.record(tool, arguments)
            if arguments == ["compose", "version"] { return DockerService.Output(status: 0) }
            return DockerService.Output(errorText: "no such project: payments", status: 1)
        }

        #expect(result.failureMessage == "no such project: payments")
        #expect(await calls.all.allSatisfy { $0.first == "docker" })
    }

    @Test func readsWhatAPruneFreed() async {
        let recorder = DockerScriptedRunner(output: "Deleted build cache objects:\nx\n\nTotal reclaimed space: 4.7GB")
        let service = DockerService(runner: { await recorder.run($0) }, availability: { true })

        let result = await service.prune(["builder", "prune", "--force"])

        #expect(result.freed == 4_700_000_000)
        #expect(result.failure == nil)
    }
}

private func container(name: String = "c", image: String) throws -> DockerContainer {
    try #require(DockerContainer(line: #"{"ID":"\#(name)-id","Names":"\#(name)","Image":"\#(image)","State":"running"}"#))
}

private func image(_ repository: String, _ tag: String, id: String, size: String) throws -> DockerImage {
    try #require(DockerImage(line:
        #"{"ID":"sha256:\#(id)","Repository":"\#(repository)","Tag":"\#(tag)","Size":"\#(size)"}"#))
}

private actor ToolCalls {
    private(set) var all: [[String]] = []

    func record(_ tool: String, _ arguments: [String]) {
        all.append([tool] + arguments)
    }
}

private actor DockerScriptedRunner {
    private(set) var commands: [[String]] = []
    private let failing: [String]?
    private let message: String
    private let output: String

    init(failing: [String]? = nil, with message: String = "", output: String = "") {
        self.failing = failing
        self.message = message
        self.output = output
    }

    func run(_ arguments: [String]) -> DockerService.Output {
        commands.append(arguments)
        if arguments == failing { return DockerService.Output(errorText: message, status: 1) }
        return DockerService.Output(text: output, status: 0)
    }
}
