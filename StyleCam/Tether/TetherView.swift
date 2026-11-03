import SwiftUI
import CoreImage
import Vision
import Combine

/// 外接相机：手机实时显示相机取景（套滤镜后的效果），遥控快门，拍到的照片自动取回、套滤镜、存相册
final class TetherSession: ObservableObject, @unchecked Sendable {
    let tether = SonyTether()
    @Published private(set) var filtered: UIImage?
    @Published private(set) var original: UIImage?
    @Published private(set) var lastThumb: UIImage?
    @Published private(set) var savedCount = 0
    @Published private(set) var message: String?
    @Published var showOriginal = false
    @Published var autoSave = true
    @Published var saveOriginal = false

    private var snapshot: GradingSnapshot
    private var tetherSub: AnyCancellable?
    private let preferPerson: Bool
    private let renderer = StyleRenderer()
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "tether.render", qos: .userInteractive)
    private let lock = NSLock()
    private var rendering = false
    private var frameIndex = 0
    private var matched: GradingParams?
    private var state: StyleRenderer.State?
    private var personMask: CIImage?
    private let personSeg: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast
        return r
    }()

    init(snapshot: GradingSnapshot, preferPerson: Bool) {
        self.snapshot = snapshot
        self.preferPerson = preferPerson
        tetherSub = tether.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        tether.onFrame = { [weak self] img in self?.handleFrame(img) }
        tether.onPhoto = { [weak self] data, name in self?.handlePhoto(data, name: name) }
    }

    /// 风格在主界面改了之后（例如换了滤镜），同步过来
    func update(snapshot s: GradingSnapshot) {
        lock.lock(); snapshot = s; matched = nil; state = nil; lock.unlock()
    }

    // MARK: - 实时取景

    private func handleFrame(_ img: CIImage) {
        lock.lock()
        if rendering { lock.unlock(); return }          // 上一帧还没画完就丢掉这一帧，保证不积压
        rendering = true
        lock.unlock()
        renderQueue.async { [self] in
            defer { lock.lock(); rendering = false; lock.unlock() }
            frameIndex += 1
            lock.lock(); let snap = snapshot; var m = matched; var st = state; lock.unlock()
            // 影调色彩每 8 帧重新对齐一次（参考图风格才需要；内置滤镜参数固定）
            if st == nil || (snap.ref != nil && frameIndex % 8 == 0) {
                m = snap.liveMatch(for: img, context: ctx, previous: m)
                st = snap.renderState(from: m!)
                lock.lock(); matched = m; state = st; lock.unlock()
            }
            guard let st else { return }
            // 皮肤（肤色保护 / 美颜）需要人像蒙版，每 5 帧更新一次
            var masks = RenderMasks()
            if StyleRenderer.needsPersonMask(st) {
                if personMask == nil || frameIndex % 5 == 0 {
                    let h = VNImageRequestHandler(ciImage: img, options: [:])
                    if (try? h.perform([personSeg])) != nil, let pb = personSeg.results?.first?.pixelBuffer {
                        personMask = SubjectMasker.ciMask(pb, fitting: img.extent)
                    }
                }
                masks.person = personMask
            }
            let out = renderer.apply(img, state: st, masks: masks)
            let showOrig = showOriginal
            guard let cg = ctx.createCGImage(showOrig ? img : out, from: img.extent) else { return }
            let ui = UIImage(cgImage: cg)
            DispatchQueue.main.async {
                if showOrig { self.original = ui } else { self.filtered = ui }
            }
        }
    }

    // MARK: - 新照片

    private func handlePhoto(_ data: Data, name: String) {
        guard autoSave else {
            DispatchQueue.main.async { self.message = "已取回 \(name)（未保存：自动存相册已关闭）" }
            return
        }
        lock.lock(); let snap = snapshot; lock.unlock()
        let keepOriginal = saveOriginal
        DispatchQueue.main.async { self.message = "正在给 \(name) 套滤镜…" }
        DispatchQueue.global(qos: .userInitiated).async {
            PhotoProcessor.processExisting(data: data, renderer: StyleRenderer(), grading: snap,
                                           preferPerson: self.preferPerson,
                                           summary: "StyleCam 外接相机 | \(name)",
                                           saveOriginal: keepOriginal) { thumb, err in
                DispatchQueue.main.async {
                    if let thumb { self.lastThumb = thumb }
                    if err == nil { self.savedCount += 1 }
                    self.message = err ?? "已保存 \(name)（套滤镜）\(keepOriginal ? " + 相机原片" : "")"
                }
            }
        }
    }
}

