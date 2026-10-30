import AVFoundation
import CoreImage
import ImageIO
import Vision
import UIKit
import Combine

/// 实时读数（取景框上方显示）
struct LiveReadout: Equatable {
    var aperture: String = "—"
    var shutter: String = "—"
    var iso: String = "—"
    var wb: String = "—"
    var bias: String = "—"
}

/// 预览帧缓存（视频线程写，渲染线程读）
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: CIImage?
    private var filtered: CIImage?

    func set(raw: CIImage, filtered: CIImage) {
        lock.lock(); self.raw = raw; self.filtered = filtered; lock.unlock()
    }

    func latest(original: Bool) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return original ? raw : filtered
    }
}

/// 相机核心：会话、镜头、iOS 27 曝光控制、白平衡、Camera Control、拍照
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: 发布给界面（主线程）
    @Published var lens: LensChoice = .wide
    @Published var availableLenses: Set<LensChoice> = []
    @Published var capabilities = HardwareCapabilities.empty
    @Published var liveHistogram = [Double](repeating: 0, count: 32)
    @Published var matchScore: Double?
    @Published var readout = LiveReadout()
    @Published var lastPhoto: UIImage?
    @Published var statusMessage: String?
    @Published var captureFlash = 0
    @Published var isSaving = false
    @Published var autoMatchStatus: String?
    @Published var captureIsLandscape = false
    @Published var captureRotationAngle: CGFloat = 90   // 照片相对传感器的旋转角（90 = 竖拍）
    @Published var compositionHint: String?
    @Published var compositionAligned = false
    @Published var isReady = false
    @Published var videoMode = false
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var proRAWSupported = false
    @Published var proRAWEnabled = false

    /// Camera Control 实体键改动后的回调（主线程）
    var onStrengthFromControl: ((Double) -> Void)?
    var onApertureFromControl: ((Float) -> Void)?

    let session = AVCaptureSession()
    let renderer = StyleRenderer()
    let frameStore = FrameStore()

    private let sessionQueue = DispatchQueue(label: "stylecam.session")
    private let videoQueue = DispatchQueue(label: "stylecam.video", qos: .userInteractive)
    private let controlsQueue = DispatchQueue(label: "stylecam.controls")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    // 视频录制（只在 videoQueue 上使用）
    private var recorder: VideoRecorder?
    private var wantRecording = false
    private lazy var videoContext = CIContext(options: [.cacheIntermediates: false])
    private var recordTimer: Timer?
    // 拍照：一次拍摄可能先后收到 RAW 和处理后的照片，等 didFinishCapture 再统一处理
    private var pendingProcessed: [Int64: (Data, [String: Any])] = [:]
    private var pendingRaw: [Int64: Data] = [:]
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var sessionLens: LensChoice = .wide
    private var plan = CapturePlan()
    private var configured = false

    // 跨线程开关
    private let stateLock = NSLock()
    private var _refHistogram: [Double]?
    private var _refMedianL: Double?
    private var _refChroma: Double?
    private var _refCast: SIMD2<Double>?
    private var _refStats: SceneStats?
    private var _autoMatch = false
    private var _wbFollow = true
    private var _saveOriginal = false
    private var _use48MP = false
    private var _planSummary = ""
    private var _preferPerson = true
    private var _variant: StyleVariant = .faithful
    private var _matchAspect = false
    private var _effects = EffectToggles()
    private var _refFace: CGRect?
    private var _refMagnification: Double?
    private var _captureAngle: Int = 90

    // 实时分割（只在 videoQueue 上使用）
    private var livePerson: CIImage?
    private var liveSubject: CIImage?
    private lazy var personSeg: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    private func locked<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }

    private var frameCount = 0
    private var lastAutoMatch = Date.distantPast
    private var lastColorMatch = Date.distantPast
    private var wbTimer: DispatchSourceTimer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private lazy var histContext = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 启动

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.statusMessage = "请在“设置”中允许相机权限" }
                return
            }
            self.sessionQueue.async {
                if !self.configured { self.configureSession() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()
        let rawOK = photoOutput.isAppleProRAWSupported
        DispatchQueue.main.async { self.proRAWSupported = rawOK }

        let avail = Set(LensChoice.allCases.filter {
            AVCaptureDevice.default($0.deviceType, for: .video, position: .back) != nil
        })
        DispatchQueue.main.async { self.availableLenses = avail }

        setLens(.wide)
        configured = true
        DispatchQueue.main.async { self.isReady = true }
    }

    // MARK: - 镜头切换

    func switchLens(_ lens: LensChoice, completion: (() -> Void)? = nil) {
        sessionQueue.async {
            self.setLens(lens)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private func setLens(_ lens: LensChoice) {
        guard let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            DispatchQueue.main.async { self.statusMessage = "找不到后置相机" }
            return
        }

        if device?.uniqueID != dev.uniqueID {
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            do {
                let newInput = try AVCaptureDeviceInput(device: dev)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    input = newInput
                    device = dev
                }
            } catch {
                DispatchQueue.main.async { self.statusMessage = "镜头切换失败：\(error.localizedDescription)" }
            }
            // 取景帧固定竖屏；照片方向跟随手机姿态（横拍得到横幅照片）
            for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
                if let c = conn, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelCapture
                self?.sessionQueue.async { self?.setPhotoRotation(angle) }
            }
            if let biggest = dev.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                photoOutput.maxPhotoDimensions = biggest
            }
            session.commitConfiguration()
        }

        if let d = device {
            if (try? d.lockForConfiguration()) != nil {
                d.videoZoomFactor = min(lens.zoomFactor, d.activeFormat.videoMaxZoomFactor)
                d.unlockForConfiguration()
            }
        }
        sessionLens = lens
        let caps = device.map(Self.readCapabilities) ?? .empty
        if let d = device { setupCameraControls(device: d, caps: caps) }
        DispatchQueue.main.async {
            self.lens = lens
            self.capabilities = caps
        }
    }

    private func setPhotoRotation(_ angle: CGFloat) {
        if let c = photoOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
        let landscape = angle == 0 || angle == 180
        locked { _captureAngle = Int(angle.rounded()) }
        DispatchQueue.main.async {
            if self.captureIsLandscape != landscape { self.captureIsLandscape = landscape }
            if self.captureRotationAngle != angle { self.captureRotationAngle = angle }
        }
    }

    static func readCapabilities(_ d: AVCaptureDevice) -> HardwareCapabilities {
        let f = d.activeFormat
        var lo = min(f.minLensAperture, f.maxLensAperture)
        var hi = max(f.minLensAperture, f.maxLensAperture)
        if hi <= 0 { lo = d.lensAperture; hi = d.lensAperture }
        var stops = f.recommendedLensApertureStops.filter { $0 >= lo - 0.01 && $0 <= hi + 0.01 }.sorted()
        if stops.isEmpty { stops = hi - lo > 0.05 ? [lo, hi] : [lo] }
        return HardwareCapabilities(
            deviceName: d.localizedName,
            apertureStops: stops,
            apertureRange: lo...hi,
            isoRange: f.minISO...f.maxISO,
            shutterRange: f.minExposureDuration.seconds...f.maxExposureDuration.seconds,
            biasRange: d.minExposureTargetBias...d.maxExposureTargetBias,
            supportedSignals: d.supportedExposureSignals,
            supportsCustomWB: d.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            supportsGlobalToneMapping: f.isGlobalToneMappingSupported,
            photoDimensions: f.supportedMaxPhotoDimensions)
    }

    // MARK: - 修改前快照：先恢复全自动，等 AE/AWB 稳定后读数

    func resetAndSnapshot(completion: @escaping (DeviceSnapshot?) -> Void) {
        sessionQueue.async {
            guard let d = self.device else { DispatchQueue.main.async { completion(nil) }; return }
            self.stopWBFollow()
            if (try? d.lockForConfiguration()) != nil {
                if !d.supportedExposureSignals.isEmpty { d.automaticallyEnablesExposureSignals = true }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.setExposureTargetBias(0, completionHandler: nil)
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                if d.activeFormat.isGlobalToneMappingSupported { d.isGlobalToneMappingEnabled = false }
                d.unlockForConfiguration()
            }
            self.sessionQueue.asyncAfter(deadline: .now() + 0.7) {
                let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
                let snap = DeviceSnapshot(
                    lens: self.sessionLens,
                    aperture: d.lensAperture,
                    shutter: d.exposureDuration.seconds,
                    iso: d.iso,
                    bias: d.exposureTargetBias,
                    wb: TempTint(temperature: Double(tt.temperature), tint: Double(tt.tint)),
                    enabledSignals: d.enabledExposureSignals,
                    globalToneMapping: d.isGlobalToneMappingEnabled)
                DispatchQueue.main.async { completion(snap) }
            }
        }
    }

    // MARK: - 应用拍摄计划

    func apply(_ newPlan: CapturePlan, completion: @escaping (ApplyReport) -> Void) {
        sessionQueue.async {
            self.plan = newPlan
            self.pushGrading()
            self.locked { self._use48MP = newPlan.use48MP; self._planSummary = Self.summary(of: newPlan) }
            guard let d = self.device else { DispatchQueue.main.async { completion(ApplyReport()) }; return }

            var report = ApplyReport()
            do {
                try d.lockForConfiguration()

                // 1) iOS 27 曝光信号
                if !d.supportedExposureSignals.isEmpty {
                    if newPlan.disabledSignals.isEmpty {
                        d.automaticallyEnablesExposureSignals = true
                    } else {
                        d.automaticallyEnablesExposureSignals = false
                        d.enabledExposureSignals = d.supportedExposureSignals.subtracting(newPlan.disabledSignals)
                    }
                }

                // 2) 光圈 / 快门 / ISO（含优先模式与降级）
                report.exposureStatus = self.applyExposure(d, plan: newPlan)

                // 3) 曝光补偿
                let b = min(max(newPlan.bias, d.minExposureTargetBias), d.maxExposureTargetBias)
                d.setExposureTargetBias(b, completionHandler: nil)

                // 4) 白平衡
                if let off = newPlan.wbOffset, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    self.lockWhiteBalance(d, offset: off)
                } else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }

                // 5) 全局色调映射
                if d.activeFormat.isGlobalToneMappingSupported {
                    d.isGlobalToneMappingEnabled = newPlan.globalToneMapping
                }
                d.unlockForConfiguration()
            } catch {
                report.exposureStatus = .unsupported("无法锁定相机：\(error.localizedDescription)")
            }

            if newPlan.wbOffset != nil && self.locked({ self._wbFollow }) { self.startWBFollow() } else { self.stopWBFollow() }
            if let d = self.device { self.setupCameraControls(device: d, caps: Self.readCapabilities(d)) }

            // 6) 等待生效后回读真实值（iOS 27 早期版本存在“设置被静默忽略”的报告，所以必须验证）
            let partial = report
            self.sessionQueue.asyncAfter(deadline: .now() + 0.9) {
                var report = partial
                let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
                report.actualAperture = d.lensAperture
                report.actualShutter = d.exposureDuration.seconds
                report.actual = [
                    "lens": "\(self.sessionLens.rawValue) · \(d.localizedName)",
                    "aperture": Fmt.ap(d.lensAperture),
                    "shutter": Fmt.shutter(d.exposureDuration.seconds),
                    "iso": "ISO \(Int(d.iso))",
                    "bias": Fmt.ev(d.exposureTargetBias),
                    "wb": Fmt.wb(TempTint(temperature: Double(tt.temperature), tint: Double(tt.tint))),
                    "signals": Fmt.signals(d.enabledExposureSignals),
                    "tonemap": d.isGlobalToneMappingEnabled ? "开" : "关",
                    "resolution": newPlan.use48MP ? "48MP" : "24MP",
                    "quality": newPlan.hasManualExposure ? "速度优先" : "质量优先"
                ]
                DispatchQueue.main.async { completion(report) }
            }
        }
    }

    /// iOS 27：setExposureModeCustom(lensAperture:duration:iso:) + 自动退化
    private func applyExposure(_ d: AVCaptureDevice, plan: CapturePlan) -> ParameterChange.Status? {
        let f = d.activeFormat
        guard plan.hasManualExposure else {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            return nil
        }
        let aLo = min(f.minLensAperture, f.maxLensAperture), aHi = max(f.minLensAperture, f.maxLensAperture)
        let wantA: Float = plan.aperture.map { min(max($0, aLo), aHi) } ?? AVCaptureDevice.autoLensAperture
        let wantT: CMTime = plan.shutter.map {
            CMTime(seconds: min(max($0, f.minExposureDuration.seconds), f.maxExposureDuration.seconds), preferredTimescale: 1_000_000_000)
        } ?? AVCaptureDevice.autoExposureDuration
        let wantI: Float = plan.iso.map { min(max($0, f.minISO), f.maxISO) } ?? AVCaptureDevice.autoISO

        let candidates: [(Float, CMTime, Float, String?)] = [
            (wantA, wantT, wantI, nil),
            (wantA, AVCaptureDevice.autoExposureDuration, AVCaptureDevice.autoISO, "快门改为自动（仅光圈优先）"),
            (AVCaptureDevice.autoLensAperture, wantT, AVCaptureDevice.autoISO, "光圈改为自动（仅快门优先）"),
            (wantA, wantT, AVCaptureDevice.currentISO, "ISO 锁定为当前值")
        ]
        for (a, t, i, note) in candidates where f.supportsExposureModeCustom(lensAperture: a, duration: t, iso: i) {
            d.setExposureModeCustom(lensAperture: a, duration: t, iso: i, completionHandler: nil)
            return note.map { ParameterChange.Status.adjusted($0) }
        }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        return .unsupported("该镜头/格式不支持这组曝光，已保持全自动")
    }

    /// 以“灰世界”自动白平衡为基准，加上参考图的色温/色调偏移后锁定
    private func lockWhiteBalance(_ d: AVCaptureDevice, offset: TempTint) {
        let base = d.temperatureAndTintValues(for: d.grayWorldDeviceWhiteBalanceGains)
        let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: min(max(base.temperature + Float(offset.temperature), 2000), 12000),
            tint: min(max(base.tint + Float(offset.tint), -150), 150))
        var g = d.deviceWhiteBalanceGains(for: target)
        let maxG = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), maxG)
        g.greenGain = min(max(g.greenGain, 1), maxG)
        g.blueGain = min(max(g.blueGain, 1), maxG)
        d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
    }

    // MARK: - 白平衡跟随：场景光线变化时，保持“自动值 + 偏移”

    private func startWBFollow() {
        stopWBFollow()
        let t = DispatchSource.makeTimerSource(queue: sessionQueue)
        t.schedule(deadline: .now() + 1.5, repeating: 1.5)
        t.setEventHandler { [weak self] in
            guard let self, let d = self.device, let off = self.plan.wbOffset,
                  d.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
                  (try? d.lockForConfiguration()) != nil else { return }
            self.lockWhiteBalance(d, offset: off)
            d.unlockForConfiguration()
        }
        t.resume()
        wbTimer = t
    }

    private func stopWBFollow() {
        wbTimer?.cancel()
        wbTimer = nil
    }

    // MARK: - 开关

    /// 把“计划里的调色参数 + 当前版本（忠实/柔和/浓郁）”交给渲染器（只在 sessionQueue 上调用）
    private func pushGrading() {
        let (v, crop, fx) = locked { (_variant, _matchAspect, _effects) }
        var g = fx.apply(v.apply(plan.grading))
        if !crop { g.cropRatio = nil }           // 画幅裁切默认关闭，需在参数面板勾选
        renderer.update(g)
    }

    func setEffects(_ e: EffectToggles) {
        locked { _effects = e }
        sessionQueue.async { self.pushGrading() }
    }

    func setMatchAspect(_ on: Bool) {
        locked { _matchAspect = on }
        sessionQueue.async { self.pushGrading() }
    }

    func setVariant(_ v: StyleVariant) {
        locked { _variant = v }
        sessionQueue.async { self.pushGrading() }
    }

    func setStrength(_ v: Double) {
        sessionQueue.async {
            self.plan.grading.strength = v
            self.pushGrading()
        }
    }

    func setWBFollow(_ on: Bool) {
        locked { _wbFollow = on }
        sessionQueue.async { if on && self.plan.wbOffset != nil { self.startWBFollow() } else { self.stopWBFollow() } }
    }

    func setAutoMatch(_ on: Bool) { locked { _autoMatch = on } }
    func setSaveOriginal(_ on: Bool) { locked { _saveOriginal = on } }
    func setUse48MP(_ on: Bool) { locked { _use48MP = on } }

    func setReference(_ profile: StyleProfile?) {
        locked {
            _refHistogram = profile?.histogram
            _refMedianL = profile?.medianL
            _refChroma = profile?.meanChroma
            _refCast = profile.map { SIMD2($0.castA, $0.castB) }
            _refStats = profile?.refStats
            _refFace = profile?.faceRect
            _refMagnification = profile?.optics.magnification
            _preferPerson = (profile?.faceCount ?? 1) > 0
        }
        if profile == nil { DispatchQueue.main.async { self.matchScore = nil; self.autoMatchStatus = nil; self.compositionHint = nil } }
    }

    func setFilterEnabled(_ on: Bool) { renderer.setEnabled(on) }

    // MARK: - Camera Control 实体按键（拨动调光圈、风格强度、曝光补偿）

    private func setupCameraControls(device d: AVCaptureDevice, caps: HardwareCapabilities) {
        guard session.supportsControls else { return }
        session.beginConfiguration()
        session.setControlsDelegate(self, queue: controlsQueue)
        for c in session.controls { session.removeControl(c) }

        var controls: [AVCaptureControl] = []

        let strength = AVCaptureSlider("风格强度", symbolName: "camera.filters", in: 0...1)
        strength.value = Float(plan.grading.strength)
        strength.setActionQueue(sessionQueue) { [weak self] v in
            guard let self else { return }
            self.plan.grading.strength = Double(v)
            self.pushGrading()
            DispatchQueue.main.async { self.onStrengthFromControl?(Double(v)) }
        }
        controls.append(strength)

        if caps.hasVariableAperture && sessionLens.hasVariableAperture && caps.apertureStops.count > 1 {
            let stops = caps.apertureStops
            let picker = AVCaptureIndexPicker("光圈", symbolName: "camera.aperture",
                                              localizedIndexTitles: stops.map { Fmt.ap($0) })
            if let cur = plan.aperture, let idx = stops.firstIndex(where: { abs($0 - cur) < 0.05 }) {
                picker.selectedIndex = idx
            }
            picker.setActionQueue(sessionQueue) { [weak self] idx in
                guard let self, idx >= 0, idx < stops.count, let d = self.device else { return }
                self.plan.aperture = stops[idx]
                if (try? d.lockForConfiguration()) != nil {
                    _ = self.applyExposure(d, plan: self.plan)
                    d.unlockForConfiguration()
                }
                DispatchQueue.main.async { self.onApertureFromControl?(stops[idx]) }
            }
            controls.append(picker)
        }

        controls.append(AVCaptureSystemExposureBiasSlider(device: d))

        for c in controls where session.canAddControl(c) { session.addControl(c) }
        session.commitConfiguration()
    }

    // MARK: - ProRAW

    func setProRAW(_ on: Bool) {
        sessionQueue.async {
            guard self.photoOutput.isAppleProRAWSupported else { return }
            self.session.beginConfiguration()
            self.photoOutput.isAppleProRAWEnabled = on
            self.session.commitConfiguration()
            let now = self.photoOutput.isAppleProRAWEnabled
            DispatchQueue.main.async { self.proRAWEnabled = now }
        }
    }

    // MARK: - 视频模式

    func setVideoMode(_ on: Bool) {
        if on {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.sessionQueue.async { self.configureAudio(granted) }
            }
        } else {
            if isRecording { stopRecording() }
            sessionQueue.async { self.configureAudio(false) }
        }
        DispatchQueue.main.async { self.videoMode = on }
    }

    private func configureAudio(_ on: Bool) {
        session.beginConfiguration()
        if on, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
            }
        } else if !on {
            if let a = audioInput { session.removeInput(a); audioInput = nil }
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        }
        session.commitConfiguration()
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        videoQueue.async { self.wantRecording = true }
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingSeconds = 0
            self.recordTimer?.invalidate()
            self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.recordingSeconds += 1
            }
        }
    }

    private func stopRecording() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordTimer?.invalidate()
            self.recordTimer = nil
        }
        videoQueue.async {
            self.wantRecording = false
            guard let rec = self.recorder else { return }
            self.recorder = nil
            DispatchQueue.main.async { self.isSaving = true }
            rec.finish { url in
                guard let url else {
                    DispatchQueue.main.async { self.isSaving = false; self.statusMessage = "视频写入失败" }
                    return
                }
                PhotoProcessor.saveVideo(url) { err in
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.statusMessage = err ?? "视频已保存到相册"
                    }
                }
            }
        }
    }

    // MARK: - 拍照

    func capturePhoto() {
        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            let processed: [String: Any]? = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil
            if self.photoOutput.isAppleProRAWEnabled,
               let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                // ProRAW：同时拿到 DNG（未调色的数字底片）和处理后的照片
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: processed)
            } else if let processed {
                settings = AVCapturePhotoSettings(format: processed)
            } else {
                settings = AVCapturePhotoSettings()
            }
            if let dims = self.chooseDimensions() { settings.maxPhotoDimensions = dims }
            // 苹果文档：自定义锁定的曝光值要在拍照中生效，必须用 .speed
            settings.photoQualityPrioritization = self.plan.hasManualExposure ? .speed : .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            DispatchQueue.main.async { self.captureFlash += 1 }
        }
    }

    private func chooseDimensions() -> CMVideoDimensions? {
        guard let d = device else { return nil }
        let maxArea = Int(photoOutput.maxPhotoDimensions.width) * Int(photoOutput.maxPhotoDimensions.height)
        let dims = d.activeFormat.supportedMaxPhotoDimensions
            .filter { Int($0.width) * Int($0.height) <= maxArea }
            .sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        guard !dims.isEmpty else { return nil }
        if locked({ _use48MP }) { return dims.last }
        return dims.min { abs(Int($0.width) * Int($0.height) - 24_000_000) < abs(Int($1.width) * Int($1.height) - 24_000_000) }
    }

    private static func summary(of p: CapturePlan) -> String {
        var parts = ["StyleCam", p.lens.rawValue]
        if let a = p.aperture { parts.append(Fmt.ap(a)) }
        if let s = p.shutter { parts.append(Fmt.shutter(s)) }
        parts.append(Fmt.ev(p.bias))
        if let wb = p.wbOffset { parts.append("WB\(Fmt.signed(wb.temperature))K") }
        if !p.disabledSignals.isEmpty { parts.append("关闭信号:" + Fmt.signals(p.disabledSignals)) }
        let g = p.grading
        parts.append("对比\(Fmt.signed(g.contrast * 100)) 饱和\(Fmt.percent(g.saturation)) 褪色\(Fmt.percent(g.shadowLift)) 颗粒\(Fmt.percent(g.grain)) 强度\(Fmt.percent(g.strength))")
        return parts.joined(separator: " | ")
    }

    // MARK: - 实时直方图与匹配度

    private func analyzeLive(_ image: CIImage, raw: CIImage, device d: AVCaptureDevice?) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        // 用 Lanczos 缩小（会做区域平均），避免颗粒/噪点让亮度统计失真
        let s = 64 / max(extent.width, extent.height)
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: s, kCIInputAspectRatioKey: 1
        ])
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 0, h > 0 else { return }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            histContext.render(small, toBitmap: base, rowBytes: w * 4,
                               bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                               format: .RGBA8, colorSpace: srgb)
        }
        let lut = ColorMath.srgbToLinearLUT
        var hist = [Double](repeating: 0, count: 32)
        var Ls: [Double] = []
        Ls.reserveCapacity(w * h)
        var chromaSum = 0.0
        var nA: [Double] = [], nB: [Double] = []
        for p in 0..<(w * h) {
            let i = p * 4
            let lab = ColorMath.linearRGBToLab(lut[Int(buf[i])], lut[Int(buf[i + 1])], lut[Int(buf[i + 2])])
            let L = lab.L
            Ls.append(L)
            hist[min(31, max(0, Int(L / 100 * 32)))] += 1
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            chromaSum += c
            if L > 25, L < 85, c < 22 { nA.append(lab.a); nB.append(lab.b) }
        }
        let total = Double(w * h)
        hist = hist.map { $0 / total }
        let (ref, autoMatch, variant, refStats) = locked { (_refHistogram, _autoMatch, _variant, _refStats) }
        var score: Double?
        if let ref {
            score = zip(ref, hist).reduce(0) { $0 + min($1.0, $1.1) }   // 直方图交集 0...1
        }

        // 风格匹配：用“未调色”的取景帧统计，按分位点对齐影调、按比值对齐彩度、按差值对齐色偏（时间平滑防闪烁）
        guard autoMatch, let refStats, let rawStats = StyleMatcher.stats(of: raw, context: histContext) else {
            publishReadout(hist: hist, score: score, device: d)
            return
        }
        sessionQueue.async {
            var g = self.plan.grading
            StyleMatcher.apply(to: &g, raw: rawStats, ref: refStats, variant: variant, alpha: 0.35)
            self.plan.grading = g
            self.pushGrading()
            let status = String(format: "画面中位 L*%.0f→%.0f · 彩度 %.1f→%.1f（×%.2f）· 色偏 a*%+.1f b*%+.1f",
                                rawStats.median, refStats.median, rawStats.chroma, refStats.chroma,
                                g.saturation, g.castA, g.castB)
            DispatchQueue.main.async { self.autoMatchStatus = status }
        }

        // 硬件曝光：让未调色画面的亮度大致接近参考图（只走一半，剩下交给影调曲线），减少暗处拉亮带来的噪点
        if let d, Date().timeIntervalSince(lastAutoMatch) > 0.4 {
            let diff = (refStats.median - rawStats.median) * 0.5
            // 安全限制：最多 ±1EV；ISO 已经很高（噪点大）或快门已经很慢时不再往亮调
            let isoHigh = d.iso > min(1000, d.activeFormat.maxISO * 0.5)
            let slow = d.exposureDuration.seconds >= 1.0 / 20
            if abs(diff) > 3 && !(diff > 0 && (isoHigh || slow)) {
                lastAutoMatch = Date()
                let step = Float(max(-0.1, min(0.1, diff * 0.015)))
                sessionQueue.async {
                    guard (try? d.lockForConfiguration()) != nil else { return }
                    let nb = min(max(d.exposureTargetBias + step, max(d.minExposureTargetBias, -1)), min(d.maxExposureTargetBias, 1))
                    d.setExposureTargetBias(nb, completionHandler: nil)
                    d.unlockForConfiguration()
                }
            }
        }
        publishReadout(hist: hist, score: score, device: d)
    }

    private func publishReadout(hist: [Double], score: Double?, device d: AVCaptureDevice?) {
        var r = LiveReadout()
        if let d {
            let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
            let eq = Optics.lens(sessionLens).equivalentF(Double(d.lensAperture))
            r = LiveReadout(aperture: Fmt.ap(d.lensAperture) + "≈" + Optics.fmtF(eq),
                            shutter: Fmt.shutter(d.exposureDuration.seconds),
                            iso: "ISO \(Int(d.iso))",
                            wb: Fmt.kelvin(Double(tt.temperature)),
                            bias: Fmt.ev(d.exposureTargetBias))
        }
        DispatchQueue.main.async {
            self.liveHistogram = hist
            self.matchScore = score
            if self.readout != r { self.readout = r }
        }
    }
}

