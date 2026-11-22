import Foundation

// MARK: - Incremental Message Timeline & Pagination Cursor

public enum CollabMessageTimeline {
    /// Merges `existing` and `incoming` messages deterministically:
    /// - Deduplicates confirmed messages by `id`, normalized `rawId`, `operationId`, or positive `seq`.
    /// - Reconciles `streaming` (`draft:...`) items when updated streaming text or a finalized non-streaming reply arrives,
    ///   and clears disappeared streaming drafts when `replaceStreamingFromIncoming` is `true`.
    /// - Sorts deterministically by `seq` ascending while keeping live streaming drafts at the tail.
    public static func merge(
        existing: [CollabSpaceMessage],
        incoming: [CollabSpaceMessage],
        replaceStreamingFromIncoming: Bool = true
    ) -> [CollabSpaceMessage] {
        var confirmed: [CollabSpaceMessage] = []
        var streamingDrafts: [CollabSpaceMessage] = []

        func normalizedID(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let clean = raw
                .replacingOccurrences(of: "vibex://space-message/", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }

        func matchesConfirmed(_ lhs: CollabSpaceMessage, _ rhs: CollabSpaceMessage) -> Bool {
            if lhs.id == rhs.id { return true }
            if let lRaw = normalizedID(lhs.rawId), let rRaw = normalizedID(rhs.rawId), lRaw == rRaw {
                return true
            }
            if let lOp = normalizedID(lhs.operationId), let rOp = normalizedID(rhs.operationId), lOp == rOp {
                return true
            }
            if lhs.seq > 0, rhs.seq > 0, lhs.seq == rhs.seq {
                return true
            }
            return false
        }

        func draftTurnKey(_ msg: CollabSpaceMessage) -> String? {
            if let turnId = normalizedID(msg.turnId) {
                return turnId
            }
            let id = msg.id
            guard id.hasPrefix("draft:") else { return nil }
            let rest = String(id.dropFirst("draft:".count))
            if let colon = rest.firstIndex(of: ":") {
                let prefix = String(rest[..<colon])
                return prefix.isEmpty ? nil : prefix
            }
            return rest.isEmpty ? nil : rest
        }

        func matchesDraft(_ lhs: CollabSpaceMessage, _ rhs: CollabSpaceMessage) -> Bool {
            if lhs.id == rhs.id { return true }
            if let lRaw = normalizedID(lhs.rawId), let rRaw = normalizedID(rhs.rawId), lRaw == rRaw {
                return true
            }
            if let lTurn = draftTurnKey(lhs), let rTurn = draftTurnKey(rhs), lTurn == rTurn {
                return true
            }
            return false
        }

        func upsertConfirmed(_ item: CollabSpaceMessage) {
            if let idx = confirmed.firstIndex(where: { matchesConfirmed($0, item) }) {
                confirmed[idx] = item
            } else {
                confirmed.append(item)
            }
        }

        func upsertDraft(_ item: CollabSpaceMessage) {
            if let idx = streamingDrafts.firstIndex(where: { matchesDraft($0, item) }) {
                streamingDrafts[idx] = item
            } else {
                streamingDrafts.append(item)
            }
        }

        for msg in existing {
            if msg.isStreamingDraft {
                if !replaceStreamingFromIncoming {
                    upsertDraft(msg)
                }
            } else {
                upsertConfirmed(msg)
            }
        }

        for msg in incoming {
            if msg.isStreamingDraft {
                upsertDraft(msg)
            } else {
                upsertConfirmed(msg)
            }
        }

        // Remove any streaming draft superseded by a confirmed non-streaming reply for the same turn, id, or sender+reply target.
        let finalizedTurnIDs = Set(confirmed.compactMap { normalizedID($0.turnId) })
        let finalizedIDs = Set(confirmed.map(\.id))
        streamingDrafts.removeAll { draft in
            if finalizedIDs.contains(draft.id) {
                return true
            }
            if let dTurn = draftTurnKey(draft), finalizedTurnIDs.contains(dTurn) {
                return true
            }
            return confirmed.contains { finalMsg in
                !finalMsg.isFromUser
                    && finalMsg.envelope.displaySender == draft.envelope.displaySender
                    && finalMsg.seq >= draft.seq
                    && finalMsg.seq > 0
                    && finalMsg.envelope.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        == draft.envelope.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let sortedConfirmed = confirmed.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if a.seq > 0, b.seq > 0, a.seq != b.seq {
                return a.seq < b.seq
            }
            if a.seq != b.seq {
                return a.seq < b.seq
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let sortedDrafts = streamingDrafts.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if a.seq != b.seq {
                return a.seq < b.seq
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return sortedConfirmed + sortedDrafts
    }

    public static func highestConfirmedSeq(in messages: [CollabSpaceMessage]) -> Int64? {
        messages
            .filter { !$0.isStreamingDraft && $0.seq > 0 }
            .map { Int64($0.seq) }
            .max()
    }

    public static func oldestConfirmedSeq(in messages: [CollabSpaceMessage]) -> Int64? {
        messages
            .filter { !$0.isStreamingDraft && $0.seq > 0 }
            .map { Int64($0.seq) }
            .min()
    }

    /// Computes the `sinceSeq` cursor for background group polling.
    /// Steps back just before any message with an active (`queued`/`processing`) delivery receipt
    /// so receipt state transitions (`processing` -> `replied`) are picked up without full reloads.
    public static func incrementalSinceSeq(for messages: [CollabSpaceMessage]) -> Int64? {
        guard let highest = highestConfirmedSeq(in: messages) else {
            return nil
        }
        let earliestActiveReceiptSeq = messages
            .filter { !$0.isStreamingDraft && $0.seq > 0 && $0.receipts.contains(where: \.isProcessing) }
            .map { Int64($0.seq) }
            .min()
        if let activeSeq = earliestActiveReceiptSeq {
            return activeSeq > 1 ? (activeSeq - 1) : nil
        }
        return highest
    }
}

// MARK: - Structured Collaboration Message Formatter (`<card>`, `<handoff>`, Fenced Code, Collapse)

public struct CollabInlineCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case ask
        case approval
    }

    public let id: String
    public let kind: Kind
    public let question: String?
    public let options: [String]
    public let action: String?
    public let command: String?
    public let reason: String?

    public init(
        id: String,
        kind: Kind,
        question: String? = nil,
        options: [String] = [],
        action: String? = nil,
        command: String? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.question = question
        self.options = options
        self.action = action
        self.command = command
        self.reason = reason
    }
}

public struct CollabInlineHandoff: Equatable, Sendable, Identifiable {
    public let id: String
    public let depth: String?
    public let done: String?
    public let inputsConstraints: String?
    public let ask: String?

    public init(
        id: String,
        depth: String? = nil,
        done: String? = nil,
        inputsConstraints: String? = nil,
        ask: String? = nil
    ) {
        self.id = id
        self.depth = depth
        self.done = done
        self.inputsConstraints = inputsConstraints
        self.ask = ask
    }
}

public enum CollabContentSegment: Equatable, Sendable, Identifiable {
    case prose(id: Int, text: String)
    case codeBlock(id: Int, language: String, code: String)
    case card(id: Int, card: CollabInlineCard)
    case handoff(id: Int, handoff: CollabInlineHandoff)

    public var id: Int {
        switch self {
        case .prose(let id, _),
             .codeBlock(let id, _, _),
             .card(let id, _),
             .handoff(let id, _):
            return id
        }
    }
}

public struct CollabParsedContent: Equatable, Sendable {
    public static let collapseLineThreshold = 12
    public static let collapseCharThreshold = 480

    public let segments: [CollabContentSegment]
    public let lineCount: Int
    public let charCount: Int
    public let shouldCollapse: Bool

    public var cards: [CollabInlineCard] {
        segments.compactMap {
            if case .card(_, let card) = $0 { return card }
            return nil
        }
    }

    public var handoffs: [CollabInlineHandoff] {
        segments.compactMap {
            if case .handoff(_, let handoff) = $0 { return handoff }
            return nil
        }
    }

    public init(
        segments: [CollabContentSegment],
        lineCount: Int,
        charCount: Int,
        shouldCollapse: Bool
    ) {
        self.segments = segments
        self.lineCount = lineCount
        self.charCount = charCount
        self.shouldCollapse = shouldCollapse
    }
}

public enum CollabMessageFormatter {
    private static let fenceRegex = try! NSRegularExpression(
        pattern: #"(?:^|\n)[ \t]{0,3}(`{3,}|~{3,})([^\n]*)\n([\s\S]*?)(?:\n[ \t]{0,3}\1(?=[ \t]*(?:\n|$))|$)"#
    )
    private static let cardRegex = try! NSRegularExpression(
        pattern: #"<card\b([^>]*)>([\s\S]*?)(?:</card>|$)"#,
        options: [.caseInsensitive]
    )
    private static let handoffRegex = try! NSRegularExpression(
        pattern: #"<handoff\b([^>]*)>([\s\S]*?)(?:</handoff>|$)"#,
        options: [.caseInsensitive]
    )
    private static let strayOpenTagRegex = try! NSRegularExpression(
        pattern: #"<(?:card|handoff)\b[^>]*$"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ rawContent: String) -> CollabParsedContent {
        let normalized = rawContent.replacingOccurrences(of: "\r\n", with: "\n")
        var segments: [CollabContentSegment] = []
        var nextID = 0

        func appendProse(_ slice: String) {
            let cleaned = stripStrayOpenXML(slice).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            segments.append(.prose(id: nextID, text: cleaned))
            nextID += 1
        }

        let ns = normalized as NSString
        var cursor = 0

        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let fenceMatch = fenceRegex.firstMatch(in: normalized, range: searchRange)
            let cardMatch = cardRegex.firstMatch(in: normalized, range: searchRange)
            let handoffMatch = handoffRegex.firstMatch(in: normalized, range: searchRange)

            enum TokenKind {
                case fence(NSTextCheckingResult, effectiveStart: Int)
                case card(NSTextCheckingResult)
                case handoff(NSTextCheckingResult)

                var startLocation: Int {
                    switch self {
                    case .fence(_, let start): return start
                    case .card(let m), .handoff(let m): return m.range.location
                    }
                }
            }

            var candidates: [TokenKind] = []
            if let f = fenceMatch {
                // If matched via leading `\n`, keep that `\n` as part of preceding prose.
                let startsWithNewline = ns.substring(with: NSRange(location: f.range.location, length: 1)) == "\n"
                let effectiveStart = startsWithNewline ? f.range.location + 1 : f.range.location
                candidates.append(.fence(f, effectiveStart: effectiveStart))
            }
            if let c = cardMatch {
                candidates.append(.card(c))
            }
            if let h = handoffMatch {
                candidates.append(.handoff(h))
            }

            guard let earliest = candidates.min(by: { $0.startLocation < $1.startLocation }) else {
                appendProse(ns.substring(with: searchRange))
                break
            }

            if earliest.startLocation > cursor {
                let prefixRange = NSRange(location: cursor, length: earliest.startLocation - cursor)
                appendProse(ns.substring(with: prefixRange))
            }

            switch earliest {
            case .fence(let match, _):
                let lang = ns.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body = ns.substring(with: match.range(at: 3))
                segments.append(.codeBlock(id: nextID, language: lang, code: body))
                nextID += 1
                cursor = match.range.location + match.range.length

            case .card(let match):
                let attrs = ns.substring(with: match.range(at: 1))
                let inner = ns.substring(with: match.range(at: 2))
                let card = parseInlineCard(attrs: attrs, inner: inner, fallbackIndex: nextID)
                segments.append(.card(id: nextID, card: card))
                nextID += 1
                cursor = match.range.location + match.range.length

            case .handoff(let match):
                let attrs = ns.substring(with: match.range(at: 1))
                let inner = ns.substring(with: match.range(at: 2))
                let handoff = parseInlineHandoff(attrs: attrs, inner: inner, fallbackIndex: nextID)
                segments.append(.handoff(id: nextID, handoff: handoff))
                nextID += 1
                cursor = match.range.location + match.range.length
            }
        }

        let metrics = computeMetrics(normalizedRaw: normalized, segments: segments)
        let shouldCollapse = metrics.lineCount > CollabParsedContent.collapseLineThreshold
            || metrics.charCount > CollabParsedContent.collapseCharThreshold

        return CollabParsedContent(
            segments: segments,
            lineCount: metrics.lineCount,
            charCount: metrics.charCount,
            shouldCollapse: shouldCollapse
        )
    }

    /// One-line human-readable preview (never exposes raw `<card>` or `<handoff>` XML).
    public static func previewText(_ rawContent: String) -> String {
        let parsed = parse(rawContent)
        var parts: [String] = []
        for segment in parsed.segments {
            switch segment {
            case .prose(_, let text):
                parts.append(text)
            case .codeBlock(_, let lang, let code):
                let firstLine = code.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
                parts.append(lang.isEmpty ? "[代码] \(firstLine)" : "[\(lang)] \(firstLine)")
            case .card(_, let card):
                switch card.kind {
                case .approval:
                    parts.append("审批请求：\(card.action ?? card.command ?? "待处理")")
                case .ask:
                    parts.append("提问：\(card.question ?? "待回答")")
                }
            case .handoff(_, let handoff):
                if let ask = handoff.ask, !ask.isEmpty {
                    parts.append("交接：\(ask)")
                } else if let done = handoff.done, !done.isEmpty {
                    parts.append("交接：\(done)")
                } else {
                    parts.append("协作交接")
                }
            }
        }
        return parts
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func computeMetrics(
        normalizedRaw: String,
        segments: [CollabContentSegment]
    ) -> (lineCount: Int, charCount: Int) {
        let hasStructuredXML = segments.contains {
            switch $0 {
            case .card, .handoff: return true
            case .prose, .codeBlock: return false
            }
        }
        if !hasStructuredXML {
            let trimmed = stripStrayOpenXML(normalizedRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (0, 0) }
            let lines = trimmed.components(separatedBy: "\n").count
            return (lines, trimmed.count)
        }

        var visibleBlocks: [String] = []
        for segment in segments {
            switch segment {
            case .prose(_, let text):
                visibleBlocks.append(text)
            case .codeBlock(_, _, let code):
                visibleBlocks.append(code)
            case .card(_, let card):
                let fields = [card.question, card.action, card.command, card.reason]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !fields.isEmpty {
                    visibleBlocks.append(fields.joined(separator: "\n"))
                }
            case .handoff(_, let handoff):
                let fields = [handoff.done, handoff.inputsConstraints, handoff.ask]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !fields.isEmpty {
                    visibleBlocks.append(fields.joined(separator: "\n"))
                }
            }
        }
        let joined = visibleBlocks.joined(separator: "\n")
        guard !joined.isEmpty else { return (0, 0) }
        return (joined.components(separatedBy: "\n").count, joined.count)
    }

    private static func stripStrayOpenXML(_ text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return strayOpenTagRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func parseInlineCard(attrs: String, inner: String, fallbackIndex: Int) -> CollabInlineCard {
        let rawKind = xmlAttribute(in: attrs, name: "kind")?.lowercased() ?? "ask"
        let kind: CollabInlineCard.Kind = rawKind == "approval" ? .approval : .ask
        let id = xmlAttribute(in: attrs, name: "id") ?? "card-\(fallbackIndex)"

        switch kind {
        case .ask:
            let question = xmlTagBody(in: inner, tag: "question")
            let rawOptions = xmlTagBody(in: inner, tag: "options") ?? ""
            let options = rawOptions
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return CollabInlineCard(
                id: id,
                kind: .ask,
                question: question,
                options: options
            )
        case .approval:
            return CollabInlineCard(
                id: id,
                kind: .approval,
                action: xmlTagBody(in: inner, tag: "action"),
                command: xmlTagBody(in: inner, tag: "command"),
                reason: xmlTagBody(in: inner, tag: "reason")
            )
        }
    }

    private static func parseInlineHandoff(attrs: String, inner: String, fallbackIndex: Int) -> CollabInlineHandoff {
        let id = xmlAttribute(in: attrs, name: "id") ?? "handoff-\(fallbackIndex)"
        let depth = xmlAttribute(in: attrs, name: "depth")
        return CollabInlineHandoff(
            id: id,
            depth: depth,
            done: xmlTagBody(in: inner, tag: "done"),
            inputsConstraints: xmlTagBody(in: inner, tag: "inputs_constraints"),
            ask: xmlTagBody(in: inner, tag: "ask")
        )
    }

    private static func xmlAttribute(in attrs: String, name: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = attrs as NSString
        guard let match = regex.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let value = unescapeXML(ns.substring(with: match.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func xmlTagBody(in inner: String, tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)>([\\s\\S]*?)(?:</\(escaped)>|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = inner as NSString
        guard let match = regex.firstMatch(in: inner, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let body = unescapeXML(ns.substring(with: match.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func unescapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
