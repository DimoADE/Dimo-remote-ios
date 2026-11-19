import Foundation

public struct ProviderInstanceItem: Equatable, Sendable, Identifiable {
    public let instanceID: String
    public let agentID: String
    public let displayName: String
    public let isDefault: Bool
    public var id: String { instanceID }
}

public struct EngineHandoffPreview: Equatable, Sendable {
    public let sourceEngine: String
    public let targetEngine: String
    public let packedCount: Int
    public let omittedCount: Int
    public let totalTokens: Int
    public let tokenBudget: Int
    public let promptText: String
}

public struct SideChatToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let summary: String
}

public struct SideChatReply: Equatable, Sendable {
    public let content: String
    public let toolCalls: [SideChatToolCall]
}

public struct SideChatContextTurn: Equatable, Sendable {
    public let turnNumber: Int
    public let userText: String
    public let assistantText: String
}

public struct SideChatMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let content: String
    public var toolCalls: [SideChatToolCall] = []
    public var isError = false

    public init(id: String, role: String, content: String, toolCalls: [SideChatToolCall] = [], isError: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.isError = isError
    }
}

private func text(_ obj: JSONValue, _ keys: String...) -> String {
    for key in keys {
        if let s = obj[key]?.stringValue, !s.isEmpty { return s }
    }
    return ""
}

private func int(_ obj: JSONValue, _ keys: String...) -> Int {
    for key in keys {
        if case .number(let n)? = obj[key] { return Int(n) }
    }
    return 0
}

public func parseProviderInstances(_ data: JSONValue) -> [ProviderInstanceItem] {
    let rows = data.arrayValue ?? data["items"]?.arrayValue ?? data["instances"]?.arrayValue ?? []
    return rows.compactMap { row in
        let instanceID = text(row, "instanceId", "instance_id")
        let agentID = text(row, "agentId", "agent_id")
        guard !instanceID.isEmpty, !agentID.isEmpty else { return nil }
        var isDefault = false
        if case .bool(let b)? = row["isDefault"] ?? row["is_default"] { isDefault = b }
        let name = text(row, "displayName", "display_name")
        return ProviderInstanceItem(
            instanceID: instanceID,
            agentID: agentID,
            displayName: name.isEmpty ? instanceID : name,
            isDefault: isDefault
        )
    }
}

public func parseEngineHandoffPreview(_ data: JSONValue) -> EngineHandoffPreview? {
    guard case .object = data else { return nil }
    return EngineHandoffPreview(
        sourceEngine: text(data, "sourceEngine", "source_engine"),
        targetEngine: text(data, "targetEngine", "target_engine"),
        packedCount: (data["packedMessages"] ?? data["packed_messages"])?.arrayValue?.count ?? 0,
        omittedCount: (data["omittedIds"] ?? data["omitted_ids"])?.arrayValue?.count ?? 0,
        totalTokens: int(data, "totalTokens", "total_tokens"),
        tokenBudget: int(data, "tokenBudget", "token_budget"),
        promptText: text(data, "handoffPromptText", "handoff_prompt_text")
    )
}

/// Instances for `agentID`, case-insensitive and tolerant of `-`/`_` differences.
public func instancesForAgent(_ all: [ProviderInstanceItem], agentID: String) -> [ProviderInstanceItem] {
    func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "-", with: "_") }
    return all.filter { norm($0.agentID) == norm(agentID) }
}

public func parseSideChatReply(_ data: JSONValue) -> SideChatReply? {
    guard case .object = data else { return nil }
    let tools: [SideChatToolCall] = (data["toolCalls"]?.arrayValue ?? []).compactMap { t in
        guard case .object = t else { return nil }
        let name = text(t, "name")
        return SideChatToolCall(
            id: text(t, "id"),
            name: name.isEmpty ? "tool" : name,
            status: text(t, "status"),
            summary: text(t, "summary")
        )
    }
    if let content = data["content"]?.stringValue {
        return SideChatReply(content: content, toolCalls: tools)
    }
    // Fall back to the terminal `done` stream event.
    for event in (data["events"]?.arrayValue ?? []).reversed() where event["type"]?.stringValue == "done" {
        if let content = event["content"]?.stringValue {
            return SideChatReply(content: content, toolCalls: tools)
        }
    }
    return nil
}

