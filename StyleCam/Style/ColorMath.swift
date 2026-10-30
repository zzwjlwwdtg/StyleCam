import Foundation

/// 色彩数学：sRGB ↔ 线性 ↔ CIE Lab（D65）
enum ColorMath {

    /// 8bit sRGB → 线性值的查找表
    static let srgbToLinearLUT: [Double] = (0..<256).map { srgbToLinear(Double($0) / 255.0) }

    @inline(__always)
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linearToSRGB(_ c: Double) -> Double {
        let v = max(0, c)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    @inline(__always)
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    }

    @inline(__always)
    private static func f(_ t: Double) -> Double {
        t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
    }

    @inline(__always)
    private static func finv(_ t: Double) -> Double {
        let t3 = t * t * t
        return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787
    }

    /// 线性亮度 Y → L*
    @inline(__always)
    static func luminanceToL(_ y: Double) -> Double {
        116.0 * f(max(0, y)) - 16.0
    }

    /// 线性 sRGB → Lab
    @inline(__always)
    static func linearRGBToLab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let fx = f(x), fy = f(y), fz = f(z)
        return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))
    }

    /// Lab → 线性 sRGB
    @inline(__always)
    static func labToLinearRGB(_ L: Double, _ a: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        let fy = (L + 16.0) / 116.0
        let fx = fy + a / 500.0
        let fz = fy - b / 200.0
        let x = 0.95047 * finv(fx)
        let y = finv(fy)
        let z = 1.08883 * finv(fz)
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (r, g, bb)
    }

    /// 通用 smoothstep，edge0 > edge1 时为反向
    @inline(__always)
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

    /// 已排序数组的百分位
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[clamp(idx, 0, sorted.count - 1)]
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return percentile(values.sorted(), 0.5)
    }

    /// 按 a*/b* 方向给色调起中文名
    static func hueName(a: Double, b: Double) -> String {
        var deg = atan2(b, a) * 180 / .pi
        if deg < 0 { deg += 360 }
        switch deg {
        case 0..<22.5, 337.5...360: return "品红"
        case 22.5..<67.5: return "橙红"
        case 67.5..<112.5: return "暖黄"
        case 112.5..<157.5: return "黄绿"
        case 157.5..<202.5: return "绿"
        case 202.5..<247.5: return "青"
        case 247.5..<292.5: return "蓝"
        default: return "紫"
        }
    }
}
