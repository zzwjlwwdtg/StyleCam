import SwiftUI
import CoreImage
import PhotosUI

/// 胶卷柜：内置的富士 / 佳能同款滤镜。
/// 结构：上半屏是当前这卷（片盒 + 拉出来的胶片 = 样片），下半屏是按情绪分组的胶卷货架。
/// 颜色跟着胶卷走：背景和主按钮取自当前胶卷的配色；控件用 iOS 27 液态玻璃。
/// 片盒都是原创设计：图案和配色由每个滤镜自己的风格生成，不复刻厂商包装。
struct FilmCabinetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = PresetThumbnails()
    @ObservedObject private var samples = PresetSampleStore.shared
    @State private var mood: PresetMood = .gentle
    @State private var brand: PresetBrand?
    @State private var focusedID: String = LookPresets.all[0].id
    @State private var pullOut: CGFloat = 1          // 胶片拉出的进度（换胶卷时从 0 动画到 1）
    @State private var viewer: FrameViewerItem?
    @State private var pick: [PhotosPickerItem] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focused: LookPreset { LookPresets.preset(id: focusedID) ?? LookPresets.all[0] }
    private var shelf: [LookPreset] { LookPresets.all.filter { $0.mood == mood && (brand == nil || $0.brand == brand) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .padding(.top, 4)
                    details
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    shelfSection
                        .padding(.top, 30)
                    Text("片盒为按风格生成的原创图案。滤镜参数按各胶片模拟与照片风格的公开观感近似，并非厂商官方配置。")
                        .font(.footnote)
                        .foregroundStyle(Palette.mist)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 110)
                }
            }
            .scrollIndicators(.hidden)
            .background(CabinetBackground(tint: focused.packaging.primary))
            .safeAreaInset(edge: .bottom) { actionBar }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("胶卷柜").font(.system(.headline, design: .serif))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .onAppear {
            if let cur = model.currentPreset {
                focusedID = cur.id
                mood = cur.mood
            }
            thumbs.render(live: model.camera.frameStore.latest(original: true))
        }
        .onChange(of: pick) { _, items in
            guard !items.isEmpty else { return }
            let id = focusedID
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { samples.add(data, for: id) }
                }
                pick = []
            }
        }
        .fullScreenCover(item: $viewer) { item in
            FrameViewer(item: item) { viewer = nil }
        }
    }

    private func focus(_ p: LookPreset) {
        guard p.id != focusedID else { return }
        focusedID = p.id
        if reduceMotion { pullOut = 1; return }
        pullOut = 0
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { pullOut = 1 }
    }

    // MARK: - 主角：片盒 + 拉出来的胶片

    private var hero: some View {
        let p = focused
        return ZStack(alignment: .leading) {
            FilmStrip(stock: p.stock, frames: frames(for: p), progress: pullOut) { i, frames in
                viewer = FrameViewerItem(frames: frames, start: i, title: p.name) { PresetSampleStore.shared.remove($0) }
            }
            .frame(height: 236)
            .padding(.leading, 52)
            CanisterArt(preset: p)
                .frame(width: 92, height: 150)
                .padding(.leading, 8)
                .id(p.id)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: focusedID)
    }

    /// 胶片上的帧：你添加的真实样片在前，后面是当前取景 / 示例图套这个滤镜的效果
    private func frames(for p: LookPreset) -> [FilmFrameContent] {
        var f: [FilmFrameContent] = samples.images(for: p.id).map {
            FilmFrameContent(id: $0.url.absoluteString, image: $0.image, caption: "我的样片", deletable: $0.url)
        }
        if let live = thumbs.images[p.id + "|live"] {
            f.append(FilmFrameContent(id: p.id + "|live", image: live, caption: "当前取景", deletable: nil))
        }
        if let ex = thumbs.images[p.id + "|sample"] {
            f.append(FilmFrameContent(id: p.id + "|sample", image: ex, caption: "示例", deletable: nil))
        }
        return f
    }

    // MARK: - 说明

    private var details: some View {
        let p = focused
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(p.brand.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(p.packaging.paper)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(p.packaging.primary.opacity(0.55), in: Capsule())
                Text("ISO \(p.stock.iso)")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Palette.mist)
                Spacer()
                if model.currentPreset?.id == p.id {
                    Label("正在使用", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.fog)
                }
            }
            Text(p.name)
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(Palette.fog)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Text(p.note)
                .font(.callout)
                .lineSpacing(3)
                .foregroundStyle(Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(p.sampleLinks) { link in
                            Button(link.title) { openURL(link.url) }
                        }
                    } label: {
                        Label("网上样片", systemImage: "safari").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.glass)
                    PhotosPicker(selection: $pick, maxSelectionCount: 6, matching: .images) {
                        Label("添加样片", systemImage: "plus").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.top, 4)
        }
        .animation(.easeOut(duration: 0.2), value: focusedID)
    }

    // MARK: - 胶卷货架

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("按心情挑一卷")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(Palette.fog)
                Spacer()
                Menu {
                    Picker("品牌", selection: $brand) {
                        Text("全部品牌").tag(PresetBrand?.none)
                        ForEach(PresetBrand.allCases) { Text($0.rawValue).tag(PresetBrand?.some($0)) }
                    }
                } label: {
                    Label(brand?.rawValue ?? "全部品牌", systemImage: "line.3.horizontal.decrease")
                        .font(.footnote.weight(.medium)).lineLimit(1).fixedSize()
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(PresetMood.allCases) { m in
                            let n = LookPresets.all.filter { $0.mood == m && (brand == nil || $0.brand == brand) }.count
                            if m == mood {
                                Button(m.rawValue) { mood = m }
                                    .buttonStyle(.glassProminent)
                                    .tint(focused.packaging.primary)
                            } else {
                                Button(m.rawValue) {
                                    withAnimation(.snappy) { mood = m }
                                }
                                .buttonStyle(.glass)
                                .disabled(n == 0)
                            }
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 20)
                }
            }
            .scrollIndicators(.hidden)

            ShelfRow(items: shelf, focusedID: focusedID, currentID: model.currentPreset?.id) { focus($0) }
        }
        .onChange(of: mood) { _, _ in if let first = shelf.first { focus(first) } }
        .onChange(of: brand) { _, _ in if !shelf.contains(where: { $0.id == focusedID }), let first = shelf.first { focus(first) } }
    }

    // MARK: - 底部操作

    private var actionBar: some View {
        let p = focused
        let using = model.currentPreset?.id == p.id
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if model.currentPreset != nil {
                    Button("不用滤镜") { model.clearReference() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
                Button {
                    Task {
                        await model.applyPreset(p)
                        dismiss()
                    }
                } label: {
                    Text(using ? "继续用这卷拍" : "用这卷拍")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(p.packaging.primary)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}

// MARK: - 货架：片盒立在木隔板上，选中的那卷抬起来

struct ShelfRow: View {
    let items: [LookPreset]
    let focusedID: String
    let currentID: String?
    let onSelect: (LookPreset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(items) { p in
                        let on = p.id == focusedID
                        Button { onSelect(p) } label: {
                            VStack(spacing: 8) {
                                CanisterArt(preset: p)
                                    .frame(width: 62, height: 100)
                                    .offset(y: on ? -10 : 0)
                                    .shadow(color: p.packaging.primary.opacity(on ? 0.55 : 0), radius: 14, y: 6)
                                HStack(spacing: 3) {
                                    if currentID == p.id {
                                        Circle().fill(Palette.fog).frame(width: 5, height: 5)
                                    }
                                    Text(p.labelTitle)
                                        .font(.footnote.weight(on ? .semibold : .regular))
                                        .foregroundStyle(on ? Palette.fog : Palette.mist)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 76)
                            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: on)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(p.name)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            // 隔板
            ZStack(alignment: .top) {
                LinearGradient(colors: [Palette.shelfTop, Palette.shelf], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            }
            .frame(height: 12)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 6)
        }
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

// MARK: - 从片盒里拉出来的胶片（大样片，可左右滑）

struct FilmStrip: View {
    let stock: FilmStock
    let frames: [FilmFrameContent]
    let progress: CGFloat
    let onTap: (Int, [FilmFrameContent]) -> Void

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let frameH = h - 44
            let frameW = frameH * 1.5
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Palette.filmBase)
                VStack {
                    perforations(width: g.size.width)
                    Spacer()
                    perforations(width: g.size.width)
                }
                .padding(.vertical, 6)

                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        if frames.isEmpty {
                            ForEach(0..<2, id: \.self) { _ in
                                Rectangle().fill(Color.white.opacity(0.05))
                                    .frame(width: frameW, height: frameH)
                                    .overlay(ProgressView().tint(Palette.mist))
                            }
                        }
                        ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                            Image(uiImage: f.image).resizable().scaledToFill()
                                .frame(width: frameW, height: frameH)
                                .clipped()
                                .overlay(alignment: .bottomLeading) {
                                    Text(f.caption)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .glassEffect(.regular, in: Capsule())
                                        .padding(8)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(i, frames) }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.leading, 56)
                    .padding(.trailing, 40)
                    .frame(height: h)
                }
                .scrollIndicators(.hidden)

                // 片边印字（胶片本身的元素，跟着胶片走）
                Text("\(stock.code)  \(stock.iso)")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.edgePrint)
                    .padding(.leading, 64)
                    .offset(y: h - 17)
                    .allowsHitTesting(false)
            }
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 36)
                }
            )
            // 拉出动画：从片盒口往右展开
            .mask(alignment: .leading) {
                Rectangle().frame(width: max(1, g.size.width * progress))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
    }

    private func perforations(width: CGFloat) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<Int(width / 13) + 1, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(Palette.hole)
                    .frame(width: 6, height: 8)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

