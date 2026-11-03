import Foundation
import ImageCaptureCore
import CoreImage
import Combine

/// 索尼相机 USB 联机（相机设为“PC 遥控”）：握手 → 实时取景 → 遥控快门 → 新照片自动取回。
/// 通过 ImageCaptureCore 发送 PTP 指令（含索尼扩展指令），所有 ImageCaptureCore 调用都在主线程。
final class SonyTether: NSObject, ObservableObject, @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case waitingAuth
        case searching
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []
    @Published var liveViewOn = true
    @Published private(set) var fps: Double = 0
    @Published private(set) var importing = false

    /// 每一帧实时取景（相机原始 JPEG 解码后的图）
    var onFrame: ((CIImage) -> Void)?
    /// 每取回一张照片（原始文件数据、文件名）
    var onPhoto: ((Data, String) -> Void)?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var liveTask: Task<Void, Never>?
    private let gate = SerialGate()
    private let qLock = NSLock()
    private var _importQueue: [UInt32] = []
    private var queueEmpty: Bool { qLock.lock(); defer { qLock.unlock() }; return _importQueue.isEmpty }
    private var lastShot = Date.distantPast

    var isConnected: Bool { if case .connected = phase { return true } else { return false } }

    // MARK: - 开始 / 结束

    func start() {
        guard phase == .idle || isFailed else { return }
        browser.delegate = self
        setPhase(.waitingAuth)
        addLog("请求访问外接相机的权限…")
        browser.requestControlAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.setPhase(.failed("没有获得访问外接相机的权限（设置 → 隐私与安全性里可以打开）"))
                    return
                }
                self.addLog("已授权，开始查找 USB 相机…")
                self.setPhase(.searching)
                self.browser.start()
            }
        }
    }

    func stop() {
        liveTask?.cancel(); liveTask = nil
        if let cam = camera {
            cam.requestCloseSession()
        }
        camera = nil
        browser.stop()
        setPhase(.idle)
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    // MARK: - PTP 收发（串行：同一时间只有一条指令在路上）

    private struct Reply {
        let code: UInt16
        let data: Data
        var ok: Bool { code == PTP.ok }
    }

    private func send(_ code: UInt16, _ params: [UInt32] = [], out: Data? = nil) async -> Reply? {
        await gate.lock()
        let reply = await withCheckedContinuation { (cont: CheckedContinuation<Reply?, Never>) in
            DispatchQueue.main.async {
                guard let cam = self.camera else { cont.resume(returning: nil); return }
                cam.requestSendPTPCommand(PTP.command(code, params), outData: out) { a, b, error in
                    if let error {
                        self.addLog("指令 \(PTP.hex(code)) 失败：\(error.localizedDescription)")
                        cont.resume(returning: nil)
                        return
                    }
                    // 两段数据里，类型为 3（响应）的是响应容器，另一段是数据
                    let ca = PTP.container(a), cb = PTP.container(b)
                    if let cb, cb.type == 3 {
                        cont.resume(returning: Reply(code: cb.code, data: a))
                    } else if let ca, ca.type == 3 {
                        cont.resume(returning: Reply(code: ca.code, data: b))
                    } else {
                        cont.resume(returning: Reply(code: cb?.code ?? 0, data: a))
                    }
                }
            }
        }
        await gate.unlock()
        return reply
    }

    private func setControl(_ prop: UInt16, _ value: UInt16) async -> Bool {
        let r = await send(PTP.Sony.controlDevice, [UInt32(prop)], out: PTP.u16(value))
        return r?.ok ?? false
    }

    // MARK: - 握手

    private func handshake() async {
        guard let name = camera?.name else { return }
        setPhase(.connecting(name))
        for phase in [UInt32(1), 2] {
            let r = await send(PTP.Sony.connect, [phase, 0, 0])
            addLog("SDIO_Connect \(phase) → \(r.map { PTP.hex($0.code) } ?? "无响应")")
        }
        var gotExt = false
        for _ in 0..<10 {
            if let r = await send(PTP.Sony.getExtDeviceInfo, [PTP.Sony.protocol300, 1]), r.ok, r.data.count > 2 {
                addLog(String(format: "扩展信息：协议版本 0x%X，%d 字节", r.data.le16(0), r.data.count))
                gotExt = true
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let r3 = await send(PTP.Sony.connect, [3, 0, 0])
        addLog("SDIO_Connect 3 → \(r3.map { PTP.hex($0.code) } ?? "无响应")")
        let pr = await send(PTP.Sony.setExtDevicePropValue, [UInt32(PTP.Sony.propPriorityMode)], out: PTP.u8(1))
        addLog("切换为手机端控制 → \(pr.map { PTP.hex($0.code) } ?? "无响应")")

        if !gotExt {
            setPhase(.failed("相机没有回应索尼联机握手。请确认相机的 USB 连接设为「PC 遥控」，并关闭「智能手机控制」"))
            return
        }
        setPhase(.connected(name))
        startLiveView()
    }

    // MARK: - 实时取景

    private func startLiveView() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            var frames = 0
            var windowStart = Date()
            var misses = 0
            while !Task.isCancelled {
                guard let self, self.isConnected else { return }
                if !self.liveViewOn || !self.queueEmpty {
                    if !self.queueEmpty { await self.drainImports() }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                let t0 = Date()
                guard let r = await self.send(PTP.getObject, [PTP.Sony.liveViewHandle]) else {
                    misses += 1
                    if misses > 30 { self.setPhase(.failed("取景画面连续读取失败，请重新插线")); return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if r.ok, let jpeg = PTP.liveViewJPEG(r.data), let img = CIImage(data: jpeg) {
                    misses = 0
                    self.onFrame?(img)
                    frames += 1
                    let dt = Date().timeIntervalSince(windowStart)
                    if dt > 1 {
                        let f = Double(frames) / dt
                        DispatchQueue.main.async { self.fps = f }
                        frames = 0; windowStart = Date()
                    }
                } else {
                    // 刚开始或太快时相机会回 AccessDenied / InvalidObjectHandle，稍等再取
                    if r.code != PTP.accessDenied && r.code != PTP.invalidObjectHandle && misses % 20 == 0 {
                        self.addLog("取景帧：\(PTP.hex(r.code))，\(r.data.count) 字节")
                    }
                    misses += 1
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // 约 20 帧 / 秒封顶，给拍照和事件留出带宽
                let spent = Date().timeIntervalSince(t0)
                if spent < 0.05 { try? await Task.sleep(nanoseconds: UInt64((0.05 - spent) * 1e9)) }
            }
        }
    }

    // MARK: - 快门

    func shoot() {
        guard isConnected, Date().timeIntervalSince(lastShot) > 0.5 else { return }
        lastShot = Date()
        Task {
            _ = await setControl(PTP.Sony.propShutterHalf, 2)
            _ = await setControl(PTP.Sony.propShutterFull, 2)
            try? await Task.sleep(nanoseconds: 350_000_000)
            _ = await setControl(PTP.Sony.propShutterFull, 1)
            _ = await setControl(PTP.Sony.propShutterHalf, 1)
            addLog("已按下快门")
            // 有的机型不发“新增对象”事件：3 秒内没收到就主动去取一次
            let shotAt = Date()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.queueEmpty, self.lastImport < shotAt {
                enqueueImport(PTP.Sony.shotHandle)
            }
        }
    }

    // MARK: - 取回新照片

    private var lastImport = Date.distantPast

    private func enqueueImport(_ handle: UInt32) {
        qLock.lock()
        if !_importQueue.contains(handle) { _importQueue.append(handle) }
        qLock.unlock()
    }

    private func nextImport() -> UInt32? {
        qLock.lock(); defer { qLock.unlock() }
        return _importQueue.isEmpty ? nil : _importQueue.removeFirst()
    }

    private func drainImports() async {
        while let handle = nextImport() {
            await importObject(handle)
        }
    }

    private func importObject(_ handle: UInt32) async {
        DispatchQueue.main.async { self.importing = true }
        defer { DispatchQueue.main.async { self.importing = false } }
        // RAW+JPEG 时同一个句柄会依次给出两个文件，最多取 2 次
        for _ in 0..<2 {
            var info: PTP.ObjectInfo?
            for _ in 0..<40 {
                if let r = await send(PTP.getObjectInfo, [handle]), r.ok, let oi = PTP.objectInfo(r.data) {
                    info = oi; break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let info else { return }
            addLog(String(format: "取回 %@（%.1f MB）…", info.filename, Double(info.size) / 1_048_576))
            guard let r = await send(PTP.getObject, [handle]), r.ok, !r.data.isEmpty else {
                addLog("取回失败。照片太大时，请把相机「RAW+J PC 保存图像」设为「仅 JPEG」")
                return
            }
            lastImport = Date()
            let name = info.filename.isEmpty ? "DSC.JPG" : info.filename
            onPhoto?(r.data, name)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: - 工具

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    func addLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(s)"
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    fileprivate func handleEvent(_ data: Data) {
        guard let c = PTP.container(data) else { return }
        switch c.code {
        case PTP.Sony.evObjectAdded, PTP.evObjectAdded:
            let h = c.params.first ?? PTP.Sony.shotHandle
            addLog(String(format: "相机拍了一张（句柄 0x%08X）", h))
            enqueueImport(h)
        case PTP.Sony.evPropChanged:
            break
        default:
            addLog("事件 \(PTP.hex(c.code)) \(c.params.map { String(format: "0x%X", $0) }.joined(separator: " "))")
        }
    }
}

// MARK: - 设备发现与会话

extension SonyTether: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        addLog("发现相机：\(cam.name ?? "未知") \(cam.transportType ?? "")")
        camera = cam
        cam.delegate = self
        setPhase(.connecting(cam.name ?? "相机"))
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device == camera else { return }
        addLog("相机已断开")
        liveTask?.cancel(); liveTask = nil
        camera = nil
        setPhase(.searching)
    }
}

extension SonyTether: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            setPhase(.failed("打开相机会话失败：\(error.localizedDescription)"))
            return
        }
        addLog("会话已打开，开始索尼联机握手…")
        Task { await handshake() }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        addLog("会话已关闭")
    }

    func didRemove(_ device: ICDevice) {
        guard device == camera else { return }
        liveTask?.cancel(); liveTask = nil
        camera = nil
        setPhase(.searching)
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        handleEvent(eventData)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// 简单的异步串行锁
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
