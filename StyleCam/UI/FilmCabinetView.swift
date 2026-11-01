import SwiftUI
import CoreImage
import PhotosUI

/// 胶卷柜：内置的富士 / 佳能同款滤镜。
/// 复古的部分只放在内容里（片盒、拉出来的胶片、片边印字、暖色颗粒底），
/// 操作控件全部用 iOS 27 液态玻璃，保持系统的干净感。
/// 片盒都是原创设计：图案和配色由每个滤镜自己的风格生成，不复刻厂商包装。
struct FilmCabinetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = PresetThumbnails()
    @ObservedObject private var samples = PresetSampleStore.shared
    @State private var brand: PresetBrand?
    @State private var viewer: FrameViewerItem?

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
                    Text("片盒是按每个滤镜的风格生成的原创图案。仿色风格：参数按各胶片模拟 / 照片风格公开的观感特征近似，非厂商官方配置。")
                        .font(.caption2).foregroundStyle(Retro.dim)
                        .padding(.horizontal, 4).padding(.bottom, 90)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .onAppear {
            thumbs.render(live: model.camera.frameStore.latest(original: true))
        }
        .fullScreenCover(item: $viewer) { item in
            FrameViewer(item: item) { viewer = nil }
        }
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

    // MARK: - 品牌筛选（液态玻璃）

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                brandButton(nil, "全部")
                ForEach(PresetBrand.allCases) { brandButton($0, $0.rawValue) }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func brandButton(_ b: PresetBrand?, _ title: String) -> some View {
        if brand == b {
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
        VStack(alignment: .leading, spacing: 14) {
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
            ForEach(items) { p in
                PresetCard(preset: p, thumbs: thumbs, samples: samples,
                           selected: model.currentPreset?.id == p.id,
                           onUse: {
                               Task {
                                   await model.applyPreset(p)
                                   dismiss()
                               }
                           },
                           onOpenFrame: { viewer = $0 })
            }
        }
    }

    // MARK: - 底部：当前使用

    @ViewBuilder
    private var currentBar: some View {
        if let p = model.currentPreset {
            HStack(spacing: 10) {
                CanisterArt(preset: p).frame(width: 20, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("正在使用").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(p.name).font(.system(.footnote, design: .serif).weight(.semibold)).lineLimit(1)
                }
                Spacer()
                Button("不用滤镜") { model.clearReference() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }
}

// MARK: - 一卷胶卷：片盒 + 拉出来的胶片（样片）+ 说明 + 操作

struct PresetCard: View {
    let preset: LookPreset
    @ObservedObject var thumbs: PresetThumbnails
    @ObservedObject var samples: PresetSampleStore
    let selected: Bool
    let onUse: () -> Void
    let onOpenFrame: (FrameViewerItem) -> Void
    @State private var pick: [PhotosPickerItem] = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        let s = preset.stock
        VStack(alignment: .leading, spacing: 12) {
            // 片盒 + 拉出来的胶片
            HStack(alignment: .center, spacing: -6) {
                CanisterArt(preset: preset)
                    .frame(width: 64, height: 104)
                    .zIndex(1)
                PulledFilm(stock: s, frames: frames, onTap: onOpenFrame)
                    .frame(height: 84)
            }

            // 说明
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(s.code)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Retro.amber)
                        .lineLimit(1)
                    Text("· ISO \(s.iso) · \(preset.brand.rawValue)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Retro.dim)
                    Spacer(minLength: 0)
                    if selected {
                        Label("使用中", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Retro.amber)
                    }
                }
                Text(preset.name)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(Retro.paper)
                Text(preset.note)
                    .font(.caption)
                    .foregroundStyle(Retro.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 操作（液态玻璃）
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onUse) {
                        Label(selected ? "使用中" : "用这卷", systemImage: "camera.aperture")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Retro.amber)

                    Menu {
                        ForEach(preset.sampleLinks) { link in
                            Button(link.title) { openURL(link.url) }
                        }
                    } label: {
                        Label("网上样片", systemImage: "safari")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.glass)

                    PhotosPicker(selection: $pick, maxSelectionCount: 6, matching: .images) {
                        Label("添加样片", systemImage: "plus.viewfinder")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(s.color.opacity(selected ? 0.26 : 0.10)), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Retro.amber.opacity(selected ? 0.8 : 0), lineWidth: 1.5))
        .onChange(of: pick) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { samples.add(data, for: preset.id) }
                }
                pick = []
            }
        }
    }

    /// 胶片上的帧：你添加的真实样片在前，后面是用当前取景 / 示例图套这个滤镜的效果
    private var frames: [FilmFrameContent] {
        var f: [FilmFrameContent] = samples.images(for: preset.id).map {
            FilmFrameContent(id: $0.url.absoluteString, image: $0.image, caption: "样片", deletable: $0.url)
        }
        if let live = thumbs.images[preset.id + "|live"] {
            f.append(FilmFrameContent(id: preset.id + "|live", image: live, caption: "取景", deletable: nil))
        }
        if let ex = thumbs.images[preset.id + "|sample"] {
            f.append(FilmFrameContent(id: preset.id + "|sample", image: ex, caption: "示例", deletable: nil))
        }
        return f
    }
}