// MARK: - 片盒：StyleCam 自有包装（相机图标 + 色块），配色全部来自滤镜本身

struct CanisterArt: View {
    let preset: LookPreset

    var body: some View {
        let pk = preset.packaging
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let capH = max(3, h * 0.085)
            let bodyW = w * 0.86
            let bodyH = h - capH * 3.4
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.05).fill(metal)
                    .frame(width: w * 0.28, height: capH * 0.9)
                cap.frame(width: w * 0.92, height: capH).offset(y: capH * 0.7)
                ZStack {
                    PackagingBlocks(preset: preset, pk: pk)
                    if w > 30 { label(pk: pk, w: bodyW, h: bodyH) }
                    // 圆柱明暗
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.5), location: 0),
                        .init(color: .black.opacity(0.04), location: 0.2),
                        .init(color: .white.opacity(0.32), location: 0.3),
                        .init(color: .white.opacity(0.0), location: 0.44),
                        .init(color: .black.opacity(0.08), location: 0.75),
                        .init(color: .black.opacity(0.55), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: bodyW, height: bodyH)
                .clipShape(Rectangle())
                .offset(y: capH * 1.7)
                Rectangle()
                    .fill(Color(red: 0.08, green: 0.06, blue: 0.05))
                    .frame(width: max(2, w * 0.07), height: h * 0.42)
                    .offset(x: bodyW / 2 - w * 0.01, y: h * 0.33)
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
            HStack(spacing: 2) {
                ForEach(0..<9, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.18)).frame(width: 0.6) }
            }
            .padding(.horizontal, 4)
        }
    }

    /// 统一的标签版式：顶部相机图标 + 字标，下部 ISO 大数字 + 名称
    private func label(pk: Packaging, w: CGFloat, h: CGFloat) -> some View {
        let onDark = pk.darkBody
        let ink = onDark ? pk.paper : pk.ink
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: w * 0.05) {
                CameraGlyph().stroke(ink, style: StrokeStyle(lineWidth: max(0.8, w * 0.025), lineJoin: .round))
                    .frame(width: w * 0.2, height: w * 0.15)
                Text("StyleCam")
                    .font(.system(size: w * 0.12, weight: .bold, design: .serif).italic())
                    .foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .padding(.top, h * 0.06)
            Text("\(preset.stock.iso)")
                .font(.system(size: w * 0.3, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .minimumScaleFactor(0.5)
                .padding(.top, h * 0.02)
            Text(preset.labelTitle)
                .font(.system(size: w * 0.13, weight: .semibold))
                .foregroundStyle(ink.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
        }
        .padding(.leading, w * 0.1)
        .frame(width: w, height: h, alignment: .leading)
    }
}

/// 原创相机图标：机身 + 取景器凸起 + 镜头
struct CameraGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let body = CGRect(x: r.minX, y: r.minY + r.height * 0.22, width: r.width, height: r.height * 0.78)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: r.width * 0.12, height: r.width * 0.12))
        p.addRoundedRect(in: CGRect(x: r.minX + r.width * 0.12, y: r.minY, width: r.width * 0.28, height: r.height * 0.24),
                         cornerSize: CGSize(width: r.width * 0.04, height: r.width * 0.04))
        let d = min(body.width, body.height) * 0.62
        p.addEllipse(in: CGRect(x: body.midX - d / 2 + r.width * 0.06, y: body.midY - d / 2, width: d, height: d))
        p.addEllipse(in: CGRect(x: body.maxX - r.width * 0.2, y: body.minY + body.height * 0.18,
                                width: r.width * 0.08, height: r.width * 0.08))
        return p
    }
}

