import Foundation
import CoreImage

/// 颗粒（亮度噪声）测量：统一换算到“观看尺度”（长边 1440，约手机全屏看图），
/// 只在平坦区域测，并可排除 JPEG 8×8 块边界，避免把压缩块效应当成颗粒。
/// 方法：Immerkær (1996) 快速噪声估计，σ = √(π/2) / 6 · mean|I * N|，N = [[1,-2,1],[-2,4,-2],[1,-2,1]]
enum GrainEstimator {
    static let viewLongEdge: CGFloat = 1440

    /// image：任意尺寸；jpegGridAligned：图像是否与原 JPEG 像素网格对齐（未缩放的原图）
    static func sigma(of image: CIImage, context: CIContext, jpegGridAligned: Bool = false) -> Double? {
        let e = image.extent
        guard e.width > 16, e.height > 16, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let long = max(e.width, e.height)
        let scale = min(1, viewLongEdge / long)
        let img = scale < 1
            ? image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            : image
        let r = img.extent
        let w = Int(r.width), h = Int(r.height)
        guard w > 16, h > 16 else { return nil }
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            context.render(img, toBitmap: b, rowBytes: w * 16,
                           bounds: CGRect(x: r.minX, y: r.minY, width: CGFloat(w), height: CGFloat(h)),
                           format: .RGBAf, colorSpace: srgb)
        }
        var y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            y[i] = 0.299 * buf[i * 4] + 0.587 * buf[i * 4 + 1] + 0.114 * buf[i * 4 + 2]
        }
        return sigma(luma: y, width: w, height: h, excludeJPEGGrid: jpegGridAligned && scale >= 1)
    }

    static func sigma(luma y: [Float], width w: Int, height h: Int, excludeJPEGGrid: Bool) -> Double? {
        // 平坦度：3×3 均值后的梯度
        var m = [Float](repeating: 0, count: w * h)
        for yy in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s: Float = 0
                for dy in -1...1 { for dx in -1...1 { s += y[(yy + dy) * w + x + dx] } }
                m[yy * w + x] = s / 9
            }
        }
        var grads: [Float] = []
        var resp: [Float] = []
        grads.reserveCapacity(w * h)
        resp.reserveCapacity(w * h)
        for yy in 3..<(h - 3) {
            for x in 3..<(w - 3) {
                if excludeJPEGGrid {
                    let mx = x % 8, my = yy % 8
                    if mx == 0 || mx == 7 || my == 0 || my == 7 { continue }
                }
                let i = yy * w + x
                let g = abs(m[i + 2] - m[i - 2]) + abs(m[i + 2 * w] - m[i - 2 * w])
                let c = y[i - w - 1] - 2 * y[i - w] + y[i - w + 1]
                    - 2 * y[i - 1] + 4 * y[i] - 2 * y[i + 1]
                    + y[i + w - 1] - 2 * y[i + w] + y[i + w + 1]
                // 排除过暗/过亮（裁切处噪声被压缩）
                guard m[i] > 0.08, m[i] < 0.92 else { continue }
                grads.append(g)
                resp.append(abs(c))
            }
        }
        guard grads.count > 500 else { return nil }
        // 取最平坦的 30% 像素
        let sortedG = grads.sorted()
        let thr = sortedG[Int(Double(sortedG.count - 1) * 0.3)]
        var acc = 0.0, n = 0.0
        for k in 0..<grads.count where grads[k] <= thr {
            acc += Double(resp[k]); n += 1
        }
        guard n > 200 else { return nil }
        return (Double.pi / 2).squareRoot() / 6 * acc / n
    }
}
