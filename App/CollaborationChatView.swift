import CompanionCore
import SwiftUI

struct CollaborationChatView: View {
    let client: HostClient
    let workspaceID: String
    let item: CollabSidebarItem
    let allSidebarItems: [CollabSidebarItem]
    let contactGroups: [CollabContactGroup]
    let onOpenConversation: (ConversationListItem) -> Void
    let onChanged: () async -> Void

    @State private var messages: [CollabSpaceMessage] = []
    @State private var scheduled: [CollabScheduledMessage] = []
    @State private var cards: [CollabCard] = []
    @State private var members: [CollabSpaceMember] = []
    @State private var loading = true
    @State private var errorMessage: String?

    // Pagination & smart scroll state
    @State private var hasMoreBefore = false
    @State private var oldestSeq: Int64?
    @State private var isLoadingEarlier = false
    @State private var isNearBottom = true
    @State private var unreadCount = 0
    @State private var isInitialScrollPending = true
    @State private var pendingScrollToBottomAfterSend = false
    @State private var pollCount = 0

    // Composer state
    @State private var draftText = ""
    @State private var selectedMentions: [String] = []
    @State private var replyingTo: CollabSpaceMessage?
    @State private var delaySeconds: Int = 0
    @State private var sending = false

    // Sheets & navigation
    @State private var showingDetails = false
    @State private var showingExpandedComposer = false
    @State private var fullReaderMessage: CollabSpaceMessage?
    @State private var cardAnswerDraft: [String: String] = [:]
    @State private var headerReactionTrigger: Int = 0

    private static let bottomAnchorID = "__bottom_anchor__"
    private static let initialPageLimit = 80
    private static let directPollLimit = 40
    private static let quickEmojis = ["👍", "❤️", "🎉", "🚀", "👀", "💡"]
    private static let delayOptions: [(label: String, seconds: Int)] = [
        ("立即发送", 0),
        ("30 秒后", 30),
        ("1 分钟后", 60),
        ("5 分钟后", 300),
        ("15 分钟后", 900),
    ]

    private var spaceID: String { item.targetSpaceId }

    private var agentMembers: [CollabSpaceMember] {
        members.filter(\.isAgent)
    }

    private var isChatActive: Bool {
        sending
            || messages.contains(where: \.isStreamingDraft)
            || messages.contains { $0.receipts.contains(where: \.isProcessing) }
    }

