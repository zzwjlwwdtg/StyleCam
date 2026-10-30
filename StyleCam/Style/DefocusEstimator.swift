import Foundation

/// 离焦量估计（Zhuo & Sim, "Defocus map estimation from a single image", 2011 的多尺度版本）
///
/// 原理：对图像再做一次已知 σ0 的高斯模糊，比较边缘处模糊前后的梯度比 R，
/// 则该边缘原有的模糊 σ = σ0 / √(R² − 1)。
/// - 主体：主体区域所有边缘 σ 的中位数（对焦清晰度）。
/// - 背景：把背景分成 8×6 块，取各块中位数的第 80 百分位，即“最虚的远景”。
///   与主体同一距离的树干、地面同样清晰，平均值会被它们拉低，所以只看远景。
/// - 背景超出主体的模糊 √(σ_bg² − σ_subj²) 即光学虚化（自动扣除压缩/缩放带来的整体发软）。
/// - 金字塔：当本层背景 σ > 2.2（测量开始饱和）时才下探到下一层，避免粗层的系统偏差。
/// 合成图标定：弥散圆直径 d ≈ 3.6·σ·(1 + 0.015·σ)，d = 0…48px（含“只有一半背景虚化”）误差约 10%。
enum DefocusEstimator {

    struct Result {
        var subjectSigma: Double       // 原尺寸下主体的模糊 σ（像素）
        var excessSigma: Double        // 远景超出主体的模糊 σ（像素）
        var blurDiameterPx: Double     // 换算成弥散圆直径（像素）
        var subjectEdges: Int
        var backgroundEdges: Int
    }

    static func estimate(gray: [Float], width: Int, height: Int, subject: [Bool]) -> Result {
        var img = gray, w = width, h = height
        var mask = labels(subject, w, h, radius: max(3, max(w, h) / 200))
        var excess = 0.0, subj0 = 1.0, sEdges = 0, bEdges = 0
        for level in 0..<5 {
            guard min(w, h) >= 60 else { break }
            let r = measure(img, w, h, mask, minTileEdges: max(10, 30 >> level))
            if level == 0 { sEdges = r.subjectEdges; bEdges = r.backgroundEdges }
            guard let s = r.subject, let b = r.farBackground else { break }
            let scale = Double(1 << level)
            if level == 0 { subj0 = s }
            excess = (max(0, b * b - s * s)).squareRoot() * scale
            if b < 2.2 { break }                      // 本层未饱和 → 结果可信
            (img, mask, w, h) = downsample(img, mask, w, h)
        }
        let d = 3.6 * excess * (1 + 0.015 * excess)
        return Result(subjectSigma: subj0, excessSigma: excess, blurDiameterPx: d,
                      subjectEdges: sEdges, backgroundEdges: bEdges)
    }

    /// 整幅图的边缘模糊 σ（像素）：梯度最强 15% 的边缘处 Zhuo-Sim 估计的中位数；可排除 JPEG 块边界
    static func edgeSigma(gray img: [Float], width w: Int, height h: Int, excludeJPEGGrid: Bool) -> Double? {
        guard w > 32, h > 32 else { return nil }
        let s0: Float = 1.5
        let g = gradient(img, w, h)
        let g1 = gradient(gaussian(img, w, h, sigma: s0), w, h)
        var vals = g
        vals.sort()
        let thr = vals[Int(Double(vals.count - 1) * 0.85)]
        var out: [Double] = []
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) {
                if excludeJPEGGrid {
                    let mx = x % 8, my = y % 8
                    if mx == 0 || mx == 7 || my == 0 || my == 7 { continue }
                }
                let i = y * w + x
                let v = g[i]
                guard v > thr, g1[i] > 1e-4 else { continue }
                guard (v >= g[i - 1] && v >= g[i + 1]) || (v >= g[i - w] && v >= g[i + w]) else { continue }
                let r = Double(v / g1[i])
                guard r > 1.02 else { continue }
                out.append(min(Double(s0) / (r * r - 1).squareRoot(), 15))
            }
        }
        return out.count > 200 ? ColorMath.median(out) : nil
    }

    // MARK: - 单层

    private struct LevelResult {
        var subject: Double?
        var farBackground: Double?
        var subjectEdges = 0
        var backgroundEdges = 0
    }

    private static func measure(_ img: [Float], _ w: Int, _ h: Int, _ mask: [Int8], minTileEdges: Int) -> LevelResult {
        let s0: Float = 1.5
        let g = gradient(img, w, h)
        let g1 = gradient(gaussian(img, w, h, sigma: s0), w, h)
        let gx = 8, gy = 6

        func threshold(_ want: Int8) -> Float? {
            var vals: [Float] = []
            for i in 0..<(w * h) where mask[i] == want { vals.append(g[i]) }
            guard vals.count > 500 else { return nil }
            vals.sort()
            return vals[Int(Double(vals.count - 1) * 0.85)]
        }
        let tS = threshold(1), tB = threshold(0)
        var subj: [Double] = []
        var tiles = [[Double]](repeating: [], count: gx * gy)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lab = mask[i]
                guard lab >= 0, let thr = (lab == 1 ? tS : tB) else { continue }
                let v = g[i]
                guard v > thr, g1[i] > 1e-4 else { continue }
                let hMax = v >= g[i - 1] && v >= g[i + 1]
                let vMax = v >= g[i - w] && v >= g[i + w]
                guard hMax || vMax else { continue }
                let r = Double(v / g1[i])
                guard r > 1.02 else { continue }
                let sigma = min(Double(s0) / (r * r - 1).squareRoot(), 15)
                if lab == 1 {
                    subj.append(sigma)
                } else {
                    tiles[min(gy - 1, y * gy / h) * gx + min(gx - 1, x * gx / w)].append(sigma)
                }
            }
        }
        var out = LevelResult()
        out.subjectEdges = subj.count
        out.backgroundEdges = tiles.reduce(0) { $0 + $1.count }
        if subj.count > 100 { out.subject = ColorMath.median(subj) }
        let tileMedians = tiles.filter { $0.count >= minTileEdges }.map { ColorMath.median($0) }.sorted()
        if tileMedians.count >= 4 { out.farBackground = ColorMath.percentile(tileMedians, 0.8) }
        return out
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
