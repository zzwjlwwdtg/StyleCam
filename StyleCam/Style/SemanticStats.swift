import Foundation
import CoreImage
import Vision

/// 语义追色：把画面分成 皮肤 / 人物其余部分（衣服、头发）/ 背景 三块，各自统计亮度和颜色。
/// 追色时整体先对齐（StyleMatcher），再让每一块“相对整体”的差异也向参考图靠拢——
/// 即“人物追人物、衣服追衣服、背景追背景”。
struct SemanticStats: Equatable {
    struct Region: Equatable {
        var L: Double        // L* 中位数
        var a: Double        // a* 中位数
        var b: Double        // b* 中位数
        var chroma: Double   // 平均彩度
        var share: Double    // 占画面比例
    }
    var all: Region
    var skin: Region?
    var person: Region?
    var background: Region?

    /// 用图像和人像蒙版统计（都缩到约 192 像素长边，在 CPU 上算）
    static func measure(_ image: CIImage, person: CIImage, context: CIContext) -> SemanticStats? {
        let e = image.extent
        guard e.width > 8, e.height > 8, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let s = 192 / max(e.width, e.height)
        let w = max(8, Int(e.width * s)), h = max(8, Int(e.height * s))
        func render(_ img: CIImage) -> [UInt8] {
            let small = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                context.render(small, toBitmap: p.baseAddress!, rowBytes: w * 4,
                               bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: srgb)
            }
            return buf
        }
        let px = render(image)
        let mk = render(person.cropped(to: e))
        let lut = ColorMath.srgbToLinearLUT
        var acc: [[(Double, Double, Double, Double)]] = [[], [], [], []]   // 全部 / 皮肤 / 人物 / 背景
        for i in 0..<(w * h) {
            let o = i * 4
            let lab = ColorMath.linearRGBToLab(lut[Int(px[o])], lut[Int(px[o + 1])], lut[Int(px[o + 2])])
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            let v = (lab.L, lab.a, lab.b, c)
            acc[0].append(v)
            let m = Double(mk[o]) / 255
            if m > 0.6 {
                if skinLikelihood(lab.L, lab.a, lab.b) > 0.5 { acc[1].append(v) } else { acc[2].append(v) }
            } else if m < 0.15 {
                acc[3].append(v)
            }
        }
        let n = Double(w * h)
        func region(_ v: [(Double, Double, Double, Double)]) -> Region? {
            guard v.count >= 40, Double(v.count) > n * 0.006 else { return nil }
            return Region(L: ColorMath.median(v.map(\.0)), a: ColorMath.median(v.map(\.1)), b: ColorMath.median(v.map(\.2)),
                          chroma: v.map(\.3).reduce(0, +) / Double(v.count), share: Double(v.count) / n)
        }
        guard let all = region(acc[0]) else { return nil }
        let st = SemanticStats(all: all, skin: region(acc[1]), person: region(acc[2]), background: region(acc[3]))
        return (st.skin == nil && st.person == nil) ? nil : st
    }

    /// 和 LUTBuilder.skinLikelihood 相同的判定
    static func skinLikelihood(_ L: Double, _ a: Double, _ b: Double) -> Double {
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        let wh = ColorMath.smoothstep(8, 25, h) * ColorMath.smoothstep(85, 65, h)
        let wc = ColorMath.smoothstep(5, 10, c) * ColorMath.smoothstep(55, 45, c)
        let wl = ColorMath.smoothstep(15, 25, L) * ColorMath.smoothstep(97, 90, L)
        return wh * wc * wl
    }

    /// 人像蒙版（拍照 / 套用相册 / 精修时用，高质量）
    static func personMask(for image: CIImage) -> CIImage? {
        let h = VNImageRequestHandler(ciImage: image, options: [:])
        guard let pb = SubjectMasker.personMask(h, quality: .accurate) else { return nil }
        return SubjectMasker.ciMask(pb, fitting: image.extent)
    }

    // MARK: - 每块相对整体的差值 → 调整量

    /// 参考图里“这一块相对整体”的偏差，减去当前画面里同样的偏差 = 这一块还要补的量
    static func residual(raw: Region?, rawAll: Region, ref: Region?, refAll: Region, strength: Double) -> RegionAdjust? {
        guard let raw, let ref, strength > 0 else { return nil }
        let dL = ((ref.L - refAll.L) - (raw.L - rawAll.L)) * strength
        let da = ((ref.a - refAll.a) - (raw.a - rawAll.a)) * strength
        let db = ((ref.b - refAll.b) - (raw.b - rawAll.b)) * strength
        let relRef = ref.chroma / max(1, refAll.chroma), relRaw = raw.chroma / max(1, rawAll.chroma)
        let sat = 1 + (relRef / max(0.2, relRaw) - 1) * strength
        let adj = RegionAdjust(dL: ColorMath.clamp(dL, -12, 12),
                               tint: SIMD2(ColorMath.clamp(da, -10, 10), ColorMath.clamp(db, -10, 10)),
                               sat: ColorMath.clamp(sat, 0.6, 1.5))
        return adj.isNeutral ? nil : adj
    }

    /// 写入调色参数（alpha：时间平滑）
    static func apply(to g: inout GradingParams, raw: SemanticStats, ref: SemanticStats, variant: StyleVariant, alpha: Double) {
        let k = variant == .soft ? 0.5 : (variant == .rich ? 1.0 : 0.8)
        func mix(_ old: RegionAdjust?, _ new: RegionAdjust?) -> RegionAdjust? {
            guard let new else { return old.flatMap { o in
                let m = RegionAdjust(dL: o.dL * (1 - alpha), tint: o.tint * (1 - alpha), sat: 1 + (o.sat - 1) * (1 - alpha))
                return m.isNeutral ? nil : m
            } }
            guard let old, alpha < 1 else { return new }
            return RegionAdjust(dL: old.dL + alpha * (new.dL - old.dL), tint: old.tint + alpha * (new.tint - old.tint),
                                sat: old.sat + alpha * (new.sat - old.sat))
        }
        g.regionSkin = mix(g.regionSkin, residual(raw: raw.skin, rawAll: raw.all, ref: ref.skin, refAll: ref.all, strength: k))
        g.regionPerson = mix(g.regionPerson, residual(raw: raw.person, rawAll: raw.all, ref: ref.person, refAll: ref.all, strength: k))
        g.regionBG = mix(g.regionBG, residual(raw: raw.background, rawAll: raw.all, ref: ref.background, refAll: ref.all, strength: k))
    }
}
