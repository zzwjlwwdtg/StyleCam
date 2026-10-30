import Foundation

/// 把调色参数“烘焙”成 33³ 的 3D LUT，交给 GPU（CIColorCubeWithColorSpace）实时套用。
/// 所有色彩运算都在感知均匀的 Lab 空间完成：曲线作用于 L*，饱和度/色偏/分离色调作用于 a*b*。
enum LUTBuilder {
    static let dimension = 33

    static func build(_ p: GradingParams) -> Data {
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
                    var t = ColorMath.clamp(lab.L / 100, 0, 1)
                    let tOrig = t
                    t = t - k * sin(twoPi * t) / twoPi
                    t = lift + t * (1 - lift - roll)
                    let L = t * 100

                    // 色彩：饱和度 + 整体色偏 + 分离色调
                    let ws = ColorMath.smoothstep(0.6, 0.0, tOrig)
                    let wh = ColorMath.smoothstep(0.4, 1.0, tOrig)
                    let a = lab.a * p.saturation + p.castA + p.shadowTint.x * ws + p.highlightTint.x * wh
                    let b = lab.b * p.saturation + p.castB + p.shadowTint.y * ws + p.highlightTint.y * wh

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
}
