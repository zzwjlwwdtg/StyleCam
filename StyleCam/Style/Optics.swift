import Foundation

/// 光学等效：把任何相机（全画幅 / APS-C / 手机）都换算到“全画幅等效”，再反推 iPhone 该怎么设。
///
/// 核心结论（摄影光学的等效原理）：
/// - 构图相同（主体在画面里一样大）时，背景虚化的大小只取决于 **入瞳直径 D = 实际焦距 / f 值**。
///   背景弥散圆 / 画面长边 = D × m × k / 36mm
///   其中 m = 全画幅放大率（像高 / 物高），k = 1 − 主体距离 / 背景距离（背景越远越接近 1）。
/// - 景深在等效空间里计算：全画幅等效焦距 + 等效 f 值（= f 值 × 裁切系数）+ 0.03mm 弥散圆，结果与真实相机一致。
/// - 所以 iPhone 主摄 f/1.48 ≈ 全画幅 24mm f/5.2，入瞳只有约 4.6mm；全画幅 85mm f/1.8 的入瞳是 47mm。
enum Optics {
    static let ffLongEdge = 36.0          // 全画幅长边 mm
    static let ffCoC = 0.03               // 全画幅容许弥散圆 mm
    static let faceHeightMM = 200.0       // Vision 人脸框高度（眉毛~下巴）对应的真实尺寸
    static let backgroundFactor = 0.6     // k 的默认假设：背景在主体后方约 1.5 倍距离处
    static let assumedMagnification = 0.02 // 无人脸、无 EXIF 时假设的“中景”放大率（≈50mm 在 2.5m）
    static let assumedFocal35 = 50.0

    /// iPhone 18 Pro Max 各镜头（实际焦距按官方规格的像素尺寸推算：主摄 1.22µm×8064 ≈ 9.8mm 宽，
    /// 长焦/超广 0.7µm×8064 ≈ 5.6mm 宽）。拍第一张照片后会用照片 EXIF 自动校准。
    struct Lens {
        let choice: LensChoice
        let focalActual: Double   // 实际焦距 mm
        let fixedF: Double?       // 固定光圈镜头的 f 值
        var focal35: Double { choice.focal35 }
        var crop: Double { focal35 / focalActual }                 // 2x/8x 裁切时自动翻倍
        func pupil(_ n: Double) -> Double { focalActual / n }       // 入瞳直径 mm
        func equivalentF(_ n: Double) -> Double { n * crop }         // 全画幅等效 f 值
    }

    private static let lock = NSLock()
    private static var focalTable: [LensChoice: Double] = [
        .ultraWide: 2.12, .wide: 6.82, .wide2x: 6.82, .tele: 16.3, .tele8x: 16.3
    ]
    private static let fixedTable: [LensChoice: Double] = [.ultraWide: 2.2, .tele: 2.8, .tele8x: 2.8]

    static func lens(_ c: LensChoice) -> Lens {
        lock.lock(); defer { lock.unlock() }
        return Lens(choice: c, focalActual: focalTable[c] ?? 6.82, fixedF: fixedTable[c])
    }

    /// 用拍出的照片 EXIF（实际焦距）校准；2x/8x 与 1x/4x 共用同一颗物理镜头
    static func calibrate(_ c: LensChoice, focalActual f: Double) {
        guard let current = focalTable[c], f > current * 0.6, f < current * 1.6 else { return }
        lock.lock(); defer { lock.unlock() }
        switch c {
        case .wide, .wide2x: focalTable[.wide] = f; focalTable[.wide2x] = f
        case .tele, .tele8x: focalTable[.tele] = f; focalTable[.tele8x] = f
        case .ultraWide: focalTable[.ultraWide] = f
        }
    }

    /// 背景弥散圆直径占画面长边的比例
    static func backgroundBlurFraction(pupilMM d: Double, magnification m: Double, k: Double = backgroundFactor) -> Double {
        d * m * k / ffLongEdge
    }

    /// 反推：要得到某个背景虚化比例需要的入瞳直径
    static func pupilNeeded(blurFraction b: Double, magnification m: Double, k: Double = backgroundFactor) -> Double {
        b * ffLongEdge / max(m * k, 1e-6)
    }

    /// 主体距离（m）：由全画幅等效焦距与放大率反推
    static func subjectDistance(focal35: Double, magnification m: Double) -> Double {
        focal35 / 1000 * (1 + 1 / max(m, 1e-4))
    }

    /// 景深范围（m），在全画幅等效空间计算
    static func depthOfField(focal35: Double, equivalentF n: Double, subjectM s: Double) -> (near: Double, far: Double) {
        let f = focal35 / 1000, c = ffCoC / 1000
        let hyper = f * f / (n * c) + f
        let near = s * (hyper - f) / (hyper + s - 2 * f)
        let far = s >= hyper ? Double.infinity : s * (hyper - f) / (hyper - s)
        return (near, far)
    }

    static func fmtDOF(_ r: (near: Double, far: Double)) -> String {
        let far = r.far.isFinite ? String(format: "%.1fm", r.far) : "∞"
        return String(format: "%.1fm – ", r.near) + far + (r.far.isFinite ? String(format: "（深 %.1fm）", r.far - r.near) : "")
    }

    static func fmtF(_ n: Double) -> String { n >= 10 ? String(format: "f/%.0f", n) : String(format: "f/%.1f", n) }
}

/// 参考图的光学分析结果
struct ReferenceOptics: Equatable {
    enum Source: String {
        case exif = "EXIF 拍摄参数"
        case face = "人脸尺寸推算"
        case assumed = "仅按虚化比例（构图为假设值）"
    }

    var subjectSigma: Double = 0        // 主体离焦（分析图像素）
    var backgroundSigma: Double = 0     // 背景离焦
    var blurFraction: Double = 0        // 背景弥散圆 / 画面长边
    var subjectMaskFound = false
    var magnification: Double?          // 全画幅放大率
    var focal35: Double?
    var focal35Assumed = true
    var pupilMM: Double?                // 入瞳直径估计
    var equivalentF: Double?            // 全画幅等效 f 值
    var subjectDistanceM: Double?
    var source: Source = .assumed

    var summary: String {
        var s = "背景虚化 \(String(format: "%.1f", blurFraction * 100))% 画幅"
        if let d = pupilMM, let n = equivalentF, let f = focal35 {
            s += " · ≈ 全画幅 \(Int(f))mm \(Optics.fmtF(n))（入瞳 \(String(format: "%.1f", d))mm）"
        }
        return s
    }
}
