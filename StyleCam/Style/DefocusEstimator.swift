import Foundation

/// 离焦量估计（Zhuo & Sim, "Defocus map estimation from a single image", 2011 的多尺度版本）
///
/// 原理：对图像再做一次已知 σ0 的高斯模糊，比较边缘处模糊前后的梯度比 R，
/// 则该边缘原有的模糊 σ = σ0 / √(R² − 1)。分别统计“主体”和“背景”区域的边缘，
/// 背景超出主体的那部分模糊 √(σ_bg² − σ_subj²) 就是光学虚化（自动扣除压缩/缩放带来的整体发软）。
/// 大虚化在原尺寸下会饱和，所以在 5 层金字塔上各测一次取最大值。
/// 合成图标定：弥散圆直径 d ≈ 3.6·σ·(1 + 0.015·σ)，在 d = 4…48px 范围内误差约 10%。
enum DefocusEstimator {

    struct Result {
        var subjectSigma: Double       // 原尺寸下主体的模糊 σ（像素）
        var excessSigma: Double        // 背景超出主体的模糊 σ（像素）
        var blurDiameterPx: Double     // 换算成弥散圆直径（像素）
        var subjectEdges: Int
        var backgroundEdges: Int
    }

    static func estimate(gray: [Float], width: Int, height: Int, subject: [Bool]) -> Result {
        var img = gray, w = width, h = height
        var mask = labels(subject, w, h, radius: max(3, max(w, h) / 200))
        var best = 0.0, subj0 = 1.0, sEdges = 0, bEdges = 0
        for level in 0..<5 {
            guard min(w, h) >= 60 else { break }
            let (s, ns, b, nb) = regionSigmas(img, w, h, mask)
            if level == 0 { sEdges = ns; bEdges = nb }
            if let s, let b {
                let scale = Double(1 << level)
                let ss = s * scale, bb = b * scale
                if level == 0 { subj0 = ss }
                best = max(best, (max(0, bb * bb - ss * ss)).squareRoot())
            }
            (img, mask, w, h) = downsample(img, mask, w, h)
        }
        let d = 3.6 * best * (1 + 0.015 * best)
        return Result(subjectSigma: subj0, excessSigma: best, blurDiameterPx: d,
                      subjectEdges: sEdges, backgroundEdges: bEdges)
    }

    // MARK: - 单层

    private static func regionSigmas(_ img: [Float], _ w: Int, _ h: Int, _ mask: [Int8])
        -> (Double?, Int, Double?, Int) {
        let s0: Float = 1.5
        let g = gradient(img, w, h)
        let g1 = gradient(gaussian(img, w, h, sigma: s0), w, h)

        func sigmas(_ want: Int8) -> [Double] {
            var vals: [Float] = []
            for i in 0..<(w * h) where mask[i] == want { vals.append(g[i]) }
            guard vals.count > 500 else { return [] }
            vals.sort()
            let thr = vals[Int(Double(vals.count - 1) * 0.85)]
            var out: [Double] = []
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    guard mask[i] == want else { continue }
                    let v = g[i]
                    guard v > thr, g1[i] > 1e-4 else { continue }
                    let hMax = v >= g[i - 1] && v >= g[i + 1]
                    let vMax = v >= g[i - w] && v >= g[i + w]
                    guard hMax || vMax else { continue }
                    let r = Double(v / g1[i])
                    guard r > 1.02 else { continue }
                    out.append(min(Double(s0) / (r * r - 1).squareRoot(), 15))
                }
            }
            return out
        }
        let s = sigmas(1), b = sigmas(0)
        return (s.count > 100 ? ColorMath.median(s) : nil, s.count,
                b.count > 100 ? ColorMath.median(b) : nil, b.count)
    }

    /// 1 = 主体，0 = 背景，-1 = 两者交界（腐蚀 radius 像素后丢弃，避免主体轮廓被当成背景边缘）
    private static func labels(_ subject: [Bool], _ w: Int, _ h: Int, radius r: Int) -> [Int8] {
        func erode(_ m: [Bool]) -> [Bool] {
            var tmp = [Bool](repeating: false, count: w * h)
            var out = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var ok = true
                    for j in max(0, x - r)...min(w - 1, x + r) where !m[y * w + j] { ok = false; break }
                    tmp[y * w + x] = ok
                }
            }
            for x in 0..<w {
                for y in 0..<h {
                    var ok = true
                    for j in max(0, y - r)...min(h - 1, y + r) where !tmp[j * w + x] { ok = false; break }
                    out[y * w + x] = ok
                }
            }
            return out
        }
        let s = erode(subject), b = erode(subject.map { !$0 })
        return (0..<(w * h)).map { (i: Int) -> Int8 in s[i] ? 1 : (b[i] ? 0 : -1) }
    }

    private static func gradient(_ img: [Float], _ w: Int, _ h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (img[i + 1] - img[i - 1]) * 0.5
                let gy = (img[i + w] - img[i - w]) * 0.5
                g[i] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return g
    }

    private static func gaussian(_ img: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
        let r = Int((3 * sigma).rounded(.up))
        var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = k.reduce(0, +)
        k = k.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for j in -r...r { acc += k[j + r] * img[y * w + min(w - 1, max(0, x + j))] }
                tmp[y * w + x] = acc
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for j in -r...r { acc += k[j + r] * tmp[min(h - 1, max(0, y + j)) * w + x] }
                out[y * w + x] = acc
            }
        }
        return out
    }

    private static func downsample(_ img: [Float], _ mask: [Int8], _ w: Int, _ h: Int)
        -> ([Float], [Int8], Int, Int) {
        let nw = w / 2, nh = h / 2
        var o = [Float](repeating: 0, count: nw * nh)
        var m = [Int8](repeating: -1, count: nw * nh)
        for y in 0..<nh {
            for x in 0..<nw {
                let i = 2 * y * w + 2 * x
                o[y * nw + x] = (img[i] + img[i + 1] + img[i + w] + img[i + w + 1]) * 0.25
                // 4 个像素同属一个区域才保留，否则记为边界（-1）
                let a = mask[i], b = mask[i + 1], c = mask[i + w], d = mask[i + w + 1]
                m[y * nw + x] = (a == b && b == c && c == d) ? a : -1
            }
        }
        return (o, m, nw, nh)
    }
}