    private var shouldShowExpandComposerButton: Bool {
        draftText.count > 80 || draftText.contains("\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !scheduled.isEmpty {
                scheduledBanner
            }

            messageStream

            if !cards.filter(\.isPending).isEmpty {
                pendingCardsStack
            }

            composerBar
        }
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    headerReactionTrigger += 1
                } label: {
                    HStack(spacing: 8) {
                        if item.isGroup {
                            let groupAvatars = (agentMembers.isEmpty ? item.membersPreview.map(\.botAvatar) : agentMembers.map(\.botAvatar))
                            CollabGroupAvatarView(
                                avatars: groupAvatars.isEmpty
                                    ? [CollabBotAvatarConfig.derive(seed: item.displayName)]
                                    : groupAvatars,
                                tagColorHex: item.tagColor,
                                size: 28,
                                sessionActive: isChatActive
                            )
                        } else {
                            let dmAvatar = item.member?.botAvatar
                                ?? CollabBotAvatarConfig.derive(seed: item.displayName)
                            MemberBotAvatarView(
                                config: dmAvatar,
                                size: 28,
                                animated: true,
                                sessionActive: isChatActive,
                                isSupervisor: item.member?.isSupervisor == true,
                                reactionTrigger: headerReactionTrigger
                            )
                        }

                        Text(item.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if item.isGroup, item.memberCount > 0 {
                            Text("(\(item.memberCount))")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingDetails = true
                } label: {
                    Image(systemName: item.isGroup ? "person.3" : "slider.horizontal.3")
                }
                .accessibilityLabel(item.isGroup ? "群组详情" : "助手详情")
            }
        }
        .sheet(isPresented: $showingDetails) {
            CollaborationDetailSheet(
                client: client,
                workspaceID: workspaceID,
                item: item,
                members: members,
                allSidebarItems: allSidebarItems,
                contactGroups: contactGroups,
                onOpenConversation: { conv in
                    showingDetails = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        onOpenConversation(conv)
                    }
                },
                onChanged: {
                    await pollUpdates(forceMembers: true, forceLatestTail: true)
                    await onChanged()
                }
            )
        }
        .sheet(item: $fullReaderMessage) { targetMessage in
            let cardByID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            CollabFullMessageReaderSheet(
                message: targetMessage,
                senderAvatar: resolveSenderAvatar(for: targetMessage),
                cardRecordsByID: cardByID,
                onResolveCard: { inlineCard, decision, answer, declined in
                    if let serverCard = cardByID[inlineCard.id] {
                        resolveCard(serverCard, decision: decision, answer: answer, declined: declined)
                    }
                }
            )
        }
        .sheet(isPresented: $showingExpandedComposer) {
            CollabExpandedComposerSheet(
                title: item.isGroup ? "编辑群消息" : "给 \(item.displayName) 发消息",
                isGroup: item.isGroup,
                agentMembers: agentMembers,
                draftText: $draftText,
                selectedMentions: $selectedMentions,
                replyingTo: $replyingTo,
                canSend: canSend,
                onToggleMention: { name in
                    toggleMention(name: name)
                },
                onSend: {
                    sendMessage()
                }
            )
        }
        .onDisappear {
            dismissKeyboard()
        }
        .task(id: spaceID) {
            resetForSpaceChange()
            try? await client.collabMarkRead(threadID: item.threadId)
            await initialLoad()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { break }
                pollCount += 1
                await pollUpdates(forceMembers: pollCount % 10 == 0, forceLatestTail: false)
            }
        }
    }

    // MARK: - Message Stream

    @ViewBuilder
    private var messageStream: some View {
        if loading && messages.isEmpty && errorMessage == nil {
            CollaborationChatSkeletonView()
        } else if let errorMessage, messages.isEmpty {
            Spacer()
            LoadFailureView(message: errorMessage) { Task { await initialLoad() } }
            Spacer()
        } else if messages.isEmpty {
            Spacer()
            ContentUnavailableView {
                Label(item.isGroup ? "群里还没有消息" : "还没有私聊消息", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(item.isGroup ? "用下方输入框发送消息，可 @ 指定助手协同处理" : "在下方输入内容即可与 \(item.displayName) 对话")
            }
            Spacer()
        } else {
            let messageByID = Dictionary(
                messages.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let cardByID = Dictionary(
                cards.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )

            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if hasMoreBefore {
                                CollabLoadEarlierButton(isLoadingEarlier: isLoadingEarlier) {
                                    Task {
                                        await loadEarlierMessages(proxy: proxy)
                                    }
                                }
                            }

                            ForEach(messages) { message in
                                CollabMessageRow(
                                    message: message,
                                    repliedMessage: resolvedRepliedMessage(for: message, in: messageByID),
                                    isGroup: item.isGroup,
                                    senderAvatar: resolveSenderAvatar(for: message),
                                    quickEmojis: Self.quickEmojis,
                                    cardRecordsByID: cardByID,
                                    onTapSender: {
                                        openSenderSession(for: message)
                                    },
                                    onReply: {
                                        withAnimation { replyingTo = message }
                                    },
                                    onReact: { emoji in
                                        react(to: message, emoji: emoji)
                                    },
                                    onCollect: {
                                        collectMessage(message)
                                    },
                                    onDistill: {
                                        distillMessage(message)
                                    },
                                    onOpenFullReader: {
                                        fullReaderMessage = message
                                    },
                                    onResolveInlineCard: { inlineCard, decision, answer, declined in
                                        if let serverCard = cardByID[inlineCard.id] {
                                            resolveCard(serverCard, decision: decision, answer: answer, declined: declined)
                                        }
                                    },
                                    onCancelReceiptTurn: { receipt in
                                        cancelTurn(for: receipt)
                                    }
                                )
                                .id(message.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                                .onAppear {
                                    isNearBottom = true
                                    unreadCount = 0
                                }
                                .onDisappear {
                                    isNearBottom = false
                                }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        if isInitialScrollPending, !messages.isEmpty {
                            scrollToBottom(proxy: proxy, animated: false)
                            isInitialScrollPending = false
                        }
                    }
                    .onChange(of: messages.last?.id) { oldLastID, newLastID in
                        guard newLastID != nil else { return }
                        if isInitialScrollPending {
                            scrollToBottom(proxy: proxy, animated: false)
                            isInitialScrollPending = false
                            pendingScrollToBottomAfterSend = false
                            unreadCount = 0
                        } else if isNearBottom || pendingScrollToBottomAfterSend {
                            scrollToBottom(proxy: proxy, animated: true)
                            pendingScrollToBottomAfterSend = false
                            unreadCount = 0
                        } else {
                            let finalizedExistingDraft = (oldLastID?.hasPrefix("draft:") == true)
                                && (messages.last?.isStreamingDraft == false)
                            if !finalizedExistingDraft || unreadCount == 0 {
                                unreadCount += 1
                            }
                        }
                    }
                    .onChange(of: messages.last?.envelope.content) { _, _ in
                        guard isNearBottom, messages.last?.isStreamingDraft == true else { return }
                        scrollToBottom(proxy: proxy, animated: false)
                    }

                    if !isNearBottom {
                        CollabJumpToBottomPill(unreadCount: unreadCount) {
                            isNearBottom = true
                            unreadCount = 0
                            scrollToBottom(proxy: proxy, animated: true)
                        }
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func resolvedRepliedMessage(
        for message: CollabSpaceMessage,
        in lookup: [String: CollabSpaceMessage]
    ) -> CollabSpaceMessage? {
        guard let replyID = message.inReplyTo, !replyID.isEmpty else { return nil }
        let clean = replyID.replacingOccurrences(of: "vibex://space-message/", with: "")
        return lookup[clean]
    }

    // MARK: - Scheduled Messages Banner

    private var scheduledBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(scheduled) { item in
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.content)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("定时投递：\(item.deliverAt)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") {
                        cancelScheduled(item)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
        }
    }

    // MARK: - Pending Approval & Ask Cards

    private var pendingCardsStack: some View {
        VStack(spacing: 8) {
            ForEach(cards.filter(\.isPending)) { card in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: card.kind == "approval" ? "checkmark.shield.fill" : "questionmark.circle.fill")
                            .foregroundStyle(card.kind == "approval" ? .orange : .blue)
                        Text(card.kind == "approval" ? "待审批请求" : "助手提问")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    if let text = card.question ?? card.reason ?? card.action ?? card.command {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }
                    if card.kind == "approval" {
                        HStack(spacing: 8) {
                            Button {
                                resolveCard(card, decision: "approved", answer: nil, declined: false)
                            } label: {
                                Text("批准")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                resolveCard(card, decision: "rejected", answer: nil, declined: true)
                            } label: {
                                Text("拒绝")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        if !card.options.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(card.options, id: \.self) { opt in
                                        Button(opt) {
                                            resolveCard(card, decision: nil, answer: opt, declined: false)
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            TextField(
                                "输入回答…",
                                text: Binding(
                                    get: { cardAnswerDraft[card.id] ?? "" },
                                    set: { cardAnswerDraft[card.id] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))

                            Button("发送") {
                                let ans = (cardAnswerDraft[card.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !ans.isEmpty else { return }
                                resolveCard(card, decision: nil, answer: ans, declined: false)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("跳过") {
                                resolveCard(card, decision: nil, answer: nil, declined: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Composer Bar

    private var composerBar: some View {
        VStack(spacing: 8) {
            if let reply = replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("回复 \(reply.envelope.displaySender)：\(CollabMessageFormatter.previewText(reply.envelope.content))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation { replyingTo = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 2)
            }

            if item.isGroup && !agentMembers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        mentionChip(name: "全体成员", label: "@全体成员", avatar: nil)
                        ForEach(agentMembers) { member in
                            mentionChip(
                                name: member.nickname,
                                label: "@\(member.nickname)",
                                avatar: member.botAvatar
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage, !messages.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            HStack(alignment: .bottom, spacing: 6) {
                if item.isGroup {
                    Menu {
                        ForEach(Self.delayOptions, id: \.seconds) { option in
                            Button {
                                delaySeconds = option.seconds
                            } label: {
                                HStack {
                                    Text(option.label)
                                    if delaySeconds == option.seconds {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } label: {
                        Image(systemName: delaySeconds > 0 ? "clock.badge.checkmark.fill" : "clock")
                            .font(.system(size: 17))
                            .foregroundStyle(delaySeconds > 0 ? Color.orange : Color.secondary)
                            .frame(width: 34, height: 36)
                    }
                    .accessibilityLabel("定时发送")
                }

                TextField(
                    item.isGroup ? "发送群消息（可点上方 @ 提及助手）…" : "给 \(item.displayName) 发消息…",
                    text: $draftText,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .font(.system(size: 15.5))
                .padding(.leading, item.isGroup ? 4 : 10)
                .padding(.vertical, 7)
                .frame(minHeight: 36)

                if shouldShowExpandComposerButton {
                    Button {
                        showingExpandedComposer = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展开全屏编辑")
                }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Color(.systemBackground) : Color.primary.opacity(0.36))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(canSend ? Color.primary : Color.primary.opacity(0.08))
                        )
                        .animation(.easeOut(duration: 0.18), value: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func toggleMention(name: String) {
        if selectedMentions.contains(name) {
            selectedMentions.removeAll { $0 == name }
        } else {
            selectedMentions.append(name)
            if !draftText.contains("@\(name)") {
                if draftText.hasSuffix("@") {
                    draftText += "\(name) "
                } else {
                    draftText = (draftText.isEmpty ? "" : draftText + " ") + "@\(name) "
                }
            }
        }
    }

    private func mentionChip(name: String, label: String, avatar: CollabBotAvatarConfig?) -> some View {
        let isSelected = selectedMentions.contains(name)
        return Button {
            toggleMention(name: name)
        } label: {
            HStack(spacing: 5) {
                if let avatar {
                    MemberBotAvatarView(config: avatar, size: 17)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? Color.blue : Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private func resolveSenderAvatar(for message: CollabSpaceMessage) -> CollabBotAvatarConfig {
        if item.isDirect, let dmMember = item.member {
            return dmMember.botAvatar
        }
        if let matched = agentMembers.first(where: {
            $0.nickname == message.envelope.sender || $0.conversationId == message.envelope.conversationId
        }) {
            return matched.botAvatar
        }
        if let preview = item.membersPreview.first(where: {
            $0.name == message.envelope.sender || $0.conversationId == message.envelope.conversationId
        }) {
            return preview.botAvatar
        }
        return CollabBotAvatarConfig.derive(seed: message.envelope.displaySender)
    }

    private var canSend: Bool {
        !sending && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Network & Incremental Pagination

    private func resetForSpaceChange() {
        messages = []
        scheduled = []
        cards = []
        members = []
        loading = true
        errorMessage = nil
        hasMoreBefore = false
        oldestSeq = nil
        isLoadingEarlier = false
        isNearBottom = true
        unreadCount = 0
        isInitialScrollPending = true
        pendingScrollToBottomAfterSend = false
        pollCount = 0
    }

    private func initialLoad() async {
        do {
            async let pageTask = client.collabMessages(
                spaceID: spaceID,
                latest: true,
                limit: Self.initialPageLimit
            )
            async let membersTask = item.isGroup ? client.collabSpaceMembers(spaceID: spaceID) : []
            let page = try await pageTask
            let loadedMembers = (try? await membersTask) ?? []
            let merged = CollabMessageTimeline.merge(
                existing: [],
                incoming: page.messages,
                replaceStreamingFromIncoming: true
            )
            messages = merged
            hasMoreBefore = page.hasMoreBefore
            oldestSeq = page.resolvedOldestSeq ?? CollabMessageTimeline.oldestConfirmedSeq(in: merged)
            scheduled = page.scheduled
            cards = page.cards
            if item.isGroup {
                members = loadedMembers
            }
            errorMessage = nil
        } catch {
            errorMessage = describeHostFailure(error)
        }
        loading = false
    }

    private func pollUpdates(forceMembers: Bool, forceLatestTail: Bool) async {
        if messages.isEmpty && !loading {
            await initialLoad()
            return
        }
        do {
            let shouldLoadMembers = item.isGroup && (forceMembers || members.isEmpty)
            async let membersTask: [CollabSpaceMember]? = shouldLoadMembers
                ? (try? await client.collabSpaceMembers(spaceID: spaceID))
                : nil

            let page: CollabMessagesPage
            if item.isDirect || spaceID.hasPrefix("direct:") {
                page = try await client.collabMessages(
                    spaceID: spaceID,
                    latest: true,
                    limit: Self.directPollLimit
                )
            } else if !forceLatestTail, let sinceSeq = CollabMessageTimeline.incrementalSinceSeq(for: messages) {
                page = try await client.collabMessages(
                    spaceID: spaceID,
                    sinceSeq: sinceSeq,
                    latest: false,
                    limit: Self.initialPageLimit
                )
            } else {
                page = try await client.collabMessages(
                    spaceID: spaceID,
                    latest: true,
                    limit: Self.directPollLimit
                )
            }

            let merged = CollabMessageTimeline.merge(
                existing: messages,
                incoming: page.messages,
                replaceStreamingFromIncoming: true
            )
            messages = merged
            if oldestSeq == nil {
                oldestSeq = page.resolvedOldestSeq ?? CollabMessageTimeline.oldestConfirmedSeq(in: merged)
            }
            scheduled = page.scheduled
            cards = page.cards
            if let refreshedMembers = await membersTask {
                members = refreshedMembers
            }
            errorMessage = nil
        } catch {
            errorMessage = describeHostFailure(error)
        }
    }

    private func loadEarlierMessages(proxy: ScrollViewProxy) async {
        guard !isLoadingEarlier, hasMoreBefore else { return }
        guard let cursor = oldestSeq ?? CollabMessageTimeline.oldestConfirmedSeq(in: messages),
              cursor > 1
        else {
            hasMoreBefore = false
            return
        }

        let anchorID = messages.first?.id
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }

        do {
            let page = try await client.collabMessages(
                spaceID: spaceID,
                beforeSeq: cursor,
                latest: false,
                limit: Self.initialPageLimit
            )
            guard !page.messages.isEmpty else {
                hasMoreBefore = false
                return
            }

            let merged = CollabMessageTimeline.merge(
                existing: messages,
                incoming: page.messages,
                replaceStreamingFromIncoming: false
            )
            hasMoreBefore = page.hasMoreBefore
            if let fetchedOldest = page.resolvedOldestSeq {
                oldestSeq = min(cursor, fetchedOldest)
            } else {
                oldestSeq = CollabMessageTimeline.oldestConfirmedSeq(in: merged)
            }

            var updateTx = Transaction()
            updateTx.disablesAnimations = true
            withTransaction(updateTx) {
                messages = merged
            }

            if let anchorID {
                var scrollTx = Transaction()
                scrollTx.disablesAnimations = true
                withTransaction(scrollTx) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = describeHostFailure(error)
        }
    }

    private func sendMessage() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        pendingScrollToBottomAfterSend = true
        let recipients = selectedMentions
        let replyID = replyingTo?.id
        let delay = delaySeconds > 0 ? delaySeconds : nil

        draftText = ""
        selectedMentions = []
        replyingTo = nil
        delaySeconds = 0

        Task {
            do {
                try await client.collabPostMessage(
                    spaceID: spaceID,
                    content: text,
                    to: recipients,
                    inReplyTo: replyID,
                    delaySeconds: delay
                )
                errorMessage = nil
                await pollUpdates(forceMembers: false, forceLatestTail: false)
                await onChanged()
            } catch {
                pendingScrollToBottomAfterSend = false
                errorMessage = describeHostFailure(error)
            }
            sending = false
        }
    }

    private func react(to message: CollabSpaceMessage, emoji: String) {
        Task {
            try? await client.collabReact(spaceID: spaceID, messageID: message.id, emoji: emoji)
            if item.isGroup, message.seq > 1 {
                if let page = try? await client.collabMessages(
                    spaceID: spaceID,
                    sinceSeq: Int64(message.seq - 1),
                    latest: false,
                    limit: 5
                ) {
                    messages = CollabMessageTimeline.merge(
                        existing: messages,
                        incoming: page.messages,
                        replaceStreamingFromIncoming: false
                    )
                    return
                }
            }
            await pollUpdates(forceMembers: false, forceLatestTail: true)
        }
    }

    private func collectMessage(_ message: CollabSpaceMessage) {
        Task {
            try? await client.collaborationCommand("space.addCollectionItem", input: [
                "spaceId": spaceID,
                "kind": "text",
                "name": "\(message.envelope.displaySender) 的消息",
                "content": message.envelope.content,
                "creatorNickname": "User",
            ])
        }
    }

    private func distillMessage(_ message: CollabSpaceMessage) {
        Task {
            try? await client.collaborationCommand("space.memory.distillMessage", input: [
                "spaceId": spaceID,
                "messageId": message.id,
                "content": message.envelope.content,
            ])
        }
    }

    private func cancelTurn(for receipt: CollabDeliveryReceipt) {
        guard let matched = agentMembers.first(where: {
            $0.conversationId == receipt.conversationId || $0.nickname == receipt.nickname
        }) else { return }
        Task {
            try? await client.collabCancelSpaceTurn(spaceID: spaceID, memberID: matched.memberId)
            await pollUpdates(forceMembers: false, forceLatestTail: true)
        }
    }

    private func cancelScheduled(_ scheduledItem: CollabScheduledMessage) {
        Task {
            try? await client.collaborationCommand("space.cancelScheduledMessage", input: [
                "spaceId": spaceID,
                "id": scheduledItem.id,
            ])
            await pollUpdates(forceMembers: false, forceLatestTail: false)
        }
    }

    private func resolveCard(_ card: CollabCard, decision: String?, answer: String?, declined: Bool) {
        Task {
            try? await client.collabResolveCard(
                cardID: card.id,
                decision: decision,
                answer: answer,
                declined: declined
            )
            cardAnswerDraft[card.id] = nil
            await pollUpdates(forceMembers: false, forceLatestTail: true)
        }
    }

    private func openSenderSession(for message: CollabSpaceMessage) {
        guard !message.isFromUser, !message.envelope.isSystem else { return }
        if let convID = message.envelope.conversationId, !convID.isEmpty {
            openConversation(id: convID, title: message.envelope.displaySender)
            return
        }
        if let matched = agentMembers.first(where: { $0.nickname == message.envelope.sender }) {
            openMemberSession(
                memberID: matched.resolvedIdentityId,
                fallbackConvID: matched.conversationId,
                title: matched.nickname
            )
        }
    }

    private func openMemberSession(memberID: String, fallbackConvID: String?, title: String) {
        Task {
            let resolved = (try? await client.collabResolveSession(memberID: memberID, threadID: item.threadId)) ?? fallbackConvID
            guard let convID = resolved, !convID.isEmpty else { return }
            openConversation(id: convID, title: title)
        }
    }

    private func openConversation(id: String, title: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "id": id,
            "workspace_id": workspaceID,
            "title": title,
            "message_count": 0,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]),
        let item = try? JSONDecoder().decode(ConversationListItem.self, from: data)
        else { return }
        onOpenConversation(item)
    }
}

// MARK: - Single Message Row (O(1) Pre-Resolved Reply Lookup)

private struct CollabMessageRow: View {
    let message: CollabSpaceMessage
    let repliedMessage: CollabSpaceMessage?
    let isGroup: Bool
    let senderAvatar: CollabBotAvatarConfig
    let quickEmojis: [String]
    let cardRecordsByID: [String: CollabCard]
    let onTapSender: () -> Void
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onCollect: () -> Void
    let onDistill: () -> Void
    let onOpenFullReader: () -> Void
    let onResolveInlineCard: (CollabInlineCard, String?, String?, Bool) -> Void
    let onCancelReceiptTurn: (CollabDeliveryReceipt) -> Void

    private var parsedContent: CollabParsedContent {
        CollabMessageFormatter.parse(message.envelope.content)
    }

    private var senderColor: Color {
        Color(collabHex: senderAvatar.color) ?? CollabTagPalette.hashColor(message.envelope.displaySender)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isFromUser {
                Spacer(minLength: 36)
            } else {
                Button(action: onTapSender) {
                    MemberBotAvatarView(
                        config: senderAvatar,
                        size: 32,
                        animated: true,
                        sessionActive: message.isStreamingDraft
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Button(action: onTapSender) {
                        Text(message.envelope.displaySender)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(message.isFromUser ? .secondary : senderColor)
                    }
                    .buttonStyle(.plain)

                    ForEach(message.envelope.recipientLabels, id: \.self) { target in
                        Text("@\(target)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                    }

                    if message.isStreamingDraft {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                if let replied = repliedMessage {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 2, height: 14)
                        Text("\(replied.envelope.displaySender)：\(CollabMessageFormatter.previewText(replied.envelope.content))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }

                let parsed = parsedContent
                CollabFormattedBubbleContent(
                    parsed: parsed,
                    isFromUser: message.isFromUser,
                    isStreaming: message.isStreamingDraft,
                    cardRecordsByID: cardRecordsByID,
                    onOpenFullReader: onOpenFullReader,
                    onResolveCard: onResolveInlineCard
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.isFromUser ? Color.blue : Color(.secondarySystemGroupedBackground))
                )
                .textSelection(.enabled)
                .contextMenu {
                    ForEach(quickEmojis, id: \.self) { emoji in
                        Button("\(emoji) 表情回应") { onReact(emoji) }
                    }
                    Divider()
                    Button {
                        onReply()
                    } label: {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                    }
                    Button {
                        UIPasteboard.general.string = message.envelope.content
                    } label: {
                        Label("复制内容", systemImage: "doc.on.doc")
                    }
                    Button {
                        onOpenFullReader()
                    } label: {
                        Label("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        onCollect()
                    } label: {
                        Label("加入空间收藏", systemImage: "bookmark")
                    }
                    Button {
                        onDistill()
                    } label: {
                        Label("提炼到空间记忆", systemImage: "brain")
                    }
                    if !message.isFromUser && !message.envelope.isSystem {
                        Divider()
                        Button {
                            onTapSender()
                        } label: {
                            Label("打开该助手会话", systemImage: "terminal")
                        }
                    }
                }

                // Reactions bar
                let reactions = message.groupedReactions
                if !reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(reactions, id: \.emoji) { r in
                            Button {
                                onReact(r.emoji)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(r.emoji)
                                        .font(.system(size: 12))
                                    Text("\(r.count)")
                                        .font(.system(size: 11, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(r.byUser ? .blue : .secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(r.byUser ? Color.blue.opacity(0.15) : Color.primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Delivery Receipts (for user messages in group/direct chats)
                if message.isFromUser && !message.receipts.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.receipts) { receipt in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(receiptColor(receipt.effectiveState))
                                    .frame(width: 6, height: 6)
                                if let nick = receipt.nickname, !nick.isEmpty {
                                    Text(nick)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                Text(receipt.stateLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                if isGroup && receipt.isProcessing {
                                    Button {
                                        onCancelReceiptTurn(receipt)
                                    } label: {
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }

            if !message.isFromUser {
                Spacer(minLength: 36)
            }
        }
    }

    private func receiptColor(_ state: String) -> Color {
        switch state {
        case "replied": return .green
        case "processing": return .blue
        case "queued", "dispatched": return .orange
        case "failed", "timed_out": return .red
        default: return .secondary
        }
    }
}