/// Last `maxTurns` user→assistant pairs as side-chat context (clipped like desktop: 600 chars).
public func buildSideChatContext(
    _ items: [TimelineItem],
    maxTurns: Int = 6,
    maxChars: Int = 600
) -> [SideChatContextTurn] {
    func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= maxChars ? t : String(t.prefix(maxChars)) + "…"
    }
    var turns: [(String, String)] = []
    var user: String?
    var assistant = ""
    func flush() {
        if let u = user { turns.append((clip(u), clip(assistant))) }
        user = nil
        assistant = ""
    }
    for item in items {
        switch item.role {
        case .user:
            flush()
            user = item.text
        case .assistant:
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if user != nil, !t.isEmpty {
                if !assistant.isEmpty { assistant += "\n\n" }
                assistant += t
            }
        case .divider:
            break
        }
    }
    flush()
    return turns.suffix(maxTurns).enumerated().map {
        SideChatContextTurn(turnNumber: $0.offset + 1, userText: $0.element.0, assistantText: $0.element.1)
    }
}

public func handoffArgs(
    conversationID: String,
    targetEngine: String,
    targetProviderInstanceID: String?,
    tokenBudget: Int?
) -> [String: Any] {
    var args: [String: Any] = ["conversationId": conversationID, "targetEngine": targetEngine]
    if let id = targetProviderInstanceID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
        args["targetProviderInstanceId"] = id
    }
    if let tokenBudget { args["tokenBudget"] = tokenBudget }
    return args
}

public func sideChatArgs(
    conversationID: String,
    sideChatID: String,
    prompt: String,
    contextTurns: [SideChatContextTurn],
    history: [SideChatMessage]
) -> [String: Any] {
    [
        "conversationId": conversationID,
        "sideChatId": sideChatID,
        "prompt": prompt,
        "contextTurns": contextTurns.map {
            ["turnNumber": $0.turnNumber, "userText": $0.userText, "assistantText": $0.assistantText] as [String: Any]
        },
        "history": history.filter { !$0.isError }.map { ["role": $0.role, "content": $0.content] },
    ]
}

extension HostClient {
    /// Side chat blocks until the agent finishes, so it outlives the default request timeout.
    public static let sideChatTimeout: TimeInterval = 200

    public func providerInstances() async throws -> [ProviderInstanceItem] {
        parseProviderInstances(try await call("provider_instances_list", as: JSONValue.self))
    }

    public func previewEngineHandoff(
        conversationID: String,
        targetEngine: String,
        targetProviderInstanceID: String?,
        tokenBudget: Int? = nil
    ) async throws -> EngineHandoffPreview {
        let res: JSONValue = try await call(
            "conversation_preview_engine_handoff",
            args: handoffArgs(
                conversationID: conversationID,
                targetEngine: targetEngine,
                targetProviderInstanceID: targetProviderInstanceID,
                tokenBudget: tokenBudget
            ),
            as: JSONValue.self
        )
        guard let preview = parseEngineHandoffPreview(res) else { throw HostError.malformedResponse }
        return preview
    }

    public func confirmEngineHandoff(
        conversationID: String,
        targetEngine: String,
        targetProviderInstanceID: String?,
        tokenBudget: Int? = nil
    ) async throws {
        let _: JSONValue = try await call(
            "conversation_confirm_engine_handoff",
            args: handoffArgs(
                conversationID: conversationID,
                targetEngine: targetEngine,
                targetProviderInstanceID: targetProviderInstanceID,
                tokenBudget: tokenBudget
            ),
            as: JSONValue.self
        )
    }

    public func sideChatSend(
        conversationID: String,
        sideChatID: String,
        prompt: String,
        contextTurns: [SideChatContextTurn],
        history: [SideChatMessage]
    ) async throws -> SideChatReply {
        let res: JSONValue = try await withRequestTimeout(Self.sideChatTimeout).call(
            "conversation_side_chat_send",
            args: sideChatArgs(
                conversationID: conversationID,
                sideChatID: sideChatID,
                prompt: prompt,
                contextTurns: contextTurns,
                history: history
            ),
            as: JSONValue.self
        )
        guard let reply = parseSideChatReply(res) else { throw HostError.malformedResponse }
        return reply
    }

    public func sideChatAbort(conversationID: String, sideChatID: String) async throws {
        let _: JSONValue = try await call(
            "conversation_side_chat_abort",
            args: ["conversationId": conversationID, "sideChatId": sideChatID],
            as: JSONValue.self
        )
    }
}
