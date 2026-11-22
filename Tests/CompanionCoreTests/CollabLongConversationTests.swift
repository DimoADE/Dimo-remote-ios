import Foundation
import Testing
@testable import CompanionCore

private final class CollabRecordingTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var recordedInputs: [[String: Any]] = []
    var nextReplyJSON: String

    init(replyJSON: String = "{\"operation_id\":\"o\",\"data\":{\"messages\":[],\"scheduled\":[],\"cards\":[]}}") {
        self.nextReplyJSON = replyJSON
    }

    func execute(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> HttpExchange {
        let reply = lock.withLock { () -> String in
            if let body,
               let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let args = root["args"] as? [String: Any],
               let input = args["input"] as? [String: Any]
            {
                recordedInputs.append(input)
            }
            return nextReplyJSON
        }
        return HttpExchange(status: 200, body: Data(reply.utf8))
    }
}

@Test func collabMessagesSendsPaginationArgumentsAndDecodesPageMetadata() async throws {
    let pageReply = """
    {"operation_id":"o","data":{
      "messages":[
        {"id":"m-10","seq":10,"origin":"user","envelope":{"id":"m-10","sender":"Person","content":"hello"}},
        {"id":"m-11","seq":11,"origin":"agent","envelope":{"id":"m-11","sender":"架构师","content":"world"}}
      ],
      "scheduled":[],
      "cards":[],
      "hasMoreBefore":true,
      "oldestSeq":10
    }}
    """
    let transport = CollabRecordingTransport(replyJSON: pageReply)
    let client = HostClient(
        origin: try HostOrigin.parse("http://127.0.0.1:17891"),
        accessToken: "token",
        transport: transport
    )

    // Default call: backward compatible, latest=true, limit=80
    let initialPage = try await client.collabMessages(spaceID: "space-1")
    #expect(initialPage.hasMoreBefore == true)
    #expect(initialPage.oldestSeq == 10)
    #expect(initialPage.resolvedOldestSeq == 10)
    #expect(initialPage.messages.count == 2)

    // Incremental poll: sinceSeq > 0
    _ = try await client.collabMessages(spaceID: "space-1", sinceSeq: 11, limit: 80)

    // Backward pagination: beforeSeq takes precedence
    _ = try await client.collabMessages(spaceID: "space-1", beforeSeq: 10, limit: 50)

    #expect(transport.recordedInputs.count == 3)

    let firstInput = transport.recordedInputs[0]
    #expect(firstInput["spaceId"] as? String == "space-1")
    #expect(firstInput["latest"] as? Bool == true)
    #expect(firstInput["limit"] as? Int == 80)
    #expect(firstInput["sinceSeq"] == nil)
    #expect(firstInput["beforeSeq"] == nil)

    let secondInput = transport.recordedInputs[1]
    #expect(secondInput["spaceId"] as? String == "space-1")
    #expect((secondInput["sinceSeq"] as? NSNumber)?.int64Value == 11)
    #expect(secondInput["limit"] as? Int == 80)
    #expect(secondInput["latest"] == nil)
    #expect(secondInput["beforeSeq"] == nil)

    let thirdInput = transport.recordedInputs[2]
    #expect(thirdInput["spaceId"] as? String == "space-1")
    #expect((thirdInput["beforeSeq"] as? NSNumber)?.int64Value == 10)
    #expect(thirdInput["limit"] as? Int == 50)
    #expect(thirdInput["latest"] == nil)
    #expect(thirdInput["sinceSeq"] == nil)

    // Snake_case metadata fallback + default hasMoreBefore=false when omitted
    let snakeJSON = """
    {"messages":[{"id":"m-5","seq":5,"envelope":{"sender":"Bot","content":"ok"}}],
     "has_more_before":true,
     "oldest_seq":5}
    """
    let snakePage = try JSONDecoder().decode(CollabSpaceMessagePage.self, from: Data(snakeJSON.utf8))
    #expect(snakePage.hasMoreBefore == true)
    #expect(snakePage.oldestSeq == 5)

    let legacyJSON = """
    {"messages":[{"id":"m-7","seq":7,"envelope":{"sender":"Bot","content":"legacy"}}]}
    """
    let legacyPage = try JSONDecoder().decode(CollabSpaceMessagePage.self, from: Data(legacyJSON.utf8))
    #expect(legacyPage.hasMoreBefore == false)
    #expect(legacyPage.oldestSeq == nil)
    #expect(legacyPage.resolvedOldestSeq == 7)
}

