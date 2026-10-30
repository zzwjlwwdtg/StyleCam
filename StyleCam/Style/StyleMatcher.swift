import Foundation
import CoreImage

/// 画面统计：亮度分布（21 个分位点）、平均彩度、中性色偏
struct SceneStats: Equatable {
    var quantiles: [Double]          // L* 在 1%,5%,10%,…,95%,99% 处的值
    var chroma: Double
    var cast: SIMD2<Double>?
    var chromaRel: Double = 0        // 以中性色偏为原点的平均彩度（去掉整体色偏带来的彩度）
    var median: Double { quantiles.count == 21 ? quantiles[10] : 50 }
}

/// 风格匹配：把“当前画面（未调色）”的统计对齐到参考图，而不是把参考图的绝对数值直接套上去。
/// 这样用参考图本身测试时结果≈不变；拍其他场景时，明暗分布/色彩浓度/色偏向参考图靠拢。
enum StyleMatcher {
    static let probs: [Double] = [0.01] + stride(from: 0.05, through: 0.951, by: 0.05).map { $0 } + [0.99]
    static let grid: [Double] = stride(from: 0.0, through: 100.0, by: 5.0).map { $0 }

    // MARK: - 统计

    static func stats(rgba bytes: [UInt8], width w: Int, height h: Int) -> SceneStats {
        let lut = ColorMath.srgbToLinearLUT
        var Ls: [Double] = []
        Ls.reserveCapacity(w * h)
        var chroma = 0.0
        var nA: [Double] = [], nB: [Double] = []
        var allA: [Double] = [], allB: [Double] = []
        allA.reserveCapacity(w * h); allB.reserveCapacity(w * h)
        for p in 0..<(w * h) {
            let i = p * 4
            let lab = ColorMath.linearRGBToLab(lut[Int(bytes[i])], lut[Int(bytes[i + 1])], lut[Int(bytes[i + 2])])
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            Ls.append(lab.L)
            allA.append(lab.a); allB.append(lab.b)
            chroma += c
            if lab.L > 25, lab.L < 85, c < 22 { nA.append(lab.a); nB.append(lab.b) }
        }
        Ls.sort()
        let n = max(1, Ls.count)
        let cast: SIMD2<Double>? = nA.count > n / 50 ? SIMD2(ColorMath.median(nA), ColorMath.median(nB)) : nil
        let o = cast ?? .zero
        var rel = 0.0
        for i in 0..<allA.count { rel += ((allA[i] - o.x) * (allA[i] - o.x) + (allB[i] - o.y) * (allB[i] - o.y)).squareRoot() }
        return SceneStats(quantiles: probs.map { ColorMath.percentile(Ls, $0) }, chroma: chroma / Double(n), cast: cast,
                          chromaRel: rel / Double(n))
    }

    static func stats(of image: CIImage, context: CIContext, maxSide: CGFloat = 96) -> SceneStats? {
        let e = image.extent
        guard e.width > 0, e.height > 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let s = min(1, maxSide / max(e.width, e.height))
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 8, h > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            context.render(small, toBitmap: b, rowBytes: w * 4,
                           bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                           format: .RGBA8, colorSpace: srgb)
        }
        // 去掉 Lanczos 边缘一圈
        var inner: [UInt8] = []
        inner.reserveCapacity((w - 2) * (h - 2) * 4)
        for y in 1..<(h - 1) { inner.append(contentsOf: buf[(y * w + 1) * 4 ..< (y * w + w - 1) * 4]) }
        return stats(rgba: inner, width: w - 2, height: h - 2)
    }

    // MARK: - 影调曲线：分位点匹配

    /// 返回 21 个值：输入 L* = 0,5,…,100 时的输出 L*
    static func toneCurve(raw: [Double], ref: [Double], strength: Double) -> [Double] {
        // 分位点对（raw → ref），去掉 raw 不递增的点
        var xs: [Double] = [], ys: [Double] = []
        for (x, y) in zip(raw, ref) where xs.isEmpty || x > xs.last! + 0.5 {
            xs.append(x); ys.append(y)
        }
        guard xs.count >= 3 else { return grid }
        func f(_ L: Double) -> Double {
            if L <= xs[0] { return ys[0] + (L - xs[0]) }                    // 两端按斜率 1 延伸
            if L >= xs[xs.count - 1] { return ys[ys.count - 1] + (L - xs[xs.count - 1]) }
            var i = 1
            while xs[i] < L { i += 1 }
            let t = (L - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + t * (ys[i] - ys[i - 1])
        }
        // 黑位/白位（两端）对齐得更充分：中间调 strength，两端最多 +0.35
        var out = grid.map { L -> Double in
            let edge = ColorMath.smoothstep(25, 2, L) + ColorMath.smoothstep(75, 98, L)
            let s = min(1, strength + 0.35 * edge)
            return L + s * (f(L) - L)
        }
        // 单调、斜率限制在 0.4–2.5，两端固定在 0…100 范围内
        out[0] = ColorMath.clamp(out[0], 0, 30)
        for i in 1..<out.count {
            let lo = out[i - 1] + 0.4 * 5, hi = out[i - 1] + 2.5 * 5
            out[i] = ColorMath.clamp(out[i], lo, hi)
        }
        return out.map { ColorMath.clamp($0, 0, 100) }
    }

    static func evalCurve(_ c: [Double], _ L: Double) -> Double {
        let x = ColorMath.clamp(L, 0, 100) / 5
        let i = min(19, Int(x))
        let t = x - Double(i)
        return c[i] + t * (c[i + 1] - c[i])
    }

    // MARK: - 写入调色参数

    static func toneStrength(_ v: StyleVariant) -> Double { v == .soft ? 0.4 : (v == .rich ? 0.8 : 0.6) }

    /// alpha：时间平滑系数（1 = 直接设为目标；实时预览用 0.35 防止闪烁）
    static func apply(to g: inout GradingParams, raw: SceneStats, ref: SceneStats, variant: StyleVariant, alpha: Double) {
        let curve = toneCurve(raw: raw.quantiles, ref: ref.quantiles, strength: toneStrength(variant))
        if let old = g.toneCurve, old.count == curve.count, alpha < 1 {
            g.toneCurve = zip(old, curve).map { $0 + alpha * ($1 - $0) }
        } else {
            g.toneCurve = curve
        }
        // 彩度比用“去掉整体色偏后的彩度”，避免色偏补齐后又把彩度推高
        let rc = ref.chromaRel > 0.5 ? ref.chromaRel : ref.chroma
        let lc = raw.chromaRel > 0.5 ? raw.chromaRel : raw.chroma
        let sat = lc > 0.5 ? ColorMath.clamp(rc * variant.chromaFactor / lc, 0.4, 1.6) : 1
        g.saturation += alpha * (sat - g.saturation)
        if let rc = ref.cast, let lc = raw.cast {
            let t = rc * variant.castFactor - lc
            g.castA += alpha * (ColorMath.clamp(t.x, -12, 12) - g.castA)
            g.castB += alpha * (ColorMath.clamp(t.y, -12, 12) - g.castB)
        }
    }
}