struct FilmFrameContent: Identifiable {
    let id: String
    let image: UIImage
    let caption: String
    let deletable: URL?      // 用户添加的样片可以删除
}

struct FrameViewerItem: Identifiable {
    let id = UUID()
    let frames: [FilmFrameContent]
    let start: Int
    let title: String
    let onDelete: (URL) -> Void
}

// MARK: - 拉出来的胶片

struct PulledFilm: View {
    let stock: FilmStock
    let frames: [FilmFrameContent]
    let onTap: (FrameViewerItem) -> Void

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let frameH = h - 26
            let frameW = frameH * 1.5
            ZStack(alignment: .leading) {
                // 片基（右端渐隐，像还卷在外面）
                Rectangle()
                    .fill(Retro.filmBase)
                    .overlay(alignment: .top) { perforations(width: g.size.width).padding(.top, 3) }
                    .overlay(alignment: .bottom) { perforations(width: g.size.width).padding(.bottom, 3) }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 6)
                        if frames.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06))
                                    .frame(width: frameW, height: frameH)
                                    .overlay(ProgressView().controlSize(.small).tint(Retro.amber))
                            }
                        }
                        ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                            VStack(spacing: 1) {
                                Image(uiImage: f.image).resizable().scaledToFill()
                                    .frame(width: frameW, height: frameH)
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(f.caption)
                                            .font(.system(size: 7, weight: .semibold))
                                            .padding(.horizontal, 3).padding(.vertical, 1)
                                            .background(.black.opacity(0.45), in: Capsule())
                                            .padding(3)
                                    }
                            }
                            .overlay(alignment: .topLeading) {
                                Text("\(i + 1)A ▸ \(stock.iso)")
                                    .font(.system(size: 5.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Retro.amber.opacity(0.9))
                                    .offset(y: -9)
                            }
                            .onTapGesture {
                                onTap(FrameViewerItem(frames: frames, start: i, title: stock.code, onDelete: { url in
                                    PresetSampleStore.shared.remove(url)
                                }))
                            }
                        }
                        Color.clear.frame(width: 30)
                    }
                    .frame(height: h)
                }
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85),
                                         .init(color: .black.opacity(0.0), location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .bottomLeading) {
                Text(stock.code)
                    .font(.system(size: 5.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Retro.amber.opacity(0.75))
                    .padding(.leading, 18).offset(y: -1)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
    }

    private func perforations(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<Int(width / 11) + 1, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.05, green: 0.04, blue: 0.04))
                    .frame(width: 5, height: 6)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

// MARK: - 片盒（原创图案：按滤镜情绪选纹样，按滤镜调色后的颜色配色）