@Test func collabMessageTimelineMergesPaginationDeduplicatesAndReconcilesStreamingDrafts() throws {
    let m3 = CollabSpaceMessage(
        rawId: "vibex://space-message/m-3",
        seq: 3,
        origin: "user",
        operationId: "op-3",
        envelope: CollabMessageEnvelope(id: "m-3", sender: "Person", content: "第三条")
    )
    let draftInitial = CollabSpaceMessage(
        rawId: "draft:turn-9",
        seq: 4,
        origin: "agent",
        turnId: "turn-9",
        streaming: true,
        envelope: CollabMessageEnvelope(id: "draft:turn-9", sender: "架构师", content: "正在分析…", streaming: true)
    )

    // 1. Streaming update replaces stale draft text and stays at tail
    let draftUpdated = CollabSpaceMessage(
        rawId: "draft:turn-9",
        seq: 4,
        origin: "agent",
        turnId: "turn-9",
        streaming: true,
        envelope: CollabMessageEnvelope(id: "draft:turn-9", sender: "架构师", content: "正在分析模块边界…", streaming: true)
    )
    let afterStreamTick = CollabMessageTimeline.merge(
        existing: [m3, draftInitial],
        incoming: [draftUpdated],
        replaceStreamingFromIncoming: true
    )
    #expect(afterStreamTick.map(\.id) == ["m-3", "draft:turn-9"])
    #expect(afterStreamTick.last?.envelope.content == "正在分析模块边界…")

    // 2. Backward pagination (`replaceStreamingFromIncoming: false`) prepends older messages and keeps live tail draft
    let m1 = CollabSpaceMessage(
        rawId: "m-1",
        seq: 1,
        origin: "user",
        envelope: CollabMessageEnvelope(id: "m-1", sender: "Person", content: "第一条")
    )
    let m2 = CollabSpaceMessage(
        rawId: "m-2",
        seq: 2,
        origin: "agent",
        envelope: CollabMessageEnvelope(id: "m-2", sender: "架构师", content: "第二条")
    )
    let afterLoadEarlier = CollabMessageTimeline.merge(
        existing: afterStreamTick,
        incoming: [m2, m1],
        replaceStreamingFromIncoming: false
    )
    #expect(afterLoadEarlier.map(\.id) == ["m-1", "m-2", "m-3", "draft:turn-9"])

    // 3. Deduplication by operationId / seq + finalized reply clears disappeared streaming draft
    let m3Updated = CollabSpaceMessage(
        rawId: "m-3",
        seq: 3,
        origin: "user",
        operationId: "op-3",
        envelope: CollabMessageEnvelope(
            id: "m-3",
            sender: "Person",
            content: "第三条",
            reactions: [CollabReaction(emoji: "👍", actor: "Person")]
        )
    )
    let m4Final = CollabSpaceMessage(
        rawId: "m-4",
        seq: 4,
        origin: "agent",
        turnId: "turn-9",
        streaming: false,
        envelope: CollabMessageEnvelope(id: "m-4", sender: "架构师", content: "分析完毕：建议拆分模块。")
    )
    let afterFinalize = CollabMessageTimeline.merge(
        existing: afterLoadEarlier,
        incoming: [m3Updated, m4Final],
        replaceStreamingFromIncoming: true
    )
    #expect(afterFinalize.map(\.id) == ["m-1", "m-2", "m-3", "m-4"])
    #expect(afterFinalize[2].groupedReactions.first?.emoji == "👍")
    #expect(afterFinalize.contains(where: \.isStreamingDraft) == false)
    #expect(CollabMessageTimeline.highestConfirmedSeq(in: afterFinalize) == 4)
    #expect(CollabMessageTimeline.oldestConfirmedSeq(in: afterFinalize) == 1)
    #expect(CollabMessageTimeline.incrementalSinceSeq(in: afterFinalize) == 4)
}

private extension CollabMessageTimeline {
    static func incrementalSinceSeq(in messages: [CollabSpaceMessage]) -> Int64? {
        incrementalSinceSeq(for: messages)
    }
}