struct TetherView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: TetherSession
    @State private var showLog = false

    init(snapshot: GradingSnapshot, preferPerson: Bool) {
        _session = StateObject(wrappedValue: TetherSession(snapshot: snapshot, preferPerson: preferPerson))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                topBar
                viewer
                controls
            }
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            model.camera.stop()                         // 用外接相机时先停掉手机相机，省电省带宽
            session.tether.start()
        }
        .onDisappear {
            session.tether.stop()
            model.camera.start()
        }
        .onChange(of: model.currentPreset?.id) { _, _ in session.update(snapshot: model.camera.gradingSnapshot()) }
        .onChange(of: model.variant) { _, _ in session.update(snapshot: model.camera.gradingSnapshot()) }
        .sheet(isPresented: $showLog) { logSheet }
    }

    private var styleName: String {
        model.currentPreset?.name ?? (model.referenceImage != nil ? "参考图风格" : "未选滤镜（原片）")
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline) }
                .buttonStyle(.glass)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseText).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(styleName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if session.tether.isConnected {
                Text(String(format: "%.0f fps", session.tether.fps))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.glass)
                .accessibilityLabel("连接日志")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var phaseText: String {
        switch session.tether.phase {
        case .idle: return "外接相机"
        case .waitingAuth: return "等待授权…"
        case .searching: return "等待 USB 连接相机…"
        case .connecting(let n): return "正在连接 \(n)…"
        case .connected(let n): return "已连接 \(n)"
        case .failed(let m): return m
        }
    }

    // MARK: - 取景

    @ViewBuilder
    private var viewer: some View {
        let img = session.showOriginal ? (session.original ?? session.filtered) : session.filtered
        ZStack {
            if session.tether.isConnected, let img {
                Image(uiImage: img).resizable().scaledToFit()
                    .overlay(alignment: .topLeading) {
                        Text(session.showOriginal ? "相机原片" : "套滤镜后")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassEffect(.regular, in: Capsule())
                            .padding(10)
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !session.showOriginal { session.showOriginal = true } }
                        .onEnded { _ in session.showOriginal = false })
                    .accessibilityHint("按住查看相机原片")
            } else if session.tether.isConnected {
                ProgressView("正在读取取景画面…").tint(.white)
            } else {
                setupGuide
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let m = session.message {
                Text(m).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用数据线连接索尼相机").font(.title3.weight(.semibold))
            step(1, "相机菜单里把「USB 连接」设为「PC 遥控」，并关闭「智能手机控制」。")
            step(2, "在「PC 遥控设置」里，把「静态影像保存目的地」设为「PC+相机」，「RAW+J PC 保存图像」设为「仅 JPEG」。")
            step(3, "用能传数据的 USB-C 转 Micro-USB 线连接手机和相机，打开相机电源。")
            step(4, "手机弹出访问相机的授权时，选择允许。连上后这里会显示相机的实时画面，并套上当前滤镜。")
            if case .failed = session.tether.phase {
                Button("重试") {
                    session.tether.stop()
                    session.tether.start()
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold)).frame(width: 18)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部

    private var controls: some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Toggle(isOn: $session.autoSave) { Text("自动存相册").font(.caption) }
                        .toggleStyle(.button).buttonStyle(.glass)
                    Toggle(isOn: $session.saveOriginal) { Text("同时存原片").font(.caption) }
                        .toggleStyle(.button).buttonStyle(.glass)
                        .disabled(!session.autoSave)
                    Toggle(isOn: Binding(get: { session.tether.liveViewOn }, set: { session.tether.liveViewOn = $0 })) {
                        Text("取景").font(.caption)
                    }
                    .toggleStyle(.button).buttonStyle(.glass)
                }
            }
            HStack {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let t = session.lastThumb {
                            Image(uiImage: t).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.1)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if session.savedCount > 0 {
                        Text("\(session.savedCount)").font(.caption2.bold())
                            .padding(4).background(.yellow, in: Circle()).foregroundStyle(.black)
                            .offset(x: 6, y: -6)
                    }
                }
                Spacer()
                Button { session.tether.shoot() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(session.tether.isConnected ? Color.white : Color.gray).frame(width: 62, height: 62)
                        if session.tether.importing { ProgressView().tint(.black) }
                    }
                }
                .disabled(!session.tether.isConnected)
                .accessibilityLabel("遥控相机拍照")
                Spacer()
                Color.clear.frame(width: 54, height: 54)
            }
            .padding(.horizontal, 28)
            Text("也可以直接按相机上的快门，拍到的照片会自动传到手机").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var logSheet: some View {
        NavigationStack {
            List(session.tether.log.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                .navigationTitle("连接日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: session.tether.log.joined(separator: "\n")) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