struct CanisterArt: View {
    let preset: LookPreset

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let capH = max(3, h * 0.085)
            let bodyW = w * 0.86
            ZStack(alignment: .top) {
                // 顶部轴心
                RoundedRectangle(cornerRadius: w * 0.05)
                    .fill(metal)
                    .frame(width: w * 0.28, height: capH * 0.9)
                // 上盖
                cap.frame(width: w * 0.92, height: capH).offset(y: capH * 0.7)
                // 盒身（标签纹样 + 圆柱明暗）
                ZStack {
                    LabelPattern(preset: preset)
                    labelText(w: bodyW, h: h)
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.55), location: 0),
                        .init(color: .black.opacity(0.05), location: 0.22),
                        .init(color: .white.opacity(0.35), location: 0.32),
                        .init(color: .white.opacity(0.0), location: 0.45),
                        .init(color: .black.opacity(0.10), location: 0.75),
                        .init(color: .black.opacity(0.6), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: bodyW, height: h - capH * 3.4)
                .clipShape(Rectangle())
                .offset(y: capH * 1.7)
                // 出片口（绒布唇）
                Rectangle()
                    .fill(Color(red: 0.08, green: 0.06, blue: 0.05))
                    .frame(width: max(2, w * 0.07), height: h * 0.42)
                    .offset(x: bodyW / 2 - w * 0.01, y: h * 0.33)
                // 下盖
                cap.frame(width: w * 0.92, height: capH).offset(y: h - capH * 1.7)
            }
            .frame(width: w, height: h, alignment: .top)
            .shadow(color: .black.opacity(0.5), radius: 4, x: 2, y: 3)
        }
    }

    private var metal: LinearGradient {
        LinearGradient(colors: [Color(white: 0.35), Color(white: 0.92), Color(white: 0.6), Color(white: 0.3)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private var cap: some View {
        ZStack {
            Capsule().fill(metal)
            // 压纹
            HStack(spacing: 2) {
                ForEach(0..<9, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.18)).frame(width: 0.6) }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func labelText(w: CGFloat, h: CGFloat) -> some View {
        if w > 30 {
            // 小标签贴在下半部，让纹样露出来
            let dark = preset.mood == .mono || preset.mood == .cinematic
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Text(preset.labelTitle)
                        .font(.system(size: w * 0.15, weight: .black, design: .serif))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    HStack(spacing: 2) {
                        Text("\(preset.stock.iso)")
                            .font(.system(size: w * 0.15, weight: .black, design: .rounded))
                        Text("36")
                            .font(.system(size: w * 0.08, weight: .bold, design: .monospaced))
                            .baselineOffset(w * 0.05)
                    }
                }
                .foregroundStyle(dark ? Retro.paper : Color(red: 0.12, green: 0.09, blue: 0.07))
                .padding(.vertical, 2).padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .background((dark ? Color.black : Retro.paper).opacity(0.62))
                .padding(.bottom, h * 0.06)
            }
            .overlay(alignment: .top) {
                Text("STYLECAM")
                    .font(.system(size: w * 0.09, weight: .heavy, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle((dark ? Retro.paper : Color.black).opacity(0.55))
                    .padding(.top, h * 0.05)
            }
        }
    }
}

/// 片盒标签纹样：温柔 → 柔光圆斑；复古 → 70 年代彩条；清冷 → 细竖纹；浓郁 → 大色块；电影 → 片孔条；黑白 → 网点
struct LabelPattern: View {
    let preset: LookPreset

    var body: some View {
        let pal = preset.palette
        let mood = preset.mood
        let seed = preset.seed
        Canvas { ctx, size in
            var rng = SplitMix(seed: seed)
            let w = size.width, h = size.height
            let bg = pal[6], ink = pal[5]
            switch mood {
            case .gentle:
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
                for _ in 0..<14 {
                    let r = CGFloat(rng.next(in: 0.15...0.5)) * w
                    let c = CGPoint(x: CGFloat(rng.next(in: -0.1...1.1)) * w, y: CGFloat(rng.next(in: 0...1)) * h)
                    let col = [pal[0], pal[1], pal[4], pal[3]][Int(rng.next(in: 0...3.99))]
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .radialGradient(Gradient(colors: [col.opacity(0.75), col.opacity(0)]),
                                                   center: c, startRadius: 0, endRadius: r))
                }
            case .nostalgic:
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
                let cols = [pal[4], pal[0], pal[3], pal[5]]
                let band = h * 0.075
                for (i, col) in cols.enumerated() {
                    var p = Path()
                    let y0 = h * 0.62 + CGFloat(i) * band
                    p.move(to: CGPoint(x: -w, y: y0 + w * 0.5))
                    p.addLine(to: CGPoint(x: w * 2, y: y0 - w * 0.6))
                    ctx.stroke(p, with: .color(col), lineWidth: band * 0.92)
                }
                // 太阳
                let r = w * 0.32
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.55 - r, y: h * 0.18 - r, width: r * 2, height: r * 2)), with: .color(pal[4].opacity(0.85)))
            case .cool:
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [pal[6], pal[1]]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                var x: CGFloat = 0
                while x < w {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 0.7, height: h)), with: .color(ink.opacity(0.25)))
                    x += CGFloat(rng.next(in: 2.5...5))
                }
                ctx.fill(Path(CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.05)), with: .color(pal[1]))
            case .vivid:
                let cols = [pal[3], pal[4], pal[2], pal[1], pal[0]]
                let n = cols.count
                for (i, col) in cols.enumerated() {
                    ctx.fill(Path(CGRect(x: 0, y: h * CGFloat(i) / CGFloat(n), width: w, height: h / CGFloat(n) + 1)), with: .color(col))
                }
                let r = w * 0.45
                ctx.fill(Path(ellipseIn: CGRect(x: -r * 0.4, y: h * 0.7 - r, width: r * 2, height: r * 2)), with: .color(pal[6].opacity(0.25)))
            case .cinematic:
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pal[5]))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.62, width: w, height: h * 0.2)),
                         with: .linearGradient(Gradient(colors: [pal[1], pal[3], pal[0]]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
                var x: CGFloat = 2
                while x < w {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: h * 0.58, width: 3, height: 3), cornerRadius: 0.6), with: .color(pal[6].opacity(0.7)))
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: h * 0.835, width: 3, height: 3), cornerRadius: 0.6), with: .color(pal[6].opacity(0.7)))
                    x += 6
                }
            case .mono:
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pal[6]))
                let step: CGFloat = 4
                var y: CGFloat = 0
                while y < h {
                    var x: CGFloat = (Int(y / step) % 2 == 0) ? 0 : step / 2
                    while x < w {
                        let t = y / h
                        let r = step * 0.5 * t
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(ink))
                        x += step
                    }
                    y += step
                }
            }
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(in r: ClosedRange<Double>) -> Double {
        r.lowerBound + Double(next() % 1_000_000) / 1_000_000 * (r.upperBound - r.lowerBound)
    }
}

