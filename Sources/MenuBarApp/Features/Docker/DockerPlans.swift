import Foundation

// The four kinds of thing the Docker sheet lists, in the order of its rail.
enum DockerKind: Int, CaseIterable, Identifiable, Sendable {
    case containers, images, volumes, networks

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        }
    }

    var icon: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "point.3.connected.trianglepath.dotted"
        }
    }

    var noun: String {
        switch self {
        case .containers: "container"
        case .images: "image"
        case .volumes: "volume"
        case .networks: "network"
        }
    }

    func amount(_ count: Int) -> String { counted(count, noun) }
}

// What uses what. Docker counts a stopped container as a user too, which is why a stopped
// container keeps its image and volumes out of every prune until it is removed itself.
struct DockerUsage {
    let containers: [DockerContainer]

    func users(of image: DockerImage) -> [DockerContainer] {
        containers.filter { image.isUsed(by: $0) }
    }

    func users(of volume: DockerVolume) -> [DockerContainer] {
        containers.filter { volume.isUsed(by: $0) }
    }

    func users(of network: DockerNetwork) -> [DockerContainer] {
        containers.filter { $0.networkNames.contains(network.name) }
    }
}

// The impact of deleting a selection. Anything still in use stays and says why, so a
// mixed selection is never refused outright.
struct DockerDeletion {
    struct Item {
        let id: String
        let label: String
        let bytes: Int64
        var users: [String] = []
        var builtIn = false
        var running = false

        var stays: Bool { builtIn || !users.isEmpty }
    }

    let kind: DockerKind
    let going: [Item]
    let staying: [Item]

    init(kind: DockerKind, items: [Item]) {
        self.kind = kind
        // A container is never in the way of its own removal: a running one is stopped
        // first.
        going = kind == .containers ? items : items.filter { !$0.stays }
        staying = kind == .containers ? [] : items.filter(\.stays)
    }

    static func containers(_ containers: [DockerContainer]) -> DockerDeletion {
        DockerDeletion(kind: .containers, items: containers.map {
            Item(id: $0.id, label: $0.name, bytes: $0.bytes ?? 0, running: $0.isRunning)
        })
    }

    static func images(_ images: [DockerImage], usage: DockerUsage) -> DockerDeletion {
        DockerDeletion(kind: .images, items: images.map {
            Item(id: $0.id, label: $0.isUntagged ? "Untagged \($0.shortID)" : $0.reference,
                 bytes: $0.bytes ?? 0, users: usage.users(of: $0).map(\.name))
        })
    }

    static func volumes(_ volumes: [DockerVolume], sizes: [String: Int64],
                        usage: DockerUsage) -> DockerDeletion {
        DockerDeletion(kind: .volumes, items: volumes.map {
            Item(id: $0.id, label: $0.id, bytes: sizes[$0.id] ?? $0.bytes ?? 0,
                 users: usage.users(of: $0).map(\.name))
        })
    }

    static func networks(_ networks: [DockerNetwork], usage: DockerUsage) -> DockerDeletion {
        DockerDeletion(kind: .networks, items: networks.map {
            Item(id: $0.id, label: $0.name, bytes: 0, users: usage.users(of: $0).map(\.name),
                 builtIn: $0.isBuiltIn)
        })
    }

    var bytes: Int64 { going.reduce(0) { $0 + $1.bytes } }
    var canDelete: Bool { !going.isEmpty }

    var title: String {
        guard let first = going.first else { return "Nothing here can be deleted" }
        return going.count == 1 ? "Delete \"\(first.label)\"?" : "Delete \(kind.amount(going.count))?"
    }

    var action: String {
        going.isEmpty ? "Delete \(kind.noun)s" : "Delete \(kind.amount(going.count))"
    }

    var warning: String? {
        kind == .volumes && !going.isEmpty ? "Volume data cannot be restored." : nil
    }

