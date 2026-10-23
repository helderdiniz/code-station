# ADR-0001: Persistent agent sessions

## Status

Accepted

## Context

The waiting notice represents background work that the agent still owns. Code Station must know when that work ends, accept follow-up messages in the same conversation, and stop the work when the user ends the wait.

## Decision

Claude uses its streaming CLI protocol. Codex uses its local app server, and Copilot uses its headless server. Each run owns one process group and one conversation. The servers remain alive while background tasks are pending and close after the conversation becomes idle with no tasks left.

`AgentLaunchConfiguration` resolves the model, access settings, workspace roots, and MCP options. Command-line arguments and `AgentServerLaunch` parameters are built from that value. Prompts remain data and never determine permissions. `AgentMessageFramer` extracts complete messages, and `AgentRequestTracker` matches replies and checks timeouts. `AgentSessionConnection` handles initialization, agent notifications, task lists, and cancellation. Adapters map decoded payloads directly into `StreamEvent` values. `SessionRunner` owns the queue, wait threshold, process lifetime, and process cleanup, and writes agent events into `ProjectStore`. `AgentCatalog` owns executable availability, discovered models, and defaults. `SessionFollowUps` requests titles, recaps, and suggestions through the runner, which retains ownership of summary turns and cancellation. `SessionComposerStore` owns unsent input and prompt-history navigation.

Codex supplies background terminals and child-agent states. Copilot supplies its session task list. While waiting, task lists are refreshed every five seconds. A generation counter prevents a delayed task-list response from finishing a newer turn. Task updates do not reset the three-minute notice threshold.

Tool access remains governed by the session's selected policy. The connection does not approve requests that fall outside it. User questions can be answered through the existing question card. Unknown server requests receive an explicit error.

## Consequences

The same waiting notice, follow-up flow, and end-turn action work across the three agent integrations. Commands reported directly by a server remain available even when a transcript tool-call ID is absent.

The installed Codex and Copilot versions must support the server and task-list APIs. Unsupported requests fail visibly instead of being interpreted as an empty task list. Protocol and runner fixtures cover ordinary tests; live timer tests require working accounts and are opt-in.