// MARK: - 全屏看样片

struct FrameViewer: View {
    let item: FrameViewerItem
    let close: () -> Void
    @State private var index = 0
    @State private var deleted: Set<String> = []

    var body: some View {
        let frames = item.frames.filter { !deleted.contains($0.id) }
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                    Image(uiImage: f.image).resizable().scaledToFit().tag(i)
                }
            }
            .tabViewStyle(.page)
            HStack {
                Text(item.title).font(.system(.footnote, design: .monospaced)).foregroundStyle(Retro.amber)
                Spacer()
                if frames.indices.contains(index), let url = frames[index].deletable {
                    Button(role: .destructive) {
                        item.onDelete(url)
                        deleted.insert(frames[index].id)
                        if frames.count <= 1 { close() }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.glass)
                }
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass)
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear { index = item.start }
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

// MARK: - 用户添加的样片（每个滤镜各自一组，存在本机）

@MainActor
final class PresetSampleStore: ObservableObject {
    static let shared = PresetSampleStore()
    @Published private(set) var version = 0
    private var cache: [String: [(url: URL, image: UIImage)]] = [:]

    private var root: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PresetSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func images(for id: String) -> [(url: URL, image: UIImage)] {
        _ = version
        if let c = cache[id] { return c }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let list = files.compactMap { u in UIImage(contentsOfFile: u.path).map { (url: u, image: $0) } }
        cache[id] = list
        return list
    }

    func add(_ data: Data, for id: String) {
        guard let img = UIImage(data: data),
              let small = img.preparingThumbnail(of: Self.fit(img.size, 900)),
              let jpg = small.jpegData(compressionQuality: 0.85) else { return }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6)).jpg"
        try? jpg.write(to: dir.appendingPathComponent(name))
        cache[id] = nil
        version += 1
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        invalidate()
    }

    func invalidate() {
        cache = [:]
        version += 1
    }

    private static func fit(_ s: CGSize, _ m: CGFloat) -> CGSize {
        let k = min(1, m / max(s.width, s.height))
        return CGSize(width: s.width * k, height: s.height * k)
    }
}

// MARK: - 小样渲染

/// 给每个内置滤镜生成小样：当前取景画面一张、内置示例图一张（只套色彩影调，不加颗粒）
@MainActor
final class PresetThumbnails: ObservableObject {
    @Published var images: [String: UIImage] = [:]
    private var busy = false

    /// 没有取景画面时用的示例图（App 内置）
    nonisolated static let sample: CIImage? = Bundle.main.url(forResource: "preset_sample", withExtension: "jpg")
        .flatMap { CIImage(contentsOf: $0, options: [.applyOrientationProperty: true]) }

    func render(live: CIImage?) {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let ctx = CIContext()
            var sources: [(String, CIImage)] = []
            if let s = Self.sample { sources.append(("sample", s)) }
            if let live { sources.insert(("live", live), at: 0) }
            let renderer = StyleRenderer()
            for (tag, frame) in sources {
                let e = frame.extent
                let s = min(1, 360 / max(e.width, e.height))
                let scaled = frame.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                // 取景帧的像素缓冲会被复用，先拷贝出来
                guard let base = ctx.createCGImage(scaled, from: scaled.extent.integral) else { continue }
                let small = CIImage(cgImage: base)
                for p in LookPresets.all {
                    var g = p.grading
                    g.grain = 0; g.grainAddSigma = 0
                    let st = StyleRenderer.State(params: g, lut: LUTBuilder.build(g),
                                                 skinLut: LUTBuilder.build(g, skinVersion: true), enabled: true)
                    let out = renderer.apply(small, state: st)
                    if let cg = ctx.createCGImage(out, from: out.extent) {
                        let img = UIImage(cgImage: cg)
                        await MainActor.run { self.images[p.id + "|" + tag] = img }
                    }
                }
            }
            await MainActor.run { self.busy = false }
        }
    }
}
