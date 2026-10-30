import AVFoundation
import CoreImage
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
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var sessionLens: LensChoice = .wide
    private var plan = CapturePlan()
    private var configured = false

    // 跨线程开关
    private let stateLock = NSLock()
    private var _refHistogram: [Double]?
    private var _refMedianL: Double?
    private var _autoMatch = false
    private var _wbFollow = true
    private var _saveOriginal = false
    private var _use48MP = false
    private var _planSummary = ""

    private func locked<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }

    private var frameCount = 0
    private var lastAutoMatch = Date.distantPast
    private var wbTimer: DispatchSourceTimer?
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

        let avail = Set(LensChoice.allCases.filter {
            AVCaptureDevice.default($0.deviceType, for: .video, position: .back) != nil
        })
        DispatchQueue.main.async { self.availableLenses = avail }

        setLens(.wide)
        configured = true
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
            for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
                if let c = conn, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
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
            self.renderer.update(newPlan.grading)
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

    func setStrength(_ v: Double) {
        sessionQueue.async {
            self.plan.grading.strength = v
            self.renderer.update(self.plan.grading)
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
        }
        if profile == nil { DispatchQueue.main.async { self.matchScore = nil } }
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
            self.renderer.update(self.plan.grading)
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

    // MARK: - 拍照

    func capturePhoto() {
        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
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

    private func analyzeLive(_ image: CIImage, device d: AVCaptureDevice?) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let s = 64 / max(extent.width, extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
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
        for p in 0..<(w * h) {
            let i = p * 4
            let y = ColorMath.luminance(lut[Int(buf[i])], lut[Int(buf[i + 1])], lut[Int(buf[i + 2])])
            let L = ColorMath.luminanceToL(y)
            Ls.append(L)
            hist[min(31, max(0, Int(L / 100 * 32)))] += 1
        }
        let total = Double(w * h)
        hist = hist.map { $0 / total }
        let liveMedian = ColorMath.median(Ls)

        let (ref, refMedian, autoMatch) = locked { (_refHistogram, _refMedianL, _autoMatch) }
        var score: Double?
        if let ref {
            score = zip(ref, hist).reduce(0) { $0 + min($1.0, $1.1) }   // 直方图交集 0...1
        }

        // 闭环亮度对齐：慢慢调曝光补偿，让实时画面的亮度中位数靠近参考图
        if autoMatch, let refMedian, let d, Date().timeIntervalSince(lastAutoMatch) > 0.4 {
            let diff = refMedian - liveMedian
            if abs(diff) > 3 {
                lastAutoMatch = Date()
                let step = Float(max(-0.2, min(0.2, diff * 0.02)))
                sessionQueue.async {
                    guard (try? d.lockForConfiguration()) != nil else { return }
                    let nb = min(max(d.exposureTargetBias + step, max(d.minExposureTargetBias, -3)), min(d.maxExposureTargetBias, 3))
                    d.setExposureTargetBias(nb, completionHandler: nil)
                    d.unlockForConfiguration()
                }
            }
        }

        var r = LiveReadout()
        if let d {
            let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
            r = LiveReadout(aperture: Fmt.ap(d.lensAperture),
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
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let raw = CIImage(cvPixelBuffer: pb)
        let filtered = renderer.apply(raw, state: renderer.snapshotState())
        frameStore.set(raw: raw, filtered: filtered)
        frameCount += 1
        if frameCount % 12 == 0 {
            analyzeLive(filtered, device: (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device)
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
        let metadata = photo.metadata
        let state = renderer.snapshotState()
        let (summary, saveOriginal) = locked { (_planSummary, _saveOriginal) }
        DispatchQueue.main.async { self.isSaving = true }
        DispatchQueue.global(qos: .userInitiated).async {
            PhotoProcessor.process(data: data, metadata: metadata, renderer: self.renderer, state: state,
                                   summary: summary, saveOriginal: saveOriginal) { thumb, err in
                DispatchQueue.main.async {
                    self.isSaving = false
                    if let thumb { self.lastPhoto = thumb }
                    self.statusMessage = err ?? "已保存到相册"
                }
            }
        }
    }
}

// MARK: - Camera Control 委托

extension CameraManager: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
