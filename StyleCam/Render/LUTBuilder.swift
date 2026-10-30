import Foundation

/// 把调色参数“烘焙”成 33³ 的 3D LUT，交给 GPU（CIColorCubeWithColorSpace）实时套用。
/// 所有色彩运算都在感知均匀的 Lab 空间完成：曲线作用于 L*，饱和度/色偏/分离色调作用于 a*b*。
enum LUTBuilder {
    static let dimension = 33

    /// skinVersion = true：给肤色用的版本，保留影调（曲线/黑白位），但不加色偏、分离色调、分区调色，饱和度只改 30%
    static func build(_ p: GradingParams, skinVersion: Bool = false) -> Data {
        var p = p
        if skinVersion {
            if !p.monochrome { p.castA = 0; p.castB = 0 }
            p.shadowTint = .zero; p.highlightTint = .zero
            p.greenTarget = nil; p.skyTarget = nil
            p.saturation = 1 + (p.saturation - 1) * 0.3
        }
        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)

        let exposure = pow(2.0, p.exposureEV)
        let k = ColorMath.clamp(p.contrast, -1, 1) * 0.8          // S 曲线强度
        let lift = p.shadowLift * 0.18                             // 黑位提升量
        let roll = p.highlightRolloff * 0.15                       // 白位压低量
        let strength = ColorMath.clamp(p.strength, 0, 1)
        let twoPi = 2 * Double.pi

        var idx = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let sr = Double(ri) / Double(n - 1)
                    let sg = Double(gi) / Double(n - 1)
                    let sb = Double(bi) / Double(n - 1)

                    let lr = ColorMath.srgbToLinear(sr) * exposure
                    let lg = ColorMath.srgbToLinear(sg) * exposure
                    let lb = ColorMath.srgbToLinear(sb) * exposure
                    let lab = ColorMath.linearRGBToLab(lr, lg, lb)

                    // 影调：S 曲线 + 黑白位
                    // 影调匹配曲线（分位点对齐参考图），之后再叠加版本带来的对比/褪色
                    let matchedL = p.toneCurve.map { StyleMatcher.evalCurve($0, lab.L) } ?? lab.L
                    var t = ColorMath.clamp(matchedL / 100, 0, 1)
                    let tOrig = t
                    t = t - k * sin(twoPi * t) / twoPi
                    t = lift + t * (1 - lift - roll)
                    var L = t * 100

                    // 色彩：饱和度 + 整体色偏 + 分离色调
                    let ws = ColorMath.smoothstep(0.6, 0.0, tOrig)
                    let wh = ColorMath.smoothstep(0.4, 1.0, tOrig)
                    // 分区调色：植物 / 天空的色相与彩度向参考图同类颜色靠拢
                    var (ra, rb) = regionPull(lab.a, lab.b, p)
                    // 按色相分别调整（内置滤镜）
                    if !p.hsl.isEmpty { (ra, rb, L) = hslAdjust(ra, rb, L, p.hsl) }
                    var a = ra * p.saturation + p.castA + p.shadowTint.x * ws + p.highlightTint.x * wh
                    var b = rb * p.saturation + p.castB + p.shadowTint.y * ws + p.highlightTint.y * wh
                    if p.monochrome {
                        // 黑白：去掉颜色，castA/castB 作为整体染色（如暖调黑白）
                        a = p.castA; b = p.castB
                    }

                    let out = ColorMath.labToLinearRGB(L, a, b)
                    var orr = ColorMath.clamp(ColorMath.linearToSRGB(out.r), 0, 1)
                    var og = ColorMath.clamp(ColorMath.linearToSRGB(out.g), 0, 1)
                    var ob = ColorMath.clamp(ColorMath.linearToSRGB(out.b), 0, 1)

                    // 风格强度：与原图混合
                    orr = sr + (orr - sr) * strength
                    og = sg + (og - sg) * strength
                    ob = sb + (ob - sb) * strength

                    cube[idx] = Float(orr)
                    cube[idx + 1] = Float(og)
                    cube[idx + 2] = Float(ob)
                    cube[idx + 3] = 1
                    idx += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - 分区调色

    private static func hueDeg(_ a: Double, _ b: Double) -> Double {
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return h
    }

    private static func angleDiff(_ to: Double, _ from: Double) -> Double {
        var d = to - from
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private static func regionPull(_ a: Double, _ b: Double, _ p: GradingParams) -> (Double, Double) {
        let c = (a * a + b * b).squareRoot()
        guard c > 3, p.regionStrength > 0 else { return (a, b) }
        var h = hueDeg(a, b), nc = c
        for (target, center, width) in [(p.greenTarget, 135.0, 45.0), (p.skyTarget, 255.0, 40.0)] {
            guard let t = target else { continue }
            let d = abs(angleDiff(h, center))
            let w = ColorMath.smoothstep(width, width * 0.4, d) * ColorMath.smoothstep(4, 12, c) * p.regionStrength
            guard w > 0 else { continue }
            let th = hueDeg(t.x, t.y), tc = (t.x * t.x + t.y * t.y).squareRoot()
            h += w * angleDiff(th, h)
            nc += w * 0.5 * (tc - nc)
        }
        let r = h * .pi / 180
        return (nc * cos(r), nc * sin(r))
    }

    private static func hslAdjust(_ a: Double, _ b: Double, _ L: Double, _ bands: [HSLBand]) -> (Double, Double, Double) {
        let c = (a * a + b * b).squareRoot()
        guard c > 2 else { return (a, b, L) }
        var h = hueDeg(a, b), nc = c, nl = L
        let chromaW = ColorMath.smoothstep(2, 10, c)
        for band in bands {
            let d = abs(angleDiff(h, band.hue))
            let w = ColorMath.smoothstep(band.width, band.width * 0.3, d) * chromaW
            guard w > 0 else { continue }
            h += w * band.dHue
            nc *= 1 + w * (band.sat - 1)
            nl += w * band.dL
        }
        let r = h * .pi / 180
        return (nc * cos(r), nc * sin(r), ColorMath.clamp(nl, 0, 100))
    }

    // MARK: - 肤色可能性（输出灰度：白 = 肤色）

    static let skinLikelihood: Data = {
        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var idx = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let lab = ColorMath.linearRGBToLab(ColorMath.srgbToLinear(Double(ri) / Double(n - 1)),
                                                       ColorMath.srgbToLinear(Double(gi) / Double(n - 1)),
                                                       ColorMath.srgbToLinear(Double(bi) / Double(n - 1)))
                    let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
                    let h = hueDeg(lab.a, lab.b)
                    // 肤色：色相约 20°–75°（橙红~黄），彩度 8–50，亮度 20–92
                    let wh = ColorMath.smoothstep(8, 25, h) * ColorMath.smoothstep(85, 65, h)
                    let wc = ColorMath.smoothstep(5, 10, c) * ColorMath.smoothstep(55, 45, c)
                    let wl = ColorMath.smoothstep(15, 25, lab.L) * ColorMath.smoothstep(97, 90, lab.L)
                    let v = Float(wh * wc * wl)
                    cube[idx] = v; cube[idx + 1] = v; cube[idx + 2] = v; cube[idx + 3] = 1
                    idx += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}
