import AppKit
import SwiftUI

// One of the deployments the site file names, as a diagnosis sees it.
struct TroubleshootEnvironment: Identifiable, Equatable, Sendable {
    let name: String
    let title: String
    let isDangerous: Bool

    init(name: String, title: String, isDangerous: Bool = false) {
        self.name = name
        self.title = title
        self.isDangerous = isDangerous
    }

    init(_ environment: SiteDefaults.Environment) {
        self.init(name: environment.name,
                  title: environment.label,
                  isDangerous: environment.isDangerous)
    }

    var id: String { name }

    // The prompt gets the name the deployment goes by as well as its label, since "prd"
    // is what the agent will meet in URLs and namespaces while "Prod" is only on screen.
    var promptTitle: String {
        title.lowercased() == name.lowercased() ? name : "\(title) (\(name))"
    }

    static func all(in defaults: SiteDefaults = .current) -> [TroubleshootEnvironment] {
        defaults.deployEnvironments.map(TroubleshootEnvironment.init)
    }

    static func live(in defaults: SiteDefaults = .current) -> [TroubleshootEnvironment] {
        all(in: defaults).filter(\.isDangerous)
    }
}

struct TroubleshootRequest {
    let problem: String
    let incidentTime: String
    // Only a hint for where to look first. Every server goes with every diagnosis, since
    // one problem often spans deployments, and the shared Grafana belongs to none of them.
    let environment: TroubleshootEnvironment?
    let liveEnvironments: [TroubleshootEnvironment]
    let projects: [String]
    let skills: [String]
    let mcpServersEnabled: Bool
    let mcpServerNames: [String]
    let agent: AgentKind

    init(problem: String, incidentTime: String = "",
         environment: TroubleshootEnvironment? = nil,
         liveEnvironments: [TroubleshootEnvironment] = TroubleshootEnvironment.live(),
         projects: [String],
         skills: [String] = [], mcpServersEnabled: Bool, mcpServerNames: [String] = [],
         agent: AgentKind) {
        self.problem = problem
        self.incidentTime = incidentTime
        self.environment = environment
        self.liveEnvironments = liveEnvironments
        self.projects = projects
        self.skills = skills
        self.mcpServersEnabled = mcpServersEnabled
        self.mcpServerNames = mcpServerNames
        self.agent = agent
    }

    // The problem text already carries the ids, and any link they came in, so the agent
    // sees them as they were written. They are pulled out only to tell the agent to
    // start from them.
    var traceIDs: [String] { TraceInput.traceIDs(in: problem) }

    var userInput: String {
        var parts = [problem.isBlank
            ? "Troubleshoot the problem shown in the attached files."
            : problem.trimmed]
        if !incidentTime.isBlank {
            parts.append("Incident time window (as supplied): " + incidentTime.trimmed)
        }
        return parts.joined(separator: "\n\n")
    }

    var customInstructions: String {
        let projectText = projects.joined(separator: ", ")
        let mcpText: String
        if !mcpServersEnabled {
            mcpText = "MCP servers are disabled for this diagnosis."
        } else if mcpServerNames.isEmpty {
            mcpText = "MCP servers are enabled. Use them when they provide relevant logs, metrics, or service context."
        } else {
            let names = mcpServerNames.sorted().joined(separator: ", ")
            mcpText = """
            MCP servers are enabled: \(names). Their tools may be deferred from the initial tool list. Search the available tool catalogue for these server names before concluding that a server or tool is unavailable.
            """
        }
        let skillText: String
        if skills.isEmpty {
            skillText = "No skills were picked for this diagnosis."
        } else {
            let names = skills.sorted().map { "`\($0)`" }.joined(separator: ", ")
            skillText = """
            Skills to use: \(names). Load each one before the first step it covers, whatever the agent calls skills.
            """
        }
        // Claude is told how to draw a chart in its system prompt. The others have no
        // such channel, and a diagnosis is where a chart earns its place most often, so
        // the shape travels with the brief instead.
        let chartText = agent == .claudeCode
            ? ""
            : "\n\n\(TranscriptChartSpec.agentInstructions)"
        // The agent fetches the trace with its own tools and skills, which is what knows
        // which Grafana holds traces at this site; the app only draws what comes back.
        let traceText: String
        if traceIDs.isEmpty {
            traceText = ""
        } else {
            let ids = traceIDs.map { "`\($0)`" }.joined(separator: ", ")
            let start = traceIDs.count == 1 ? "Start from trace \(ids)." : "Start from traces \(ids)."
            traceText = "\n\n\(start) Fetch each whole trace with the Grafana MCP tools and the skills you have, and follow a skill's guidance on which Grafana holds traces. Draw each one as a ```\(TranscriptTraceSpec.fenceLanguage) block before going further. Then, for each service whose spans failed, read its logs for that trace ID on the Grafana that holds that service's logs, and put the lines the diagnosis rests on in a ```\(TranscriptLogsSpec.fenceLanguage) block."
        }
        let environmentText = environment.map {
            "Environment: \($0.promptTitle). Look there first, but follow the evidence if it leads to another environment."
        } ?? "Environment: not given. Work out where the problem is from the problem text and the evidence."
        // Servers for every environment are always there, so the live ones are named
        // whichever environment was picked.
        let liveText = liveEnvironments.isEmpty ? "" : {
            let names = liveEnvironments.map(\.promptTitle).joined(separator: ", ")
            let noun = liveEnvironments.count == 1 ? "environment" : "environments"
            return " Treat the \(noun) \(names) as live: do not mutate data, configuration, deployments, or running services there."
        }()

        return """
        Troubleshooting context:
        - \(environmentText)
        - Projects: \(projectText)
        - \(skillText)
        - \(mcpText)

        Investigate the problem and use read-only checks first. Do not change code or configuration.\(liveText) Explain the likely root cause, cite the evidence you found, and give concrete next steps. If a fix is needed, propose it and wait for a follow-up before applying it. Chart the measurements the root cause rests on.\(chartText)\(traceText)

        \(TranscriptEvidenceBlocks.agentInstructions)
        """
    }
}

struct TroubleshootMCPConfiguration: Equatable {
    let missing: [String]
    let disabled: [String]

    init(requiredNames: [String], registeredNames: Set<String>,
         disabledNames: Set<String> = []) {
        let required = Set(requiredNames)
        missing = required.subtracting(registeredNames).sorted()
        disabled = required.intersection(registeredNames).intersection(disabledNames).sorted()
    }

    var isAvailable: Bool { missing.isEmpty && disabled.isEmpty }
}
