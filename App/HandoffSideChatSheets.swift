import CompanionCore
import Observation
import SwiftUI

// MARK: Engine handoff

@MainActor
@Observable
final class EngineHandoffController {
    private let client: HostClient
    private let conversationID: String
    private(set) var instances: [ProviderInstanceItem] = []
    private(set) var preview: EngineHandoffPreview?
    private(set) var busy = false
    private(set) var done = false
    private(set) var error: String?
    var targetEngine: String?
    var targetInstanceID: String?

    init(client: HostClient, conversationID: String) {
        self.client = client
        self.conversationID = conversationID
    }

    func loadInstances() async {
        instances = (try? await client.providerInstances()) ?? []
    }

    func select(engine: String) {
        targetEngine = engine
        targetInstanceID = nil
        preview = nil
        error = nil
    }

    func select(instance: String?) {
        targetInstanceID = instance
        preview = nil
    }

    func loadPreview() async {
        guard let engine = targetEngine else { return }
        busy = true
        defer { busy = false }
        do {
            preview = try await client.previewEngineHandoff(
                conversationID: conversationID,
                targetEngine: engine,
                targetProviderInstanceID: targetInstanceID
            )
            error = nil
        } catch {
            preview = nil
            self.error = error.localizedDescription
        }
    }

    func confirm() async {
        guard let engine = targetEngine, preview != nil else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.confirmEngineHandoff(
                conversationID: conversationID,
                targetEngine: engine,
                targetProviderInstanceID: targetInstanceID
            )
            done = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct EngineHandoffSheet: View {
    @State private var controller: EngineHandoffController
    let agents: [CatalogAgent]
    let currentAgentID: String
    let writable: Bool
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        client: HostClient,
        conversationID: String,
        agents: [CatalogAgent],
        currentAgentID: String,
        writable: Bool,
        onDone: @escaping () -> Void
    ) {
        _controller = State(initialValue: EngineHandoffController(client: client, conversationID: conversationID))
        self.agents = agents
        self.currentAgentID = currentAgentID
        self.writable = writable
        self.onDone = onDone
    }

    private var targets: [CatalogAgent] {
        agents.filter { $0.usable && $0.id != currentAgentID }
    }

    private var targetInstances: [ProviderInstanceItem] {
        guard let engine = controller.targetEngine else { return [] }
        return instancesForAgent(controller.instances, agentID: engine)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("目标引擎") {
                    if targets.isEmpty {
                        Text("没有可切换的引擎").foregroundStyle(.secondary)
                    }
                    ForEach(targets) { agent in
                        Button {
                            controller.select(engine: agent.id)
                            Task { await controller.loadPreview() }
                        } label: {
                            HStack {
                                AgentIconView(agent: agent.id, size: 18)
                                Text(agent.displayName).foregroundStyle(.primary)
                                Spacer()
                                if controller.targetEngine == agent.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                if targetInstances.count > 1 {
                    Section("账号实例") {
                        ForEach(targetInstances) { inst in
                            Button {
                                controller.select(instance: inst.instanceID)
                                Task { await controller.loadPreview() }
                            } label: {
                                HStack {
                                    Text(inst.displayName + (inst.isDefault ? "（默认）" : ""))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if controller.targetInstanceID == inst.instanceID {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
                if let preview = controller.preview {
                    Section("交接预览") {
                        Text("将携带 \(preview.packedCount) 条消息，省略 \(preview.omittedCount) 条")
                        Text("约 \(preview.totalTokens) / \(preview.tokenBudget) tokens")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = controller.error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if !writable {
                    Section { Text("当前为只读或离线连接，无法执行切换。").foregroundStyle(.secondary).font(.footnote) }
                }
            }
            .navigationTitle("切换引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(controller.busy && controller.preview != nil ? "切换中…" : "确认切换") {
                        Task {
                            await controller.confirm()
                            if controller.done {
                                onDone()
                                dismiss()
                            }
                        }
                    }
                    .disabled(controller.preview == nil || controller.busy || !writable)
                }
            }
            .overlay { if controller.busy && controller.preview == nil { ProgressView() } }
            .task { await controller.loadInstances() }
        }
    }
}

// MARK: Side chat

@MainActor
@Observable
final class SideChatController {
    private let client: HostClient
    private let conversationID: String
    private let sideChatID = UUID().uuidString.lowercased()
    private(set) var messages: [SideChatMessage] = []
    private(set) var sending = false
    private var task: Task<Void, Never>?

    init(client: HostClient, conversationID: String) {
        self.client = client
        self.conversationID = conversationID
    }

    func send(_ prompt: String, items: [TimelineItem]) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let history = messages
        messages.append(SideChatMessage(id: UUID().uuidString, role: "user", content: text))
        sending = true
        let context = buildSideChatContext(items)
        task = Task { [client, conversationID, sideChatID] in
            do {
                let reply = try await client.sideChatSend(
                    conversationID: conversationID,
                    sideChatID: sideChatID,
                    prompt: text,
                    contextTurns: context,
                    history: history
                )
                messages.append(SideChatMessage(
                    id: UUID().uuidString, role: "assistant", content: reply.content, toolCalls: reply.toolCalls
                ))
            } catch is CancellationError {
            } catch {
                messages.append(SideChatMessage(
                    id: UUID().uuidString, role: "assistant", content: error.localizedDescription, isError: true
                ))
            }
            sending = false
        }
    }

    func abort() {
        guard sending else { return }
        task?.cancel()
        sending = false
        Task { [client, conversationID, sideChatID] in
            try? await client.sideChatAbort(conversationID: conversationID, sideChatID: sideChatID)
        }
    }
}

struct SideChatSheet: View {
    let controller: SideChatController
    let items: [TimelineItem]
    @State private var input = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if controller.messages.isEmpty {
                                Text("在不打断主对话的前提下提问。会带上最近几轮上下文。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(controller.messages) { msg in
                                bubble(msg).id(msg.id)
                            }
                            if controller.sending {
                                HStack { ProgressView().controlSize(.small); Text("思考中…").font(.footnote).foregroundStyle(.secondary) }
                                    .id("sending")
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: controller.messages.count) { _, _ in
                        if let last = controller.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("向旁路提问…", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    if controller.sending {
                        Button("停止") { controller.abort() }.buttonStyle(.bordered)
                    } else {
                        Button("发送") {
                            controller.send(input, items: items)
                            input = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
            }
            .navigationTitle("旁路对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func bubble(_ msg: SideChatMessage) -> some View {
        let isUser = msg.role == "user"
        return VStack(alignment: .leading, spacing: 4) {
            Text(msg.content)
                .font(.callout)
                .foregroundStyle(msg.isError ? Color.red : Color.primary)
                .textSelection(.enabled)
            ForEach(Array(msg.toolCalls.enumerated()), id: \.offset) { _, tool in
                Text("\(tool.name)\(tool.summary.isEmpty ? "" : " · " + tool.summary)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .background(
            (isUser ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
