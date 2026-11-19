import Foundation
import Testing
@testable import CompanionCore

private func rows(_ raw: String) throws -> [JSONValue] {
    try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
}

@Test func handoffNoticeBecomesDividerRow() throws {
    let message = #"{\"fromAgent\":\"claude\",\"toAgent\":\"codex\",\"toModel\":\"gpt-5\",\"handoffTokens\":1200}"#
    let list = try rows("""
    [{"row_id":"n1","revision":1,"row":{"kind":"session_notice","notice":{"announcement_id":"host-note:agent-handoff:1","message":"\(message)"}}},
     {"row_id":"n2","revision":1,"row":{"kind":"session_notice","notice":{"announcement_id":"other","message":"{}"}}}]
    """)
    let items = TimelineBuilder.build(fromRows: list)
    #expect(items.count == 1)
    #expect(items[0].role == .divider)
    #expect(items[0].text == "交接 · claude → codex (gpt-5) · 约 1200 tokens")
}

@Test func rateLimitBannerFromTurnErrorLapsesAfterNextUserMessage() throws {
    let err = #"{"row_id":"e1","revision":1,"row":{"kind":"turn_error","error":{"error":{"kind":"rate_limited","message":"slow","raw":{"retry_after_seconds":30}}}}}"#
    let user = #"{"row_id":"u1","revision":1,"row":{"kind":"message_turn","turn":{"id":"t","role":"user","blocks":[]}}}"#
    let banner = TimelineExtras.rateLimit(fromRows: try rows("[\(err)]"))
    #expect(banner?.retryAfterSeconds == 30)
    #expect(banner?.rowID == "e1")
    #expect(TimelineExtras.rateLimit(fromRows: try rows("[\(err),\(user)]")) == nil)
}

@Test func turnFailedEventSetsAndTurnCompletedClearsRateLimit() throws {
    func event(_ seq: Int64, _ kind: String, _ payload: String) throws -> RemoteEvent {
        try JSONDecoder().decode(
            RemoteEvent.self,
            from: Data(#"{"sequence":\#(seq),"kind":"\#(kind)","payload":\#(payload)}"#.utf8)
        )
    }
    let failed = try [
        event(1, "user_turn_started", #"{"turn_id":"t1"}"#),
        event(2, "turn_failed", #"{"error":{"kind":"rate_limited","raw":{"reset_at":1800000000}}}"#),
    ]
    let state = SessionStateBuilder.build(from: failed)
    #expect(state.rateLimit?.resetAtMs == 1_800_000_000_000)
    #expect(state.inFlightTurnID == nil)
    let running = SessionStateBuilder.build(from: [try event(1, "user_turn_started", #"{"turn_id":"t9"}"#)])
    #expect(running.inFlightTurnID == "t9")
    let done = SessionStateBuilder.build(from: failed + [try event(3, "turn_completed", "{}")])
    #expect(done.rateLimit == nil)
}

@Test func steeringReadsOnlyBindingCapabilities() throws {
    func detail(_ raw: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) }
    #expect(SteeringCapability.from(conversationDetail: try detail(#"{"active_binding":{"capabilities":{"steering":true}}}"#)) == true)
    #expect(SteeringCapability.from(conversationDetail: try detail(#"{"active_binding":{"capabilities":{"steering":false,"delivery_channel":"queue"}}}"#)) == false)
    #expect(SteeringCapability.from(conversationDetail: try detail(#"{"active_binding":null}"#)) == false)
    #expect(SteeringCapability.from(conversationDetail: nil) == nil)
}
