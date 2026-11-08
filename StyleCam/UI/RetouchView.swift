import SwiftUI
import PhotosUI
import CoreImage
import ImageIO

/// 精修：选一张照片 → 自动中性灰匀肤 / 祛痘 → 点哪里修哪里（点修）→ 另存为新照片（原图不动）
struct RetouchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var source: CIImage?          // 原图（方向已校正）
    @State private var metadata: [String: Any] = [:]
    @State private var skin: CIImage?            // 原图尺寸的皮肤蒙版
    @State private var preview: UIImage?
    @State private var originalPreview: UIImage?
    @State private var even = 0.6
    @State private var blemish = 0.7
    @State private var brush = 0.015            // 点修半径：占长边的比例
    @State private var spots: [CGPoint] = []     // 原图坐标（左下角原点）
    @State private var spotRadii: [CGFloat] = []
    @State private var comparing = false
    @State private var busy = false
    @State private var message: String?
    @State private var renderToken = 0

    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if source == nil {
                    Spacer()
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label("选择一张人像照片", systemImage: "photo.on.rectangle")
                            .font(.headline)
                    }
                    .buttonStyle(.glassProminent)
                    Text("自动做中性灰匀肤和祛痘，再点照片上想去掉的痘痘、斑点或杂物来点修。原图不会被修改。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else {
                    editor
                    controls
                }
            }
            .navigationTitle("精修")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if source != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }.disabled(busy)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: pick) { _, item in load(item) }
        .onChange(of: even) { _, _ in rerender() }
        .onChange(of: blemish) { _, _ in rerender() }
    }

    // MARK: - 编辑区

    private var editor: some View {
        GeometryReader { geo in
            let img = comparing ? (originalPreview ?? preview) : preview
            ZStack {
                if let img {
                    let fit = fitRect(img.size, in: geo.size)
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                    // 已点的位置
                    if !comparing, let src = source {
                        ForEach(spots.indices, id: \.self) { i in
                            let p = viewPoint(spots[i], src.extent, fit)
                            Circle().stroke(.white.opacity(0.7), lineWidth: 1)
                                .frame(width: spotRadii[i] / src.extent.width * fit.width * 2,
                                       height: spotRadii[i] / src.extent.width * fit.width * 2)
                                .position(p)
                        }
                    }
                }
                if busy { ProgressView().tint(.white) }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                guard let src = source, let img = preview else { return }
                let fit = fitRect(img.size, in: geo.size)
                guard fit.contains(v.location) else { return }
                let x = (v.location.x - fit.minX) / fit.width * src.extent.width
                let yTop = (v.location.y - fit.minY) / fit.height * src.extent.height
                spots.append(CGPoint(x: src.extent.minX + x, y: src.extent.maxY - yTop))
                spotRadii.append(max(src.extent.width, src.extent.height) * brush)
                rerender()
            })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.25)
                .onEnded { _ in comparing = true }
                .sequenced(before: DragGesture(minimumDistance: 0).onEnded { _ in comparing = false }))
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.65), in: Capsule()).padding(.bottom, 6)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            row("中性灰", $even, 0...1)
            row("祛痘", $blemish, 0...1)
            row("点修大小", $brush, 0.005...0.05)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("撤销一点") {
                        if !spots.isEmpty { spots.removeLast(); spotRadii.removeLast(); rerender() }
                    }
                    .buttonStyle(.glass).disabled(spots.isEmpty)
                    Button("清除点修") { spots = []; spotRadii = []; rerender() }
                        .buttonStyle(.glass).disabled(spots.isEmpty)
                    PhotosPicker(selection: $pick, matching: .images) { Text("换一张") }
                        .buttonStyle(.glass)
                }
                .font(.footnote)
            }
            Text("点照片去掉痘痘、斑点或杂物；长按照片看原图").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func row(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: v, in: range)
        }
    }

    // MARK: - 坐标换算

    private func fitRect(_ img: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / img.width, box.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func viewPoint(_ p: CGPoint, _ e: CGRect, _ fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + (p.x - e.minX) / e.width * fit.width,
                y: fit.minY + (e.maxY - p.y) / e.height * fit.height)
    }

    // MARK: - 加载 / 渲染 / 保存

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        busy = true
        message = "正在识别皮肤…"
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                busy = false; message = "无法读取这张照片"; return
            }
            let props = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            let flat = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
            let mask = await Task.detached { Retoucher.skinMask(for: flat) }.value
            source = flat
            metadata = props
            skin = mask
            spots = []; spotRadii = []
            originalPreview = Self.render(flat, maxSide: 1600)
            message = mask == nil ? "没有识别到人像：只能用点修" : nil
            busy = false
            rerender()
        }
    }

    /// 按当前参数处理（预览用缩小图，保存用原图）
    private static func process(_ src: CIImage, skin: CIImage?, even: Double, blemish: Double,
                                spots: [CGPoint], radii: [CGFloat]) -> CIImage {
        var out = src
        if let skin, even > 0.01 || blemish > 0.01 {
            let evened = Retoucher.evenSkin(src, skin: skin, even: even, blemish: blemish)
            out = Retoucher.blend(evened, over: src, mask: skin)
        }
        if !spots.isEmpty {
            out = Retoucher.heal(out, spots: Array(zip(spots, radii)).map { (center: $0.0, radius: $0.1) })
        }
        return out
    }

    private static func render(_ img: CIImage, maxSide: CGFloat) -> UIImage? {
        let e = img.extent
        let s = min(1, maxSide / max(e.width, e.height))
        let scaled = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        return ctx.createCGImage(scaled, from: scaled.extent).map { UIImage(cgImage: $0) }
    }

    private func rerender() {
        guard let src = source else { return }
        renderToken += 1
        let token = renderToken
        let (sk, ev, bl, sp, rd) = (skin, even, blemish, spots, spotRadii)
        Task.detached(priority: .userInitiated) {
            // 预览：先缩小到 1600 长边再处理（点修坐标同比例缩放）
            let e = src.extent
            let s = min(1, 1600 / max(e.width, e.height))
            let t = CGAffineTransform(scaleX: s, y: s)
            let small = src.transformed(by: t)
            let smallSkin = sk?.transformed(by: t)
            let out = Self.process(small, skin: smallSkin, even: ev, blemish: bl,
                                   spots: sp.map { $0.applying(t) }, radii: rd.map { $0 * s })
            let ui = Self.ctx.createCGImage(out, from: small.extent).map { UIImage(cgImage: $0) }
            await MainActor.run { if token == renderToken { preview = ui } }
        }
    }

    private func save() {
        guard let src = source else { return }
        busy = true
        message = "正在保存原尺寸照片…"
        let (sk, ev, bl, sp, rd, meta) = (skin, even, blemish, spots, spotRadii, metadata)
        Task.detached(priority: .userInitiated) {
            let out = Self.process(src, skin: sk, even: ev, blemish: bl, spots: sp, radii: rd)
            let summary = String(format: "StyleCam 精修 | 中性灰 %.0f%% · 祛痘 %.0f%% · 点修 %d 处", ev * 100, bl * 100, sp.count)
            PhotoProcessor.saveRendered(out, metadata: meta, summary: summary) { _, err in
                Task { @MainActor in
                    busy = false
                    message = err ?? "已另存为新照片（原图未改动）"
                }
            }
        }
    }
}