/// 色块：同一套版式语言，几何按情绪变化（温柔 = 圆弧，复古 = 三条横带，清冷 = 竖分割，浓郁 = 斜切大块，电影 = 深底窄条，黑白 = 上下对半）
struct PackagingBlocks: View {
    let preset: LookPreset
    let pk: Packaging

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let all = Path(CGRect(origin: .zero, size: size))
            // 上半部分留给标签（纸色 / 电影款为深色），色块都在下半部分
            switch preset.mood {
            case .gentle:
                ctx.fill(all, with: .color(pk.paper))
                var arc = Path()
                arc.move(to: CGPoint(x: 0, y: h * 0.72))
                arc.addQuadCurve(to: CGPoint(x: w, y: h * 0.6), control: CGPoint(x: w * 0.5, y: h * 0.46))
                arc.addLine(to: CGPoint(x: w, y: h)); arc.addLine(to: CGPoint(x: 0, y: h)); arc.closeSubpath()
                ctx.fill(arc, with: .color(pk.primary))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.9, width: w, height: h * 0.1)), with: .color(pk.secondary))
            case .nostalgic:
                ctx.fill(all, with: .color(pk.paper))
                let top = h * 0.6, band = h * 0.4 / 3
                ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: band + 1)), with: .color(pk.primary))
                ctx.fill(Path(CGRect(x: 0, y: top + band, width: w, height: band + 1)), with: .color(pk.secondary))
                ctx.fill(Path(CGRect(x: 0, y: top + band * 2, width: w, height: band)), with: .color(pk.ink.opacity(0.85)))
            case .cool:
                ctx.fill(all, with: .color(pk.paper))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.6, width: w, height: h * 0.4)), with: .color(pk.primary))
                ctx.fill(Path(CGRect(x: w * 0.62, y: h * 0.6, width: w * 0.38, height: h * 0.4)), with: .color(pk.secondary))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.58, width: w, height: h * 0.012)), with: .color(pk.ink.opacity(0.6)))
            case .vivid:
                ctx.fill(all, with: .color(pk.paper))
                var blk = Path()
                blk.move(to: CGPoint(x: 0, y: h * 0.62)); blk.addLine(to: CGPoint(x: w, y: h * 0.56))
                blk.addLine(to: CGPoint(x: w, y: h)); blk.addLine(to: CGPoint(x: 0, y: h)); blk.closeSubpath()
                ctx.fill(blk, with: .color(pk.primary))
                var tri = Path()
                tri.move(to: CGPoint(x: 0, y: h)); tri.addLine(to: CGPoint(x: w, y: h * 0.74)); tri.addLine(to: CGPoint(x: w, y: h)); tri.closeSubpath()
                ctx.fill(tri, with: .color(pk.secondary))
            case .cinematic:
                ctx.fill(all, with: .color(pk.ink))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.66, width: w, height: h * 0.14)), with: .color(pk.primary))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.8, width: w, height: h * 0.04)), with: .color(pk.secondary))
            case .mono:
                ctx.fill(all, with: .color(pk.paper))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.62, width: w, height: h * 0.38)), with: .color(pk.ink))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.58, width: w, height: h * 0.04)), with: .color(pk.secondary))
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
                Text(item.title).font(.system(.footnote, design: .serif)).foregroundStyle(Palette.fog)
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

