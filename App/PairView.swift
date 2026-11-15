import CompanionCore
import PhotosUI
import SwiftUI
import UIKit
import Vision

struct PairView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss

    var startWithScanner: Bool = true
    var initialOrigin: String? = nil

    @State private var showingScanner: Bool

    init(startWithScanner: Bool = true, initialOrigin: String? = nil) {
        self.startWithScanner = startWithScanner
        self.initialOrigin = initialOrigin
        _showingScanner = State(initialValue: startWithScanner)
    }

    var body: some View {
        NavigationStack {
            PairingCodeForm(
                showingScanner: $showingScanner,
                initialOrigin: initialOrigin,
                onPaired: { dismiss() }
            )
            .navigationTitle(showingScanner ? "扫码配对" : "使用连接码配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { servers.isPresentingPairSheet = true }
            .onDisappear { servers.isPresentingPairSheet = false }
        }
    }
}

/// Unified single-page pairing view: squircle QR scanner at top with inline toggle to hide the
/// viewfinder and enter a connection code on the same page.
struct PairingCodeForm: View {
    @Environment(ServerStore.self) private var servers
    @Binding var showingScanner: Bool
    var initialOrigin: String? = nil
    var onPaired: () -> Void

    @State private var quickCode = ""
    @State private var submittingCode = false
    @State private var awaitingLanSas: (hostName: String, sasCode: String)?
    @State private var connectingLanHostId: String?
    @State private var lanConnectTask: Task<Void, Never>?
    @State private var localError: String?
    @State private var localMobileConflict: PendingMobileConflict?
    @State private var didAppear = false

    @State private var selectedZoom: CGFloat = 1.5
    @State private var torchOn = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoErrorMessage: String?
    @State private var pendingCloudNodeChoiceInput: String?

