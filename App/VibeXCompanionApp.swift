import SwiftUI

@main
struct VibeXCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var servers = ServerStore()
    @State private var appearance = AppAppearanceStore()
    @State private var account = VibeXAccountStore()
    @State private var connectFlow = DesktopConnectFlow()
    @State private var appUpdates = AppUpdateStore()

    private var showsLogin: Bool {
        !account.isSignedIn && (servers.profiles.isEmpty || account.requiresLogin)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsLogin {
                    LoginView()
                } else {
                    RootTabView()
                }
            }
            .environment(servers)
            .environment(appearance)
            .environment(account)
            .environment(connectFlow)
            .environment(appUpdates)
            .task {
                account.attach(serverStore: servers)
                appUpdates.checkIfDue()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appUpdates.checkIfDue()
                }
            }
            .onChange(of: account.completedSignIns) { _, _ in
                connectFlow.autoConnectOnSignIn(servers: servers, account: account)
            }
            .onChange(of: account.desktops.count) { _, count in
                if count == 1 {
                    connectFlow.autoConnectInitialIfNeeded(servers: servers, account: account)
                }
            }
            .onChange(of: servers.connectionSuccessCount) { _, _ in
                account.waiveLoginRequirement()
            }
            .sheet(isPresented: $connectFlow.isPickerPresented, onDismiss: connectFlow.pickerDismissed) {
                DesktopPickerSheet()
                    .environment(servers)
                    .environment(account)
                    .environment(connectFlow)
            }
            .sheet(isPresented: $connectFlow.isCodePairingPresented) {
                PairView()
                    .environment(servers)
            }
            .sheet(isPresented: $appUpdates.isSheetPresented) {
                if let release = appUpdates.latestRelease {
                    AppUpdateSheet(release: release)
                        .environment(appUpdates)
                }
            }
            .alert(
                "局域网已断开，是否切换至云服务？",
                isPresented: Binding(
                    get: { servers.pendingCloudFallback != nil && !servers.isPresentingPairSheet },
                    set: { if !$0 { servers.declineSwitchToCloudFallback() } }
                ),
                presenting: servers.pendingCloudFallback
            ) { _ in
                Button("切换至云服务") {
                    servers.confirmSwitchToCloudFallback()
                }
                Button("保持局域网", role: .cancel) {
                    servers.declineSwitchToCloudFallback()
                }
            } message: { prompt in
                Text("当前与电脑「\(prompt.hostName)」的局域网直连已断开，但检测到可通过「VibeX 云服务 · Beta」继续连接。是否切换至云服务？")
            }
        }
    }
}