// MARK: - 视频帧

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let raw = CIImage(cvPixelBuffer: pb)
        let st = renderer.snapshotState()
        let masks = updateLiveMasks(pb, extent: raw.extent, state: st)
        let filtered = renderer.apply(raw, state: st, masks: masks)
        frameStore.set(raw: raw, filtered: filtered)
        if wantRecording {
            if recorder == nil {
                let e = filtered.extent
                let scale = min(1, 1920 / max(e.width, e.height))
                let rot = ((locked({ _captureAngle }) - 90) % 360 + 360) % 360
                recorder = VideoRecorder(width: Int(e.width * scale), height: Int(e.height * scale),
                                         rotationDegrees: rot, context: videoContext)
            }
            recorder?.appendVideo(filtered, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        frameCount += 1
        if frameCount % 12 == 0 {
            analyzeLive(filtered, raw: raw, device: (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device)
            updateCompositionHint(filtered)
        }
    }
}

extension CameraManager {
    /// 实时分割：人像分割（balanced，每 3 帧）用于肤色保护和人像背景虚化；非人像主体用前景实例分割（每 10 帧）
    fileprivate func updateLiveMasks(_ pb: CVPixelBuffer, extent: CGRect, state st: StyleRenderer.State) -> RenderMasks {
        let needPerson = StyleRenderer.needsPersonMask(st)
        let needSubject = StyleRenderer.needsSubjectMask(st)
        let preferPerson = locked({ _preferPerson })
        guard needPerson || needSubject else {
            livePerson = nil; liveSubject = nil
            return RenderMasks()
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        if (needPerson || preferPerson) && (livePerson == nil || frameCount % 3 == 0),
           (try? handler.perform([personSeg])) != nil, let out = personSeg.results?.first?.pixelBuffer {
            livePerson = SubjectMasker.ciMask(out, fitting: extent)
        }
        if needSubject && !preferPerson && (liveSubject == nil || frameCount % 10 == 0),
           let out = SubjectMasker.foregroundMask(handler) {
            liveSubject = SubjectMasker.ciMask(out, fitting: extent)
        }
        return RenderMasks(subject: needSubject ? (preferPerson ? livePerson : (liveSubject ?? livePerson)) : nil,
                           person: needPerson ? livePerson : nil)
    }

    /// 构图提示：比较实时画面与参考图里人脸的位置和大小（都换算到“照片方向”的归一化坐标）
    fileprivate func updateCompositionHint(_ frame: CIImage) {
        let (refFace, refM, angle) = locked { (_refFace, _refMagnification, _captureAngle) }
        guard let refFace else {
            DispatchQueue.main.async { if self.compositionHint != nil { self.compositionHint = nil } }
            return
        }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: frame, options: [:]).perform([req])
        guard let face = req.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height }) else {
            DispatchQueue.main.async {
                self.compositionHint = "参考图里有人物，把人放进画面"
                self.compositionAligned = false
            }
            return
        }
        // 预览帧 → 照片方向：顺时针旋转 (angle − 90)°
        let rot = ((angle - 90) % 360 + 360) % 360
        let live = NormRect.rotate(NormRect.fromVision(face.boundingBox), clockwise: rot)
        let e = frame.extent
        let (pw, ph) = (rot == 90 || rot == 270) ? (e.height, e.width) : (e.width, e.height)
        let liveFaceFrac = Double(live.height * ph / max(pw, ph))

        var hints: [String] = []
        let sizeRatio = Double(live.height / max(refFace.height, 0.001))
        if sizeRatio < 0.85 || sizeRatio > 1.18 {
            let f35 = sessionLens.focal35
            if let refM {
                let mLive = liveFaceFrac * Optics.ffLongEdge / Optics.faceHeightMM
                let target = Optics.subjectDistance(focal35: f35, magnification: refM)
                let now = Optics.subjectDistance(focal35: f35, magnification: mLive)
                let d = abs(now - target)
                hints.append(now > target ? String(format: "靠近约 %.1fm", d) : String(format: "后退约 %.1fm", d))
            } else {
                hints.append(sizeRatio < 1 ? "靠近一点" : "后退一点")
            }
        }
        let dx = Double(live.midX - refFace.midX), dy = Double(live.midY - refFace.midY)
        if abs(dx) > 0.06 { hints.append(dx > 0 ? "镜头向右转" : "镜头向左转") }
        if abs(dy) > 0.06 { hints.append(dy > 0 ? "镜头向下压" : "镜头向上抬") }
        let aligned = hints.isEmpty
        let text = aligned ? "✓ 构图已对齐参考图" : hints.joined(separator: " · ")
        DispatchQueue.main.async {
            if self.compositionHint != text { self.compositionHint = text }
            if self.compositionAligned != aligned { self.compositionAligned = aligned }
        }
    }
}