// MARK: - 色板与背景

enum Palette {
    static let graphite = Color(red: 0x22 / 255, green: 0x25 / 255, blue: 0x29 / 255)   // 底色
    static let fog = Color(red: 0xEC / 255, green: 0xE9 / 255, blue: 0xE3 / 255)        // 主文字
    static let mist = Color(red: 0xEC / 255, green: 0xE9 / 255, blue: 0xE3 / 255).opacity(0.62)
    static let shelf = Color(red: 0x4A / 255, green: 0x3A / 255, blue: 0x2C / 255)      // 木隔板
    static let shelfTop = Color(red: 0x6E / 255, green: 0x58 / 255, blue: 0x44 / 255)
    static let filmBase = Color(red: 0x2B / 255, green: 0x1D / 255, blue: 0x14 / 255)   // 负片片基（偏橙棕）
    static let hole = Color(red: 0x14 / 255, green: 0x10 / 255, blue: 0x0D / 255)
    static let edgePrint = Color(red: 0xE8 / 255, green: 0x9A / 255, blue: 0x4C / 255)  // 片边印字
}

/// 底色 + 当前胶卷的颜色从上方晕开 + 极淡的颗粒
struct CabinetBackground: View {
    let tint: Color

    private static let grain: UIImage = {
        let n = 96
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 12345
        for i in 0..<(n * n) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = UInt8(truncatingIfNeeded: seed >> 24)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage().map { UIImage(cgImage: $0) } ?? UIImage()
    }()

    var body: some View {
        ZStack {
            Palette.graphite
            RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.0)], center: UnitPoint(x: 0.3, y: 0.0),
                           startRadius: 0, endRadius: 520)
            Image(uiImage: Self.grain).resizable(resizingMode: .tile)
                .blendMode(.overlay).opacity(0.06)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: tint)
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