@Test func collabMessageFormatterParsesCardsHandoffsCodeBlocksAndCollapseThresholds() {
    let approvalRaw = """
    请求审批：合并 PR

    <card kind="approval" id="card-42">
    <action>
    合并 PR #42
    </action>
    <command>
    git merge --no-ff &lt;feature/long-chat&gt; &amp;&amp; git status
    </command>
    <reason>
    已完成回归测试
    </reason>
    </card>
    """
    let parsedApproval = CollabMessageFormatter.parse(approvalRaw)
    #expect(parsedApproval.cards.count == 1)
    #expect(parsedApproval.cards[0].id == "card-42")
    #expect(parsedApproval.cards[0].kind == .approval)
    #expect(parsedApproval.cards[0].action == "合并 PR #42")
    #expect(parsedApproval.cards[0].command == "git merge --no-ff <feature/long-chat> && git status")
    #expect(parsedApproval.cards[0].reason == "已完成回归测试")
    #expect(parsedApproval.shouldCollapse == false)
    let approvalPreview = CollabMessageFormatter.previewText(approvalRaw)
    #expect(!approvalPreview.contains("<card"))
    #expect(approvalPreview.contains("合并 PR #42"))

    let askAndHandoffRaw = """
    <handoff id="h-1" depth="2">
    <done>已完成协议层拆分</done>
    <inputs_constraints>不要改动 mobile/ios 以外目录</inputs_constraints>
    <ask>请继续验证 UI 折叠逻辑</ask>
    </handoff>

    <card kind="ask" id="ask-7">
    <question>目标分支选哪个？</question>
    <options>main | release/0.4.9 | dev</options>
    </card>
    """
    let parsedMixed = CollabMessageFormatter.parse(askAndHandoffRaw)
    #expect(parsedMixed.handoffs.count == 1)
    #expect(parsedMixed.handoffs[0].id == "h-1")
    #expect(parsedMixed.handoffs[0].depth == "2")
    #expect(parsedMixed.handoffs[0].done == "已完成协议层拆分")
    #expect(parsedMixed.handoffs[0].inputsConstraints == "不要改动 mobile/ios 以外目录")
    #expect(parsedMixed.handoffs[0].ask == "请继续验证 UI 折叠逻辑")
    #expect(parsedMixed.cards.count == 1)
    #expect(parsedMixed.cards[0].kind == .ask)
    #expect(parsedMixed.cards[0].question == "目标分支选哪个？")
    #expect(parsedMixed.cards[0].options == ["main", "release/0.4.9", "dev"])
    #expect(!CollabMessageFormatter.previewText(askAndHandoffRaw).contains("<handoff"))

    // Fenced code blocks split cleanly from prose and protect inner XML examples
    let markdownWithCode = """
    下面是修复方案：

    ```swift
    let merged = CollabMessageTimeline.merge(existing: old, incoming: fresh)
    // <card kind="ask" id="example"><question>not a live card</question></card>
    ```

    请确认是否合入。
    """
    let parsedCode = CollabMessageFormatter.parse(markdownWithCode)
    #expect(parsedCode.cards.isEmpty)
    #expect(parsedCode.segments.count == 3)
    if case .codeBlock(_, let lang, let code) = parsedCode.segments[1] {
        #expect(lang == "swift")
        #expect(code.contains("CollabMessageTimeline.merge"))
        #expect(code.contains("<card kind=\"ask\""))
    } else {
        Issue.record("Expected middle segment to be .codeBlock")
    }

    // Collapse threshold: > 12 lines or > 480 chars
    let shortText = (1...6).map { "第 \($0) 行简短结论" }.joined(separator: "\n")
    let parsedShort = CollabMessageFormatter.parse(shortText)
    #expect(parsedShort.lineCount == 6)
    #expect(parsedShort.shouldCollapse == false)

    let tallText = (1...16).map { "第 \($0) 行构建日志输出" }.joined(separator: "\n")
    let parsedTall = CollabMessageFormatter.parse(tallText)
    #expect(parsedTall.lineCount == 16)
    #expect(parsedTall.shouldCollapse == true)

    let wideSingleParagraph = String(repeating: "长段落内容验证", count: 80) // 560 chars
    let parsedWide = CollabMessageFormatter.parse(wideSingleParagraph)
    #expect(parsedWide.lineCount == 1)
    #expect(parsedWide.charCount == 560)
    #expect(parsedWide.shouldCollapse == true)
}
