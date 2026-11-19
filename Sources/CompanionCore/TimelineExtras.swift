import Foundation

/// Rate-limit recovery state derived from a `rate_limited` turn error. The Host's live
/// rate-limit push channel is not on the remote transport, so the banner is rebuilt from
/// the transcript row / `turn_failed` event.
public struct RateLimitBanner: Equatable, Sendable {
    public let rowID: String
    public let message: String
    public let resetAtMs: Int64?
    public let retryAfterSeconds: Int64?

    public init(rowID: String, message: String = "", resetAtMs: Int64? = nil, retryAfterSeconds: Int64? = nil) {
        self.rowID = rowID
        self.message = message
        self.resetAtMs = resetAtMs
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Whether the active binding can steer an in-flight turn. `nil` means the Host has not said.
public enum SteeringCapability {
    /// Reads `active_binding.capabilities` from `conversation_detail`; never guesses from agent identity.
    public static func from(conversationDetail detail: JSONValue?) -> Bool? {
        guard var root = detail else { return nil }
        if root["active_binding"] == nil, root["activeBinding"] == nil, let inner = root["data"] ?? root["conversation"] {
            root = inner
        }
        guard let binding = root["active_binding"] ?? root["activeBinding"],
              case .object = binding
        else { return false }
        guard let caps = binding["capabilities"], case .object = caps else { return false }
        return capability(from: caps) ?? false
    }

    /// `steering` / `steer` flags; nil when the object carries no steering signal.
    public static func capability(from caps: JSONValue) -> Bool? {
        for key in ["steering", "steer"] {
            if let value = caps[key] {
                if case .bool(let flag) = value { return flag }
                if case .object = value { return true }
            }
        }
        if caps["delivery_channel"] != nil || caps["deliveryChannel"] != nil { return false }
        return nil
    }
}

public enum TimelineExtras {
    /// Divider label for `agent_handoff` host notes; nil for every other session notice.
    public static func handoffLabel(fromNotice notice: JSONValue?) -> String? {
        guard let notice else { return nil }
        let announcement = (notice["announcement_id"] ?? notice["announcementId"])?.stringValue ?? ""
        guard announcement.hasPrefix("host-note:agent-handoff"),
              let message = notice["message"]?.stringValue,
              let data = message.data(using: .utf8),
              let structured = try? JSONDecoder().decode(JSONValue.self, from: data),
              let from = structured["fromAgent"]?.stringValue, !from.isEmpty,
              let to = structured["toAgent"]?.stringValue, !to.isEmpty
        else { return nil }
        let fork = structured["handoffKind"]?.stringValue == "fork"
        var label = (fork ? "Fork 交接" : "交接") + " · " + from
        if let model = structured["fromModel"]?.stringValue, !model.isEmpty { label += " (\(model))" }
        label += " → " + to
        if let model = structured["toModel"]?.stringValue, !model.isEmpty { label += " (\(model))" }
        if case .number(let tokens)? = structured["handoffTokens"], tokens > 0 {
            label += " · 约 \(Int64(tokens)) tokens"
        }
        return label
    }

    /// A banner for a turn error body of kind `rate_limited` (accepts the doubly nested `error.error` shape).
    public static func rateLimit(from error: JSONValue, rowID: String) -> RateLimitBanner? {
        let body = error["error"] ?? error
        guard body["kind"]?.stringValue == "rate_limited" else { return nil }
        let raw = body["raw"]
        func number(_ value: JSONValue?, _ keys: [String]) -> Int64? {
            for key in keys {
                if case .number(let n)? = value?[key] { return Int64(n) }
            }
            return nil
        }
        let windows = (body["plan_usage"] ?? body["planUsage"])?["windows"]?.arrayValue ?? []
        let planReset = windows.compactMap { number($0, ["resetsAtMs"]) }.min()
        let rawReset = number(raw, ["reset_at", "resetAt", "resets_at", "resetsAt"])
            .map { $0 < 1_000_000_000_000 ? $0 * 1000 : $0 }
        let retry = number(raw, ["retry_after_seconds", "retryAfterSeconds"]).flatMap { $0 > 0 ? $0 : nil }
        return RateLimitBanner(
            rowID: rowID,
            message: body["message"]?.stringValue ?? "",
            resetAtMs: planReset ?? rawReset,
            retryAfterSeconds: retry
        )
    }

    /// The banner for the transcript rows (in display order). It lapses once a later user message follows the error.
    public static func rateLimit(fromRows rows: [JSONValue]) -> RateLimitBanner? {
        var banner: RateLimitBanner?
        for row in rows {
            switch row["row"]?["kind"]?.stringValue {
            case "turn_error":
                guard let error = row["row"]?["error"] else { continue }
                banner = rateLimit(from: error, rowID: row["row_id"]?.stringValue ?? "") ?? banner
            case "message_turn":
                if row["row"]?["turn"]?["role"]?.stringValue == "user" { banner = nil }
            default:
                continue
            }
        }
        return banner
    }
}
