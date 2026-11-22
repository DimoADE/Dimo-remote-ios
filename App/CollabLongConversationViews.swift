import CompanionCore
import SwiftUI
import UIKit

// MARK: - Formatted Bubble Content (Markdown Prose + Fenced Code + Structured XML + Collapsible Long Bubble)

struct CollabFormattedBubbleContent: View {
    let parsed: CollabParsedContent
    let isFromUser: Bool
    let isStreaming: Bool
    var cardRecordsByID: [String: CollabCard] = [:]
    let onOpenFullReader: () -> Void
    var onResolveCard: ((CollabInlineCard, String?, String?, Bool) -> Void)? = nil

    @State private var isExpanded = false

    private var isCollapsible: Bool {
        !isStreaming && parsed.shouldCollapse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if parsed.segments.isEmpty {
                Text(isStreaming ? "思考中…" : " ")
                    .font(.system(size: 14))
                    .foregroundStyle(isFromUser ? Color.white.opacity(0.8) : Color.secondary)
            } else if isCollapsible && !isExpanded {
                CollabSegmentsStack(
                    segments: parsed.segments,
                    isFromUser: isFromUser,
                    cardRecordsByID: cardRecordsByID,
                    onResolveCard: onResolveCard
                )
                .frame(maxHeight: 220, alignment: .top)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 48)
                    }
                )
            } else {
                CollabSegmentsStack(
                    segments: parsed.segments,
                    isFromUser: isFromUser,
                    cardRecordsByID: cardRecordsByID,
                    onResolveCard: onResolveCard
                )
            }

            if isCollapsible {
                Divider()
                    .overlay(isFromUser ? Color.white.opacity(0.24) : Color.primary.opacity(0.08))

                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isExpanded ? "收起" : "展开全文 · \(parsed.lineCount) 行")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(isFromUser ? Color.white : Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Button(action: onOpenFullReader) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("全屏阅读")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isFromUser ? Color.white.opacity(0.92) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Shared Segment Renderer

struct CollabSegmentsStack: View {
    let segments: [CollabContentSegment]
    let isFromUser: Bool
    var cardRecordsByID: [String: CollabCard] = [:]
    var onResolveCard: ((CollabInlineCard, String?, String?, Bool) -> Void)? = nil
    var bodyFontSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                switch segment {
                case .prose(_, let text):
                    CollabProseView(
                        text: text,
                        isFromUser: isFromUser,
                        baseFontSize: bodyFontSize
                    )
                case .codeBlock(_, let language, let code):
                    CollabFencedCodeBlockView(
                        language: language,
                        code: code,
                        isFromUser: isFromUser
                    )
                case .card(_, let card):
                    CollabStructuredCardView(
                        card: card,
                        serverCard: cardRecordsByID[card.id],
                        isFromUser: isFromUser,
                        onResolve: onResolveCard
                    )
                case .handoff(_, let handoff):
                    CollabStructuredHandoffView(
                        handoff: handoff,
                        isFromUser: isFromUser
                    )
                }
            }
        }
    }
}

// MARK: - Prose Renderer (Lightweight Block + Inline Markdown)

private struct CollabProseView: View {
    let text: String
    let isFromUser: Bool
    let baseFontSize: CGFloat

