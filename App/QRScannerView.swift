import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import Vision

struct QRScannerView: View {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void
    var onManualInputTap: (() -> Void)? = nil

    @State private var selectedZoom: CGFloat = 1.5
    @State private var torchOn = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoErrorMessage: String?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            // Frosted Card Viewfinder (matching t3-style squircle scanner)
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 22) {
                    QRScannerCameraRepresentable(
                        zoomFactor: $selectedZoom,
                        torchOn: $torchOn,
                        onCode: { code in
                            let generator = UINotificationFeedbackGenerator()
                            generator.notificationOccurred(.success)
                            onCode(code)
                        },
                        onFailure: onFailure
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
                        .padding(.horizontal, 20)

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
                .padding(.vertical, 32)
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
                .padding(.horizontal, 16)

                Spacer()

                // Bottom Quick Actions Bar
                HStack(spacing: 16) {
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

                    if let onManualInputTap {
                        Button {
                            onManualInputTap()
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
                    }

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
                }
                .padding(.bottom, 28)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let item = newValue else { return }
            photoErrorMessage = nil
            Task {
                await detectQRCode(from: item)
            }
        }
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
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            onCode(detected)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            photoErrorMessage = "未在图片中识别到二维码"
        }
    }
}

private struct ScannerCornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let len: CGFloat = 28
        let r: CGFloat = 24

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len + r / 2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + len + r / 2, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - len - r / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len + r / 2))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len - r / 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - len - r / 2, y: rect.maxY))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + len + r / 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len - r / 2))

        return path
    }
}

struct QRScannerCameraRepresentable: UIViewControllerRepresentable {
    @Binding var zoomFactor: CGFloat
    @Binding var torchOn: Bool
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        controller.onZoomChanged = { newZoom in
            DispatchQueue.main.async {
                zoomFactor = newZoom
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.applyUserZoom(zoomFactor)
        controller.applyTorch(torchOn)
    }
}

final class ScannerController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.vibex.qrscanner.session", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.vibex.qrscanner.vision", qos: .userInitiated)
    private var captureDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var baseZoomFactor: CGFloat = 1.0
    private var currentRelativeZoom: CGFloat = 1.5
    private var pinchStartZoom: CGFloat = 1.5
    private var delivered = false
    private var lastVisionSampleTime: CFTimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    granted ? self.configure() : self.onFailure?("需要相机权限才能扫码")
                }
            }
        default:
            onFailure?("需要相机权限才能扫码，请在系统设置中允许")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private static func bestBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
            ],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func configure() {
        guard let device = Self.bestBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            onFailure?("此设备无法使用相机")
            return
        }
        captureDevice = device

        // On multi-camera iPhones (Triple/DualWide), virtualDeviceSwitchOverVideoZoomFactors.first
        // represents the main 1x wide camera (while 1.0 is the 0.5x ultra-wide macro camera).
        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1.0
        baseZoomFactor = CGFloat(max(1.0, switchOver))

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            let metadataOutput = AVCaptureMetadataOutput()
            if self.session.canAddOutput(metadataOutput) {
                self.session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                    metadataOutput.metadataObjectTypes = [.qr]
                }
            }

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(videoOutput) {
                self.session.addOutput(videoOutput)
                videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
            }

            self.session.commitConfiguration()
            self.configureCameraFocusAndZoom(device: device, relativeZoom: self.currentRelativeZoom, animated: false)
            self.session.startRunning()
        }
    }

    private func configureCameraFocusAndZoom(device: AVCaptureDevice, relativeZoom: CGFloat, animated: Bool) {
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }

            let targetDeviceZoom = min(
                max(device.minAvailableVideoZoomFactor, baseZoomFactor * relativeZoom),
                min(device.maxAvailableVideoZoomFactor, baseZoomFactor * 4.0)
            )
            if animated {
                device.ramp(toVideoZoomFactor: targetDeviceZoom, withRate: 8.0)
            } else {
                device.videoZoomFactor = targetDeviceZoom
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func applyUserZoom(_ relativeZoom: CGFloat) {
        let clamped = min(max(1.0, relativeZoom), 4.0)
        guard abs(clamped - currentRelativeZoom) > 0.05, let device = captureDevice else { return }
        currentRelativeZoom = clamped
        sessionQueue.async { [weak self] in
            self?.configureCameraFocusAndZoom(device: device, relativeZoom: clamped, animated: true)
        }
    }

    func applyTorch(_ on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let targetMode: AVCaptureDevice.TorchMode = on ? .on : .off
                if device.torchMode != targetMode, device.isTorchModeSupported(targetMode) {
                    device.torchMode = targetMode
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let device = captureDevice else { return }
        switch gesture.state {
        case .began:
            pinchStartZoom = currentRelativeZoom
        case .changed:
            let next = min(max(1.0, pinchStartZoom * gesture.scale), 4.0)
            currentRelativeZoom = next
            onZoomChanged?(next)
            sessionQueue.async { [weak self] in
                self?.configureCameraFocusAndZoom(device: device, relativeZoom: next, animated: false)
            }
        default:
            break
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let previewLayer, let device = captureDevice else { return }
        let location = gesture.location(in: view)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func deliverCodeOnMain(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.delivered else { return }
            self.delivered = true
            self.sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
            self.onCode?(trimmed)
        }
    }

    // Engine 1: Hardware Metadata Decoder
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let codeObject = objects.first as? AVMetadataMachineReadableCodeObject,
              let text = codeObject.stringValue,
              !text.isEmpty
        else { return }
        deliverCodeOnMain(text)
    }

    // Engine 2: Vision Framework VNDetectBarcodesRequest (excels on angled/glare LCD/OLED screens)
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !delivered else { return }
        let now = CACurrentMediaTime()
        guard now - lastVisionSampleTime >= 0.12 else { return }
        lastVisionSampleTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest { [weak self] req, _ in
            guard let self, !self.delivered,
                  let results = req.results as? [VNBarcodeObservation]
            else { return }

            if let match = results.first(where: { ($0.payloadStringValue?.isEmpty == false) }),
               let payload = match.payloadStringValue
            {
                self.deliverCodeOnMain(payload)
            } else if let candidate = results.first,
                      candidate.boundingBox.width > 0.01,
                      candidate.boundingBox.width < 0.18,
                      let device = self.captureDevice
            {
                // Auto-zoom in when a distant/small QR code is detected but too small to decode
                let boosted = min(self.currentRelativeZoom * 1.35, 3.0)
                if boosted > self.currentRelativeZoom + 0.15 {
                    self.currentRelativeZoom = boosted
                    self.onZoomChanged?(boosted)
                    self.configureCameraFocusAndZoom(device: device, relativeZoom: boosted, animated: true)
                }
            }
        }
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
    }
}
