import Foundation
import CoreImage

/// 质感统计（都在观看尺度：长边 1440）：颗粒 σ、边缘模糊 σ（越大越软）、暗角（四角/中心亮度比）
struct TextureStats: Equatable {
    var grain: Double
    var edge: Double
    var vignette: Double
}

enum TextureEstimator {
    /// 颗粒标定：颗粒参数 1.0 ≈ 观看尺度 σ 0.026（模拟器实测，4032–8064 长边基本一致）
    static let grainSigmaPerAmount = 0.026

    static func measure(_ image: CIImage, context: CIContext, jpegGridAligned: Bool = false) -> TextureStats? {
        guard let v = GrainEstimator.viewLuma(of: image, context: context) else { return nil }
        let grid = jpegGridAligned && v.native
        let grain = GrainEstimator.sigma(luma: v.y, width: v.w, height: v.h, excludeJPEGGrid: grid) ?? 0
        let edge = DefocusEstimator.edgeSigma(gray: v.y, width: v.w, height: v.h, excludeJPEGGrid: grid) ?? 1
        // 暗角：线性亮度，四角（r>0.85）/ 中心（r<0.3）
        var c = 0.0, cn = 0.0, k = 0.0, kn = 0.0
        for y in 0..<v.h {
            for x in 0..<v.w {
                let dx = (Double(x) + 0.5) / Double(v.w) - 0.5, dy = (Double(y) + 0.5) / Double(v.h) - 0.5
                let r = (dx * dx + dy * dy).squareRoot() / 0.7071
                let lin = pow(Double(max(0, v.y[y * v.w + x])), 2.2)
                if r < 0.3 { c += lin; cn += 1 } else if r > 0.85 { k += lin; kn += 1 }
            }
        }
        let vig = (cn > 0 && kn > 0 && c > 0.001) ? (k / kn) / (c / cn) : 1
        return TextureStats(grain: grain, edge: edge, vignette: vig)
    }

    /// 只补“参考图有、当前画面没有”的那部分质感
    /// 柔化会顺带抹掉画面原有的噪点。模拟器标定（iPhone 原片）：柔化 0.3/0.6/1.0 → 噪点剩 65%/26%/6.5%
    static func noiseRemaining(afterBlur b: Double) -> Double {
        guard b > 0 else { return 1 }
        return exp(-pow(b / 0.55, 1.6))
    }

    static func apply(to g: inout GradingParams, raw: TextureStats, ref: TextureStats) {
        let d = ref.edge - raw.edge
        if d > 0.08 {
            g.blurSigmaView = (ref.edge * ref.edge - raw.edge * raw.edge).squareRoot()
            g.sharpen = 0
        } else if d < -0.12 {
            g.blurSigmaView = 0
            g.sharpen = min(0.8, -d * 1.0)
        } else {
            g.blurSigmaView = 0
            g.sharpen = 0
        }
        // 颗粒：先算柔化后画面还剩多少噪点，再补到参考图的真实颗粒
        let remaining = raw.grain * noiseRemaining(afterBlur: g.blurSigmaView)
        g.grainAddSigma = (max(0, ref.grain * ref.grain - remaining * remaining)).squareRoot()
        // 暗角：四角亮度很大程度取决于画面内容（参考图角落是深色树干、取景角落是白色打印机），
        // 差值也不可靠，所以只在参考图明显更暗时补一点点（四角最多暗约 10%；标定：0.12 → 四角/中心 0.89）
        let dv = raw.vignette - ref.vignette
        g.vignette = dv > 0.08 ? min(0.12, dv / 0.9) : 0
    }
}
