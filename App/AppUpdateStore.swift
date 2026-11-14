import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

struct MobileReleaseNotice: Codable, Equatable, Sendable {
    var id: String
    var platform: String
    var version: String
    var buildNumber: Int
    var changelog: String
    var forceUpdate: Bool
    var publishedAt: String
    var testFlightUrl: String?

    var releaseKey: String {
        "\(version)_\(buildNumber)"
    }
}

private struct MobileReleaseCheckResponse: Codable, Sendable {
    var release: MobileReleaseNotice?
    var hasUpdate: Bool
}

@Observable
@MainActor
final class AppUpdateStore {
    var checking = false
    var hasUpdate = false
    var latestRelease: MobileReleaseNotice?
    var isSheetPresented = false
    var manualStatusMessage: String?

    private let defaults: UserDefaults
    private var lastAutoCheckAt: Date?

    private static let dismissedReleaseKey = "vibex.ios.update.dismissed_key"
    private static let notifiedReleaseKey = "vibex.ios.update.notified_key"
    private static let autoCheckInterval: TimeInterval = 10 * 60
    private static let appStoreTestFlightFallback = "https://apps.apple.com/app/testflight/id899247664"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.4.6"
    }

    var currentBuild: Int {
        let raw = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "5"
        return Int(raw) ?? 5
    }

    func checkIfDue() {
        if let last = lastAutoCheckAt, Date().timeIntervalSince(last) < Self.autoCheckInterval {
            return
        }
        lastAutoCheckAt = Date()
        Task {
            await checkForUpdate(manual: false)
        }
    }

    func checkForUpdate(manual: Bool) async {
        guard !checking else { return }
        checking = true
        if manual {
            manualStatusMessage = nil
        }
        defer { checking = false }

        guard var components = URLComponents(string: "\(VibeXAccountStore.siteBaseURL)/api/mobile/releases/latest") else {
            return
        }
        components.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "version", value: currentVersion),
            URLQueryItem(name: "build", value: String(currentBuild)),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if manual {
                    manualStatusMessage = "检查更新失败，请稍后重试"
                }
                return
            }
            let decoded = try JSONDecoder().decode(MobileReleaseCheckResponse.self, from: data)
            if let release = decoded.release, decoded.hasUpdate, isLocalOutdated(against: release) {
                latestRelease = release
                hasUpdate = true
                let dismissed = defaults.string(forKey: Self.dismissedReleaseKey) ?? ""
                if manual || release.forceUpdate || dismissed != release.releaseKey {
                    isSheetPresented = true
                }
                await postSystemNotificationIfNeeded(for: release)
            } else {
                latestRelease = decoded.release
                hasUpdate = false
                isSheetPresented = false
                if manual {
                    manualStatusMessage = "当前已是最新版本 v\(currentVersion)"
                }
            }
        } catch {
            if manual {
                manualStatusMessage = "网络连接异常，暂时无法检查更新"
            }
        }
    }

    func dismissSheet() {
        guard let release = latestRelease else {
            isSheetPresented = false
            return
        }
        guard !release.forceUpdate else { return }
        defaults.set(release.releaseKey, forKey: Self.dismissedReleaseKey)
        isSheetPresented = false
    }

    func openTestFlight() {
        #if canImport(UIKit)
        let configured = latestRelease?.testFlightUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty, configured.lowercased().hasPrefix("https://"), let url = URL(string: configured) {
            UIApplication.shared.open(url)
            return
        }
        if let betaURL = URL(string: "itms-beta://") {
            UIApplication.shared.open(betaURL, options: [:]) { success in
                if !success, let fallback = URL(string: Self.appStoreTestFlightFallback) {
                    UIApplication.shared.open(fallback)
                }
            }
        }
        #endif
    }

    private func isLocalOutdated(against release: MobileReleaseNotice) -> Bool {
        if release.buildNumber != currentBuild {
            return release.buildNumber > currentBuild
        }
        return Self.compareSemver(release.version, currentVersion) > 0
    }

    private static func compareSemver(_ a: String, _ b: String) -> Int {
        let cleanA = a.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-").first.map(String.init) ?? ""
        let cleanB = b.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-").first.map(String.init) ?? ""
        let pa = cleanA.split(separator: ".").map { Int($0) ?? 0 }
        let pb = cleanB.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(pa.count, pb.count, 3)
        for idx in 0..<count {
            let da = idx < pa.count ? pa[idx] : 0
            let db = idx < pb.count ? pb[idx] : 0
            if da != db { return da > db ? 1 : -1 }
        }
        return 0
    }

    private func postSystemNotificationIfNeeded(for release: MobileReleaseNotice) async {
        #if canImport(UserNotifications)
        let already = defaults.string(forKey: Self.notifiedReleaseKey) ?? ""
        guard already != release.releaseKey else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let refreshed = await center.notificationSettings()
        guard refreshed.authorizationStatus == .authorized || refreshed.authorizationStatus == .provisional else {
            return
        }

        defaults.set(release.releaseKey, forKey: Self.notifiedReleaseKey)

        let content = UNMutableNotificationContent()
        content.title = "发现 VibeX 新版本 v\(release.version)"
        let lines = release.changelog
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        content.body = lines.prefix(2).joined(separator: "；").isEmpty
            ? "前往 TestFlight 即可更新体验最新功能"
            : lines.prefix(2).joined(separator: "\n")
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "vibex.ios.release.\(release.releaseKey)",
            content: content,
            trigger: nil
        )
        try? await center.add(req)
        #endif
    }
}

struct AppUpdateSheet: View {
    @Environment(AppUpdateStore.self) private var updates
    let release: MobileReleaseNotice

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 48, height: 48)
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("发现新版本")
                                .font(.headline.weight(.bold))
                            Text("v\(release.version)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("当前版本 v\(updates.currentVersion) (#\(updates.currentBuild)) → Build #\(release.buildNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("更新日志")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(release.changelog.isEmpty ? "• 性能优化与细节体验改进" : release.changelog)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(4)
                    }
                    .frame(minHeight: 100, maxHeight: 240)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }

                VStack(spacing: 10) {
                    Button {
                        updates.openTestFlight()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text("前往 TestFlight 更新")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    if !release.forceUpdate {
                        Button {
                            updates.dismissSheet()
                        } label: {
                            Text("稍后提醒")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .background(Color(.systemGroupedBackground))
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(release.forceUpdate ? .hidden : .visible)
            .interactiveDismissDisabled(release.forceUpdate)
        }
    }
}