// MARK: - 拍照回调

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.statusMessage = "拍照失败：\(error.localizedDescription)" }
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        let id = photo.resolvedSettings.uniqueID
        if photo.isRawPhoto {
            locked { pendingRaw[id] = data }
        } else {
            let metadata = photo.metadata
            locked { pendingProcessed[id] = (data, metadata) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let id = resolvedSettings.uniqueID
        let (processed, rawData) = locked { (pendingProcessed.removeValue(forKey: id), pendingRaw.removeValue(forKey: id)) }
        guard let processed else { return }
        let (data, metadata) = processed
        let state = renderer.snapshotState()
        let (summary, saveOriginal, preferPerson) = locked { (_planSummary, _saveOriginal, _preferPerson) }
        // 用成片 EXIF 的实际焦距校准等效光圈换算
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let fl = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue {
            Optics.calibrate(sessionLens, focalActual: fl)
        }
        DispatchQueue.main.async { self.isSaving = true }
        DispatchQueue.global(qos: .userInitiated).async {
            PhotoProcessor.process(data: data, metadata: metadata, renderer: self.renderer, state: state,
                                   summary: summary, preferPerson: preferPerson,
                                   saveOriginal: saveOriginal, rawData: rawData) { thumb, err in
                DispatchQueue.main.async {
                    self.isSaving = false
                    if let thumb { self.lastPhoto = thumb }
                    self.statusMessage = err ?? (rawData != nil ? "已保存（含 ProRAW 底片）" : "已保存到相册")
                }
            }
        }
    }
}

extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {}

// MARK: - Camera Control 委托

extension CameraManager: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
