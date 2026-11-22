import XCTest
@testable import CompanionCore

final class HandoffSideChatTests: XCTestCase {
    private func json(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    func testProviderInstancesAndFilter() throws {
        let all = parseProviderInstances(try json("""
        [{"instanceId":"work","agentId":"claude_code","displayName":"Work","isDefault":true},
         {"instance_id":"p","agent_id":"codex","display_name":"P"},{"agentId":"x"}]
        """))
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(instancesForAgent(all, agentID: "claude-code").map(\.instanceID), ["work"])
        XCTAssertTrue(all[0].isDefault)
        XCTAssertFalse(all[1].isDefault)
    }

    func testPreview() throws {
        let p = parseEngineHandoffPreview(try json("""
        {"sourceEngine":"codex","targetEngine":"claude_code","packedMessages":[{},{}],
         "omittedIds":["c"],"totalTokens":120,"tokenBudget":8000,"handoffPromptText":"hi"}
        """))
        XCTAssertEqual(p?.packedCount, 2)
        XCTAssertEqual(p?.omittedCount, 1)
        XCTAssertEqual(p?.tokenBudget, 8000)
        XCTAssertEqual(p?.promptText, "hi")
        XCTAssertNil(parseEngineHandoffPreview(.null))
    }

    func testHandoffArgs() {
        let a = handoffArgs(conversationID: "c1", targetEngine: "codex", targetProviderInstanceID: " ", tokenBudget: nil)
        XCTAssertEqual(Set(a.keys), ["conversationId", "targetEngine"])
        let b = handoffArgs(conversationID: "c1", targetEngine: "codex", targetProviderInstanceID: "work", tokenBudget: 100)
        XCTAssertEqual(b["targetProviderInstanceId"] as? String, "work")
        XCTAssertEqual(b["tokenBudget"] as? Int, 100)
    }

    func testSideChatReplyDoneFallback() throws {
        let r = parseSideChatReply(try json(#"{"content":"ok","toolCalls":[{"id":"t","name":"Read","status":"completed","summary":"s"}],"events":[]}"#))
        XCTAssertEqual(r?.content, "ok")
        XCTAssertEqual(r?.toolCalls.first?.name, "Read")
        let f = parseSideChatReply(try json(#"{"events":[{"type":"delta"},{"type":"done","content":"final"}]}"#))
        XCTAssertEqual(f?.content, "final")
        XCTAssertNil(parseSideChatReply(try json(#"{"events":[]}"#)))
    }

    func testContextKeepsLastSixClipped() {
        var items: [TimelineItem] = []
        for i in 1...8 {
            items.append(TimelineItem(id: "u\(i)", role: .user, text: "q\(i)"))
            items.append(TimelineItem(id: "a\(i)", role: .assistant, text: String(repeating: "x", count: 700)))
        }
        let ctx = buildSideChatContext(items)
        XCTAssertEqual(ctx.count, 6)
        XCTAssertEqual(ctx.first?.turnNumber, 1)
        XCTAssertEqual(ctx.first?.userText, "q3")
        XCTAssertEqual(ctx.first?.assistantText.count, 601)
    }

    func testSideChatArgsDropErrorsFromHistory() {
        let args = sideChatArgs(
            conversationID: "c", sideChatID: "s", prompt: "p", contextTurns: [],
            history: [SideChatMessage(id: "1", role: "user", content: "a"),
                      SideChatMessage(id: "2", role: "assistant", content: "boom", isError: true)]
        )
        XCTAssertEqual((args["history"] as? [[String: String]])?.count, 1)
    }
}