    var rows: [DialogRow] {
        var rows: [DialogRow] = []
        let names = Self.names(going.map(\.label))
        if kind == .containers {
            let running = going.count(where: \.running)
            let note = running == 0 ? "Logs and files written inside them go too."
                : "\(counted(running, "running container is", plural: "running containers are")) stopped first. Logs and files written inside them go too."
            rows.append(DialogRow(title: heading, detail: "\(names). \(note)"))
            rows.append(DialogRow(title: "Images and volumes stay",
                                  detail: "They can be cleaned up on their own once nothing uses them.",
                                  kept: true))
            return rows
        }
        if !going.isEmpty {
            let detail = switch kind {
            case .images: "Removed from this Mac. They can be pulled or built again."
            case .volumes: "Removed with all the data inside them."
            default: "Removed by Docker."
            }
            rows.append(DialogRow(title: heading, detail: "\(names). \(detail)"))
        }
        for item in staying.prefix(3) {
            let detail: String
            if item.builtIn {
                detail = "Built in to Docker, so it cannot be deleted."
            } else {
                let shown = item.users.prefix(2).joined(separator: " and ")
                let more = item.users.count > 2 ? " and \(item.users.count - 2) more" : ""
                let those = item.users.count == 1 ? "that container" : "those containers"
                detail = "Used by \(shown)\(more). Delete \(those) first."
            }
            rows.append(DialogRow(title: "\(item.label) stays", detail: detail, kept: true))
        }
        if staying.count > 3 {
            rows.append(DialogRow(title: "\(staying.count - 3) more stay",
                                  detail: "Each is still used by a container.", kept: true))
        }
        return rows
    }

    private var heading: String {
        bytes > 0 ? "\(kind.amount(going.count)), \(DockerSize.text(bytes))" : kind.amount(going.count)
    }

    private static func names(_ labels: [String]) -> String {
        let shown = labels.prefix(6).joined(separator: ", ")
        return labels.count > 6 ? "\(shown) and \(labels.count - 6) more" : shown
    }

    // Kept apart from the dialog's own type so the plan can be read without the UI.
    struct DialogRow: Equatable {
        let title: String
        let detail: String
        var kept = false
    }
}

// `docker system prune`, taken apart so each part shows what it would free before it runs.
struct DockerCleanUp {
    enum Choice: CaseIterable, Hashable, Sendable {
        case stoppedContainers, unusedNetworks, untaggedImages, unusedImages, buildCache, unusedVolumes

        var title: String {
            switch self {
            case .stoppedContainers: "Stopped containers"
            case .unusedNetworks: "Unused networks"
            case .untaggedImages: "Untagged images"
            case .unusedImages: "Unused tagged images"
            case .buildCache: "Build cache"
            case .unusedVolumes: "Unused volumes"
            }
        }

        var detail: String {
            switch self {
            case .stoppedContainers: "Containers that have exited. Their logs and any files written inside them go too."
            case .unusedNetworks: "Networks no container is connected to. Built-in networks are never removed."
            case .untaggedImages: "Layers left behind when an image is rebuilt under the same tag."
            case .unusedImages: "Images no container uses. Docker pulls or builds them again the next time they are needed."
            case .buildCache: "Saved build steps. The next build of each image starts from scratch."
            case .unusedVolumes: "Volumes no container uses, named and anonymous."
            }
        }

        var command: [String] {
            switch self {
            case .stoppedContainers: ["container", "prune", "--force"]
            case .unusedNetworks: ["network", "prune", "--force"]
            case .untaggedImages: ["image", "prune", "--force"]
            case .unusedImages: ["image", "prune", "--all", "--force"]
            case .buildCache: ["builder", "prune", "--force"]
            case .unusedVolumes: ["volume", "prune", "--all", "--force"]
            }
        }

        var losesData: Bool { self == .unusedVolumes }

        // Volumes hold data nobody can get back, and tagged images take a while to pull
        // again, so neither is picked until the user picks it.
        static let safe: Set<Choice> = [.stoppedContainers, .unusedNetworks, .untaggedImages, .buildCache]
    }

    struct Line {
        let choice: Choice
        let count: Int
        let bytes: Int64
        // How many of these only become unused once the stopped containers are gone.
        var freedByStopped = 0
        // The largest thing on the line, for a warning that names what is at stake.
        var largest: String?

        var isEmpty: Bool { choice == .buildCache ? bytes == 0 && count == 0 : count == 0 }

