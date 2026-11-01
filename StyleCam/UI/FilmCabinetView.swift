import SwiftUI
import CoreImage

/// 胶卷柜：内置的富士 / 佳能同款滤镜。
/// 复古的部分只放在内容里（片盒、胶片边框、片边印字、暖色颗粒底），
/// 操作控件全部用 iOS 27 液态玻璃，保持系统的干净感。
struct FilmCabinetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = PresetThumbnails()
    @State private var brand: PresetBrand?
    @State private var useLiveFrame = true

    private var presets: [LookPreset] { LookPresets.all.filter { brand == nil || $0.brand == brand } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    controls
                    ForEach(Array(PresetMood.allCases.enumerated()), id: \.element) { idx, mood in
                        let items = presets.filter { $0.mood == mood }
                        if !items.isEmpty { section(mood, index: idx + 1, items: items) }
                    }
                    Text("仿色风格：参数按各胶片模拟 / 照片风格公开的观感特征近似，非厂商官方配置。颗粒按画面已有噪点只补差值。")
                        .font(.caption2).foregroundStyle(Retro.dim)
                        .padding(.horizontal, 4).padding(.bottom, 90)
                }
                .padding(.horizontal, 16)
            }
            .background(RetroBackground())
            .safeAreaInset(edge: .bottom) { currentBar }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .onAppear { refreshThumbs() }
        .onChange(of: useLiveFrame) { _, _ in refreshThumbs(force: true) }
    }

    private func refreshThumbs(force: Bool = false) {
        let frame = useLiveFrame ? model.camera.frameStore.latest(original: true) : nil
        thumbs.render(from: frame ?? PresetThumbnails.sample, force: force)
    }

    // MARK: - 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FILM CABINET · NO.\(String(format: "%02d", LookPresets.all.count))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Retro.amber)
            Text("胶卷柜")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(Retro.paper)
            Text("富士 / 佳能同款，按心情挑一卷")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Retro.dim)
        }
        .padding(.top, 8)
    }

    // MARK: - 品牌筛选 + 样图来源（液态玻璃）

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                brandButton(nil, "全部")
                ForEach(PresetBrand.allCases) { brandButton($0, $0.rawValue) }
                Spacer(minLength: 4)
                Button {
                    useLiveFrame.toggle()
                } label: {
                    Label(useLiveFrame ? "取景样图" : "示例样图",
                          systemImage: useLiveFrame ? "camera.viewfinder" : "photo")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    private func brandButton(_ b: PresetBrand?, _ title: String) -> some View {
        let selected = brand == b
        if selected {
            Button(title) { brand = b }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glassProminent)
                .tint(Retro.amber)
        } else {
            Button(title) { withAnimation(.snappy) { brand = b } }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
        }
    }

    // MARK: - 按情绪分组

    private func section(_ mood: PresetMood, index: Int, items: [LookPreset]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Retro.amber)
                Text("\(mood.emoji) \(mood.rawValue)")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Retro.paper)
                Rectangle().fill(Retro.paper.opacity(0.18)).frame(height: 1)
                Text("\(items.count) 卷")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Retro.dim)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                row(p, frameNo: i + 1)
            }
        }
    }

    private func row(_ p: LookPreset, frameNo: Int) -> some View {
        let s = p.stock
        let selected = model.currentPreset?.id == p.id
        return Button {
            Task {
                await model.applyPreset(p)
                dismiss()
            }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                FilmFrame(image: thumbs.images[p.id], stock: s, frameNo: frameNo)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        FilmCanister(stock: s).frame(width: 22, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.code)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(Retro.amber)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text("ISO \(s.iso) · \(p.brand.rawValue)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Retro.dim)
                        }
                    }
                    Text(p.name)
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Retro.paper)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(p.note)
                        .font(.caption2)
                        .foregroundStyle(Retro.dim)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                    if selected {
                        Label("使用中", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Retro.amber)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(s.color.opacity(selected ? 0.28 : 0.10)).interactive(),
                     in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Retro.amber.opacity(selected ? 0.8 : 0), lineWidth: 1.5))
    }

    // MARK: - 底部：当前使用

    @ViewBuilder
    private var currentBar: some View {
        if let p = model.currentPreset {
            HStack(spacing: 10) {
                FilmCanister(stock: p.stock).frame(width: 18, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("正在使用").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(p.name).font(.system(.footnote, design: .serif).weight(.semibold)).lineLimit(1)
                }
                Spacer()
                Button("不用滤镜") {
                    model.clearReference()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }
}

// MARK: - 复古元素

enum Retro {
    static let amber = Color(red: 0.95, green: 0.62, blue: 0.24)
    static let paper = Color(red: 0.96, green: 0.92, blue: 0.84)
    static let dim = Color(red: 0.96, green: 0.92, blue: 0.84).opacity(0.55)
    static let filmBase = Color(red: 0.13, green: 0.09, blue: 0.06)
}

/// 暖色暗底 + 一层细颗粒（像放在暗房灯下）
struct RetroBackground: View {
    private static let grain: UIImage = {
        let n = 96
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 12345
        for i in 0..<(n * n) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = UInt8(truncatingIfNeeded: seed >> 24)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage().map { UIImage(cgImage: $0) } ?? UIImage()
    }()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.11, blue: 0.08), Color(red: 0.06, green: 0.05, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Retro.amber.opacity(0.16), .clear], center: .topLeading, startRadius: 10, endRadius: 420)
            Image(uiImage: Self.grain).resizable(resizingMode: .tile)
                .blendMode(.overlay).opacity(0.10)
        }
        .ignoresSafeArea()
    }
}