    private enum LineKind: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case bullet(id: Int, text: String)
        case numbered(id: Int, prefix: String, text: String)
        case quote(id: Int, text: String)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .bullet(let id, _),
                 .numbered(let id, _, _),
                 .quote(let id, _),
                 .paragraph(let id, _):
                return id
            }
        }
    }

    private var blocks: [LineKind] {
        let rawLines = text.components(separatedBy: "\n")
        var result: [LineKind] = []
        var paragraphBuffer: [String] = []
        var nextID = 0

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n")
            result.append(.paragraph(id: nextID, text: joined))
            nextID += 1
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = Self.parseHeading(trimmed) {
                flushParagraph()
                result.append(.heading(id: nextID, level: heading.level, text: heading.body))
                nextID += 1
            } else if let bulletBody = Self.parseBullet(trimmed) {
                flushParagraph()
                result.append(.bullet(id: nextID, text: bulletBody))
                nextID += 1
            } else if let numbered = Self.parseNumbered(trimmed) {
                flushParagraph()
                result.append(.numbered(id: nextID, prefix: numbered.prefix, text: numbered.body))
                nextID += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let quoteText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                result.append(.quote(id: nextID, text: quoteText))
                nextID += 1
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let content):
                    Text(Self.inlineMarkdown(content, isFromUser: isFromUser, baseSize: headingSize(level)))
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .foregroundStyle(isFromUser ? .white : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                case .bullet(_, let content):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: baseFontSize, weight: .bold))
                            .foregroundStyle(isFromUser ? Color.white.opacity(0.82) : Color.secondary)
                        Text(Self.inlineMarkdown(content, isFromUser: isFromUser, baseSize: baseFontSize))
                            .font(.system(size: baseFontSize))
                            .lineSpacing(3)
                            .foregroundStyle(isFromUser ? .white : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .numbered(_, let prefix, let content):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(prefix)
                            .font(.system(size: baseFontSize - 0.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(isFromUser ? Color.white.opacity(0.82) : Color.secondary)
                        Text(Self.inlineMarkdown(content, isFromUser: isFromUser, baseSize: baseFontSize))
                            .font(.system(size: baseFontSize))
                            .lineSpacing(3)
                            .foregroundStyle(isFromUser ? .white : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .quote(_, let content):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isFromUser ? Color.white.opacity(0.55) : Color.secondary.opacity(0.45))
                            .frame(width: 2.5)
                        Text(Self.inlineMarkdown(content, isFromUser: isFromUser, baseSize: baseFontSize - 0.5))
                            .font(.system(size: baseFontSize - 0.5))
                            .lineSpacing(3)
                            .foregroundStyle(isFromUser ? Color.white.opacity(0.9) : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)

                case .paragraph(_, let content):
                    Text(Self.inlineMarkdown(content, isFromUser: isFromUser, baseSize: baseFontSize))
                        .font(.system(size: baseFontSize))
                        .lineSpacing(3)
                        .foregroundStyle(isFromUser ? .white : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 2.5
        case 2: return baseFontSize + 1.5
        default: return baseFontSize + 0.5
        }
    }

    private static func parseHeading(_ line: String) -> (level: Int, body: String)? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...4).contains(hashes), line.count > hashes else { return nil }
        let idx = line.index(line.startIndex, offsetBy: hashes)
        guard line[idx] == " " else { return nil }
        let body = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : (hashes, body)
    }

    private static func parseBullet(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) {
                let body = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return body.isEmpty ? nil : body
            }
        }
        return nil
    }

    private static func parseNumbered(_ line: String) -> (prefix: String, body: String)? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let digits = line[..<dot]
        guard digits.count <= 4, digits.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let body = String(line[line.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : ("\(digits).", body)
    }

    static func inlineMarkdown(_ raw: String, isFromUser: Bool, baseSize: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: raw, options: options) else {
            return AttributedString(raw)
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: max(12, baseSize - 1), weight: .medium, design: .monospaced)
                attributed[run.range].backgroundColor = isFromUser
                    ? Color.white.opacity(0.2)
                    : Color.primary.opacity(0.08)
            } else if run.link != nil {
                attributed[run.range].foregroundColor = isFromUser ? .white : .accentColor
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

// MARK: - Opaque Fenced Code Block with Language Header + 1-Tap Copy

private struct CollabFencedCodeBlockView: View {
    let language: String
    let code: String
    let isFromUser: Bool

    @State private var copied = false

    private var headerLabel: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "CODE" : trimmed.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(headerLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isFromUser ? Color.white.opacity(0.85) : Color.secondary)

                Spacer(minLength: 8)

                Button {
                    UIPasteboard.general.string = code
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .milliseconds(1400))
                        withAnimation(.easeOut(duration: 0.15)) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(
                        copied
                            ? (isFromUser ? Color.white : Color.green)
                            : (isFromUser ? Color.white.opacity(0.88) : Color.secondary)
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isFromUser ? Color.white.opacity(0.14) : Color(.secondarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制代码" : "复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isFromUser ? Color.black.opacity(0.28) : Color(.tertiarySystemGroupedBackground))

            Divider()
                .overlay(isFromUser ? Color.white.opacity(0.14) : Color.primary.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(isFromUser ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isFromUser ? Color.black.opacity(0.2) : Color(.systemBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isFromUser ? Color.white.opacity(0.18) : Color.primary.opacity(0.1),
                    lineWidth: 0.75
                )
        )
    }
}

// MARK: - Structured `<card>` & `<handoff>` Bubble Cards

private struct CollabStructuredCardView: View {
    let card: CollabInlineCard
    let serverCard: CollabCard?
    let isFromUser: Bool
    var onResolve: ((CollabInlineCard, String?, String?, Bool) -> Void)? = nil

    private var isPending: Bool {
        serverCard?.isPending ?? false
    }

    private var statusBadgeText: String {
        if let serverCard {
            return serverCard.isPending ? "待处理" : "已处理"
        }
        return card.kind == .approval ? "审批" : "提问"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.kind == .approval ? "checkmark.shield.fill" : "questionmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        isFromUser
                            ? Color.white
                            : (card.kind == .approval ? Color.orange : Color.blue)
                    )
                Text(card.kind == .approval ? "审批请求" : "助手提问")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isFromUser ? .white : .primary)

                Spacer(minLength: 6)

                Text(statusBadgeText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(
                        isFromUser
                            ? Color.white.opacity(0.9)
                            : (isPending ? Color.orange : Color.secondary)
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            isFromUser
                                ? Color.white.opacity(0.18)
                                : (isPending ? Color.orange.opacity(0.14) : Color.primary.opacity(0.06))
                        )
                    )
            }

            if card.kind == .approval {
                if let action = card.action, !action.isEmpty {
                    Text(action)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isFromUser ? .white : .primary)
                }
                if let command = card.command, !command.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isFromUser ? .white : .primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isFromUser ? Color.black.opacity(0.2) : Color(.tertiarySystemGroupedBackground))
                    )
                }
                if let reason = card.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isFromUser ? Color.white.opacity(0.86) : Color.secondary)
                }
                if isPending, let onResolve {
                    HStack(spacing: 8) {
                        Button {
                            onResolve(card, "approved", nil, false)
                        } label: {
                            Text("批准")
                                .font(.system(size: 12.5, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            onResolve(card, "rejected", nil, true)
                        } label: {
                            Text("拒绝")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            } else {
                if let question = card.question, !question.isEmpty {
                    Text(question)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isFromUser ? .white : .primary)
                }
                if !card.options.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(card.options, id: \.self) { option in
                                if isPending, let onResolve {
                                    Button(option) {
                                        onResolve(card, nil, option, false)
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isFromUser ? .white : .blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(
                                            isFromUser ? Color.white.opacity(0.2) : Color.blue.opacity(0.12)
                                        )
                                    )
                                    .buttonStyle(.plain)
                                } else {
                                    Text(option)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(isFromUser ? Color.white.opacity(0.9) : Color.secondary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule().fill(
                                                isFromUser ? Color.white.opacity(0.16) : Color.primary.opacity(0.06)
                                            )
                                        )
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFromUser ? Color.white.opacity(0.14) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFromUser ? Color.white.opacity(0.2) : Color.primary.opacity(0.09),
                    lineWidth: 0.75
                )
        )
    }
}

private struct CollabStructuredHandoffView: View {
    let handoff: CollabInlineHandoff
    let isFromUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFromUser ? Color.white : Color.accentColor)
                Text("协作交接")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isFromUser ? .white : .primary)
                Spacer(minLength: 6)
                if let depth = handoff.depth, !depth.isEmpty {
                    Text("层级 \(depth)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isFromUser ? Color.white.opacity(0.88) : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isFromUser ? Color.white.opacity(0.16) : Color.primary.opacity(0.06))
                        )
                }
            }

            if let done = handoff.done, !done.isEmpty {
                handoffRow(label: "已完成", body: done)
            }
            if let constraints = handoff.inputsConstraints, !constraints.isEmpty {
                handoffRow(label: "上下文与约束", body: constraints)
            }
            if let ask = handoff.ask, !ask.isEmpty {
                handoffRow(label: "交接事项", body: ask)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFromUser ? Color.white.opacity(0.14) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFromUser ? Color.white.opacity(0.2) : Color.primary.opacity(0.09),
                    lineWidth: 0.75
                )
        )
    }

    private func handoffRow(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFromUser ? Color.white.opacity(0.8) : Color.secondary)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(isFromUser ? .white : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Full-Screen Long Message Reader Sheet

struct CollabFullMessageReaderSheet: View {
    let message: CollabSpaceMessage
    let senderAvatar: CollabBotAvatarConfig
    var cardRecordsByID: [String: CollabCard] = [:]
    var onResolveCard: ((CollabInlineCard, String?, String?, Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var copiedAll = false

    private var parsed: CollabParsedContent {
        CollabMessageFormatter.parse(message.envelope.content)
    }

    private var formattedTimestamp: String? {
        guard let raw = message.envelope.published, !raw.isEmpty else { return nil }
        if let date = message.envelope.publishedDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        return raw
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        if !message.isFromUser {
                            MemberBotAvatarView(
                                config: senderAvatar,
                                size: 34,
                                animated: false,
                                sessionActive: false
                            )
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.envelope.displaySender)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let formattedTimestamp {
                                Text(formattedTimestamp)
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(parsed.lineCount) 行")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                    }

                    Divider()

                    CollabSegmentsStack(
                        segments: parsed.segments,
                        isFromUser: false,
                        cardRecordsByID: cardRecordsByID,
                        onResolveCard: onResolveCard,
                        bodyFontSize: 15
                    )
                    .textSelection(.enabled)
                }
                .padding(16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("消息全文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = message.envelope.content
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeOut(duration: 0.15)) { copiedAll = true }
                        Task {
                            try? await Task.sleep(for: .milliseconds(1500))
                            withAnimation(.easeOut(duration: 0.15)) { copiedAll = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                            Text(copiedAll ? "已复制" : "复制全文")
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Floating Jump-to-Bottom Pill

struct CollabJumpToBottomPill: View {
    let unreadCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(unreadCount > 0 ? "↓ \(unreadCount) 条新消息" : "↓ 回到底部")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(unreadCount > 0 ? Color(.systemBackground) : Color.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(unreadCount > 0 ? Color.primary : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        unreadCount > 0 ? Color.clear : Color.primary.opacity(0.12),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unreadCount > 0 ? "\(unreadCount) 条新消息，回到底部" : "回到底部")
    }
}

// MARK: - Backward Pagination Header Button

struct CollabLoadEarlierButton: View {
    let isLoadingEarlier: Bool
    let onLoadEarlier: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onLoadEarlier) {
                HStack(spacing: 6) {
                    if isLoadingEarlier {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text("加载更早消息")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
                )
            }
            .buttonStyle(.plain)
            .disabled(isLoadingEarlier)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Expanded Full-Height Multi-Line Composer Sheet

struct CollabExpandedComposerSheet: View {
    let title: String
    let isGroup: Bool
    let agentMembers: [CollabSpaceMember]
    @Binding var draftText: String
    @Binding var selectedMentions: [String]
    @Binding var replyingTo: CollabSpaceMessage?
    let canSend: Bool
    let onToggleMention: (String) -> Void
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    private var lineCount: Int {
        draftText.isEmpty ? 1 : draftText.components(separatedBy: "\n").count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                            replyingTo = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground))
                }

                if isGroup && !agentMembers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            expandedMentionChip(name: "全体成员", label: "@全体成员", avatar: nil)
                            ForEach(agentMembers) { member in
                                expandedMentionChip(
                                    name: member.nickname,
                                    label: "@\(member.nickname)",
                                    avatar: member.botAvatar
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Color(.systemBackground))

                    Divider()
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draftText)
                        .focused($editorFocused)
                        .font(.system(size: 16))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .scrollContentBackground(.hidden)
                        .background(Color(.systemBackground))

                    if draftText.isEmpty {
                        Text(isGroup ? "输入长消息或需求说明，点上方芯片可 @ 指定助手…" : "输入长消息…")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                Divider()

                HStack {
                    Text("\(draftText.count) 字 · \(lineCount) 行")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground))
            }
            .background(Color(.systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSend()
                        dismiss()
                    } label: {
                        Text("发送")
                            .fontWeight(.semibold)
                    }
                    .disabled(!canSend)
                }
            }
            .onAppear {
                editorFocused = true
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func expandedMentionChip(name: String, label: String, avatar: CollabBotAvatarConfig?) -> some View {
        let isSelected = selectedMentions.contains(name)
        return Button {
            onToggleMention(name)
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
}