        var countText: String {
            switch choice {
            case .stoppedContainers: counted(count, "container")
            case .unusedNetworks: counted(count, "network")
            case .untaggedImages, .unusedImages: counted(count, "image")
            case .buildCache: counted(count, "entry", plural: "entries")
            case .unusedVolumes: counted(count, "volume")
            }
        }
    }

    let lines: [Choice: Line]

    init(containers: [DockerContainer], images: [DockerImage], volumes: [DockerVolume],
         networks: [DockerNetwork], volumeSizes: [String: Int64], disk: DockerDiskUsage,
         removingStopped: Bool) {
        let stopped = containers.filter { !$0.isRunning }
        let before = DockerUsage(containers: containers)
        let after = DockerUsage(containers: removingStopped ? containers.filter(\.isRunning) : containers)

        let untagged = images.filter(\.isUntagged)
        let unusedImages = images.filter { !$0.isUntagged && after.users(of: $0).isEmpty }
        let unusedVolumes = volumes.filter { after.users(of: $0).isEmpty }
        let unusedNetworks = networks.filter { !$0.isBuiltIn && after.users(of: $0).isEmpty }
        let volumeBytes = { (volume: DockerVolume) in volumeSizes[volume.id] ?? volume.bytes ?? 0 }

        lines = [
            .stoppedContainers: Line(choice: .stoppedContainers, count: stopped.count,
                                     bytes: stopped.reduce(0) { $0 + ($1.bytes ?? 0) }),
            .unusedNetworks: Line(choice: .unusedNetworks, count: unusedNetworks.count, bytes: 0,
                                  freedByStopped: unusedNetworks.count { !before.users(of: $0).isEmpty }),
            .untaggedImages: Line(choice: .untaggedImages, count: untagged.count,
                                  bytes: untagged.reduce(0) { $0 + ($1.bytes ?? 0) }),
            .unusedImages: Line(choice: .unusedImages, count: unusedImages.count,
                                bytes: unusedImages.reduce(0) { $0 + ($1.bytes ?? 0) },
                                freedByStopped: unusedImages.count { !before.users(of: $0).isEmpty }),
            .buildCache: Line(choice: .buildCache, count: disk.buildCacheEntries,
                              bytes: disk.buildCacheReclaimable),
            .unusedVolumes: Line(choice: .unusedVolumes, count: unusedVolumes.count,
                                 bytes: unusedVolumes.reduce(0) { $0 + volumeBytes($1) },
                                 freedByStopped: unusedVolumes.count { !before.users(of: $0).isEmpty },
                                 largest: unusedVolumes.max { volumeBytes($0) < volumeBytes($1) }?.id)
        ]
    }

    func line(_ choice: Choice) -> Line { lines[choice]! }

    // `image prune --all` takes the untagged images with the tagged ones, so picking it
    // picks them too.
    static func effective(_ choices: Set<Choice>) -> Set<Choice> {
        choices.contains(.unusedImages) ? choices.union([.untaggedImages]) : choices
    }

    func total(_ choices: Set<Choice>) -> Int64 {
        Choice.allCases
            .filter { Self.effective(choices).contains($0) }
            .reduce(0) { $0 + line($1).bytes }
    }

    // Only the steps that have something to do, in the order docker should take them:
    // containers first, since they are what keep the rest in use. Pruning every unused
    // image already takes the untagged ones, so that step is not run twice.
    func steps(_ choices: Set<Choice>) -> [Choice] {
        let choices = Self.effective(choices)
        return Choice.allCases.filter { choices.contains($0) && !line($0).isEmpty }
            .filter { !($0 == .untaggedImages && choices.contains(.unusedImages) && !line(.unusedImages).isEmpty) }
    }

    // What the safe clean up would free, for the header and the rail.
    static func safeTotal(containers: [DockerContainer], images: [DockerImage], volumes: [DockerVolume],
                          networks: [DockerNetwork], volumeSizes: [String: Int64],
                          disk: DockerDiskUsage) -> Int64 {
        DockerCleanUp(containers: containers, images: images, volumes: volumes, networks: networks,
                      volumeSizes: volumeSizes, disk: disk, removingStopped: true).total(Choice.safe)
    }
}
