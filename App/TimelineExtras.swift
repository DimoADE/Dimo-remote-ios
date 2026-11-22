import CompanionCore
import SwiftUI

/// Divider row for cross-engine handoff / fork (`agent_handoff` host note).
struct HandoffDividerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            line
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
    }
}

/// Rate-limit recovery banner; actions map to the Host's auto-resume / cancel-wait commands.
struct RateLimitRecoveryBanner: View {
    let banner: RateLimitBanner
    let engine: String
    let writable: Bool
    let autoResume: () -> Void
    let cancelWait: () -> Void

    private var recovery: String {
        if let reset = banner.resetAtMs {
            let date = Date(timeIntervalSince1970: Double(reset) / 1000)
            return "预计 \(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())) 后额度恢复"
        }
        if let retry = banner.retryAfterSeconds { return "约 \(retry) 秒后可重试" }
        return "恢复时间未知"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(engine) 已触发限流", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(recovery)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if writable {
                HStack(spacing: 8) {
                    Button("恢复后自动继续", action: autoResume)
                    Button("取消等待", role: .cancel, action: cancelWait)
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// One-line honest steering hint shown above the composer while a turn is in flight.
struct SteeringHint: View {
    /// nil while the Host has not reported the binding's capability.
    let supported: Bool?

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 2)
    }

    private var text: String {
        switch supported {
        case nil: "正在确认 Agent 是否支持回合纠偏…"
        case true?: "该 Agent 支持回合纠偏：发送的消息会直接引导当前回合"
        case false?: "该 Agent 不支持回合纠偏：消息将排队，待当前回合结束后发送"
        }
    }
}