/// 竖向 35mm 胶片框：左右齿孔、片边橙色印字、底部帧号
struct FilmFrame: View {
    let image: UIImage?
    let stock: FilmStock
    let frameNo: Int

    private let w: CGFloat = 116, h: CGFloat = 170
    private let holeCol: CGFloat = 13

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Retro.filmBase)
            HStack {
                holes
                Spacer()
                holes
            }
            .padding(.horizontal, 3)
            VStack(spacing: 3) {
                Text("◀ \(stock.code)")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Retro.amber.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            ProgressView().controlSize(.small).tint(Retro.amber)
                        }
                    }
                }
                .frame(width: w - holeCol * 2 - 6, height: (w - holeCol * 2 - 6) * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                HStack {
                    Text("\(frameNo)A ▸")
                    Spacer()
                    Text("\(stock.iso)")
                }
                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Retro.amber.opacity(0.9))
            }
            .padding(.horizontal, holeCol + 3)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
    }

    private var holes: some View {
        VStack(spacing: 7) {
            ForEach(0..<10, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 0.06, green: 0.05, blue: 0.05))
                    .frame(width: 7, height: 9)
            }
        }
    }
}

/// 小片盒：盖子 + 彩色盒身 + 标签带 + 拉出来的片头
struct FilmCanister: View {
    let stock: FilmStock

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                // 片头
                RoundedRectangle(cornerRadius: 1)
                    .fill(Retro.filmBase)
                    .frame(width: w * 0.45, height: h * 0.18)
                    .offset(x: w * 0.42, y: h * 0.42)
                // 盒身
                RoundedRectangle(cornerRadius: w * 0.18)
                    .fill(LinearGradient(colors: [stock.color.opacity(0.75), stock.color, stock.color.opacity(0.7)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.8, height: h * 0.82)
                    .offset(y: h * 0.12)
                // 标签带
                Rectangle()
                    .fill(stock.label)
                    .frame(width: w * 0.8, height: h * 0.2)
                    .offset(y: h * 0.42)
                // 盖子
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.85), Color(white: 0.5)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.86, height: h * 0.14)
                    .offset(y: h * 0.06)
                Capsule()
                    .fill(Color(white: 0.7))
                    .frame(width: w * 0.3, height: h * 0.08)
            }
            .frame(width: w, height: h, alignment: .top)
        }
    }
}

// MARK: - 小样渲染

/// 给每个内置滤镜生成小样（只套色彩影调，不加颗粒）
@MainActor
final class PresetThumbnails: ObservableObject {
    @Published var images: [String: UIImage] = [:]
    private var busy = false
    private var rendered = false

    /// 没有取景画面时用的示例图（App 内置）
    static let sample: CIImage? = Bundle.main.url(forResource: "preset_sample", withExtension: "jpg")
        .flatMap { CIImage(contentsOf: $0, options: [.applyOrientationProperty: true]) }

    func render(from frame: CIImage?, force: Bool = false) {
        guard !busy, let frame, force || !rendered else { return }
        busy = true
        if force { images = [:] }
        Task.detached(priority: .userInitiated) {
            let ctx = CIContext()
            let e = frame.extent
            let s = min(1, 300 / max(e.width, e.height))
            let scaled = frame.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            // 取景帧的像素缓冲会被复用，先拷贝出来
            guard let base = ctx.createCGImage(scaled, from: scaled.extent.integral) else {
                await MainActor.run { self.busy = false }
                return
            }
            let small = CIImage(cgImage: base)
            let renderer = StyleRenderer()
            for p in LookPresets.all {
                var g = p.grading
                g.grain = 0; g.grainAddSigma = 0
                let st = StyleRenderer.State(params: g, lut: LUTBuilder.build(g),
                                             skinLut: LUTBuilder.build(g, skinVersion: true), enabled: true)
                let out = renderer.apply(small, state: st)
                if let cg = ctx.createCGImage(out, from: out.extent) {
                    let img = UIImage(cgImage: cg)
                    await MainActor.run { self.images[p.id] = img }
                }
            }
            await MainActor.run { self.busy = false; self.rendered = true }
        }
    }
}