    private var lanHosts: [DiscoveredLanHost] {
        servers.discoveredHosts.filter { !$0.isCloudService }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    if showingScanner {
                        scannerCard
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        Spacer(minLength: 12)

                        if let awaiting = awaitingLanSas {
                            lanSasComparisonCard(hostName: awaiting.hostName, sasCode: awaiting.sasCode)
                        } else if !lanHosts.isEmpty {
                            discoveredLanCard
                        }

                        inlineCodeCard
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let errorText = localError, !errorText.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.08))
                        )
                    }
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)

            bottomActionBar
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let item = newValue else { return }
            photoErrorMessage = nil
            Task {
                await detectQRCode(from: item)
            }
        }
        .confirmationDialog(
            "选择连接节点",
            isPresented: Binding(
                get: { pendingCloudNodeChoiceInput != nil },
                set: { if !$0 { pendingCloudNodeChoiceInput = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingInput = pendingCloudNodeChoiceInput {
                Button("官方云服务") {
                    pendingCloudNodeChoiceInput = nil
                    executePair(input: pendingInput, cloudPreference: .official)
                }
                Button("自建云节点") {
                    let customOrigin = servers.customRelayOrigin
                    pendingCloudNodeChoiceInput = nil
                    executePair(input: pendingInput, cloudPreference: .custom(customOrigin))
                }
            }
            Button("取消", role: .cancel) {
                pendingCloudNodeChoiceInput = nil
            }
        } message: {
            Text("检测到你已配置自建云节点，请选择本次配对使用的云节点")
        }
        .alert(
            "选择要远程连接的手机",
            isPresented: Binding(
                get: { localMobileConflict != nil },
                set: { if !$0 { localMobileConflict = nil } }
            ),
            presenting: localMobileConflict
        ) { conflict in
            Button("使用「\(conflict.currentDeviceName)」（本机）", role: .destructive) {
                let action = conflict.retryAction
                localMobileConflict = nil
                Task { @MainActor in
                    await action()
                }
            }
            Button("保留「\(conflict.existingDeviceName)」", role: .cancel) {
                localMobileConflict = nil
            }
        } message: { conflict in
            Text("同一台电脑仅限一台手机远程连接。当前电脑已连接「\(conflict.existingDeviceName)」，若切换为本机连接，「\(conflict.existingDeviceName)」将被强制下线并清除凭据，下次需重新连接。")
        }
        .onChange(of: servers.connectionSuccessCount) { _, _ in
            onPaired()
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            servers.discoverHosts()
        }
        .onDisappear {
            torchOn = false
            lanConnectTask?.cancel()
            lanConnectTask = nil
        }
    }

    private var scannerCard: some View {
        VStack(spacing: 20) {
            QRScannerCameraRepresentable(
                zoomFactor: $selectedZoom,
                torchOn: $torchOn,
                onCode: { code in
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    quickCode = cleaned
                    torchOn = false
                    submitQuickCode(overrideInput: cleaned)
                },
                onFailure: { message in
                    localError = message
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showingScanner = false
                    }
                }
            )
            .frame(width: 248, height: 248)
            .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.82), lineWidth: 1.8)
            )
            .shadow(color: .black.opacity(0.14), radius: 16, y: 6)

            Text("请扫描桌面端「远程连接」中的配对二维码")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            // Zoom Pills (1x / 1.5x / 2.5x)
            HStack(spacing: 10) {
                ForEach([1.0, 1.5, 2.5], id: \.self) { factor in
                    let isSelected = abs(selectedZoom - factor) < 0.2
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedZoom = factor
                    } label: {
                        Text(factor == 1.0 ? "1x" : String(format: "%.1fx", factor))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
                            .frame(width: 44, height: 30)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.primary : Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let photoErrorMessage {
                Text(photoErrorMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.88)))
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private var bottomActionBar: some View {
        HStack(spacing: 16) {
            if showingScanner {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color(.secondarySystemGroupedBackground))
                                .frame(width: 50, height: 50)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        Text("相册")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    torchOn = false
                    photoErrorMessage = nil
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showingScanner = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 16, weight: .semibold))
                        Text("使用连接码配对")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    torchOn.toggle()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(torchOn ? Color.yellow : Color(.secondarySystemGroupedBackground))
                                .frame(width: 50, height: 50)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
                            Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(torchOn ? .black : .primary)
                        }
                        Text("手电筒")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    localError = nil
                    photoErrorMessage = nil
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showingScanner = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                        Text("扫码配对")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 22)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    @MainActor
    private func detectQRCode(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let cgImage = image.cgImage
        else {
            photoErrorMessage = "无法读取所选图片"
            return
        }

        let detected = await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            return request.results?.compactMap(\.payloadStringValue).first(where: { !$0.isEmpty })
        }.value

        if let detected {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let cleaned = detected.trimmingCharacters(in: .whitespacesAndNewlines)
            quickCode = cleaned
            torchOn = false
            submitQuickCode(overrideInput: cleaned)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            photoErrorMessage = "未在图片中识别到二维码"
        }
    }

    private var discoveredLanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前 Wi-Fi 发现电脑（免输码，对比连接码即连）")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(lanHosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    let isBusy = connectingLanHostId == host.id
                    Button {
                        connectLanHost(host)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Text(host.displayName)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            if isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("连接")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.accentColor)
                                    )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(connectingLanHostId != nil || submittingCode)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                    )
            )
        }
    }

    private func lanSasComparisonCard(hostName: String, sasCode: String) -> some View {
        VStack(spacing: 10) {
            Text("连接「\(hostName)」")
                .font(.system(size: 15, weight: .semibold))
            Text("对比电脑顶部显示的连接码一致后，点击「连接」")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(sasCode)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .kerning(3)
                .foregroundStyle(Color.accentColor)
            Button("取消等待") {
                lanConnectTask?.cancel()
                lanConnectTask = nil
                connectingLanHostId = nil
                awaitingLanSas = nil
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private func connectLanHost(_ host: DiscoveredLanHost, replaceExistingMobile: Bool = false) {
        localError = nil
        connectingLanHostId = host.id
        lanConnectTask?.cancel()
        lanConnectTask = Task { @MainActor in
            defer {
                connectingLanHostId = nil
                awaitingLanSas = nil
            }
            do {
                try await servers.connectViaAccountRequest(
                    origin: host.origin,
                    hostId: host.hostId.map(AccountDesktop.rawHostId) ?? "",
                    hostName: host.displayName,
                    deviceName: UIDevice.current.name,
                    accountToken: servers.accountStore?.token,
                    replaceExistingMobile: replaceExistingMobile,
                    onAwaitingApproval: { sasCode in
                        self.awaitingLanSas = (hostName: host.displayName, sasCode: sasCode)
                    }
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
                return
            } catch let PairingError.mobileDeviceConflict(existingName) {
                localMobileConflict = PendingMobileConflict(
                    existingDeviceName: existingName,
                    currentDeviceName: UIDevice.current.name
                ) {
                    connectLanHost(host, replaceExistingMobile: true)
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                localError = ServerStore.sanitizeError(error)
            }
        }
    }

    private var inlineCodeCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("输入 8 位连接码或粘贴邀请", text: $quickCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                        .submitLabel(.go)
                        .onSubmit {
                            submitQuickCode()
                        }

                    if !quickCode.isEmpty {
                        Button {
                            quickCode = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(.systemGroupedBackground))
                )

                if quickCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        pasteAndPairIfInvitation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .semibold))
                            Text("粘贴")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        submitQuickCode()
                    } label: {
                        if submittingCode {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        } else {
                            Text("连接")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .buttonStyle(.plain)
                    .disabled(submittingCode)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private func pasteAndPairIfInvitation() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
        !pasted.isEmpty
        else { return }
        quickCode = pasted
        localError = nil
        if PairingInvitation.looksLikeInvitation(pasted) {
            submitQuickCode(overrideInput: pasted)
        }
    }

    private func submitQuickCode(overrideInput: String? = nil) {
        let input = (overrideInput ?? quickCode).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !submittingCode else { return }
        if servers.hasCustomRelayNode && servers.accountStore?.canUseCloudRelay == true {
            pendingCloudNodeChoiceInput = input
            return
        }
        executePair(input: input, cloudPreference: .auto)
    }

    private func executePair(input: String, cloudPreference: CloudNodePreference) {
        guard !input.isEmpty, !submittingCode else { return }
        submittingCode = true
        localError = nil
        servers.pairingError = nil
        Task { @MainActor in
            do {
                try await servers.pair(
                    input: input,
                    manualOrigin: initialOrigin ?? "",
                    deviceName: UIDevice.current.name,
                    cloudPreference: cloudPreference,
                    onConflict: { conflict in
                        localMobileConflict = conflict
                    }
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                submittingCode = false
            } catch PairingError.mobileDeviceConflict {
                submittingCode = false
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                localError = ServerStore.sanitizeError(error)
                submittingCode = false
            }
        }
    }
}
