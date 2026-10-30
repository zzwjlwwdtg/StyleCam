import Foundation
import CoreGraphics
import ImageIO
import Vision
import UIKit

enum StyleAnalyzerError: LocalizedError {
    case decodeFailed
    var errorDescription: String? { "无法读取这张图片" }
}

/// 8bit sRGB 像素缓冲
struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; bytes = buf
    }
}

/// 分析参考图：EXIF + 影调 + 色彩 + 质感 + 景深 + 场景
enum StyleAnalyzer {

    static func analyze(data: Data) throws -> (StyleProfile, UIImage) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let small = thumbnail(src, maxPixel: 384),
              let medium = thumbnail(src, maxPixel: 1600),
              let px = RGBAPixels(small),
              let mpx = RGBAPixels(medium)
        else { throw StyleAnalyzerError.decodeFailed }

        let exif = readEXIF(src)
        let w = px.width, h = px.height, n = w * h
        let lut = ColorMath.srgbToLinearLUT

        var Ls = [Double](repeating: 0, count: n)
        var Ys = [Double](repeating: 0, count: n)
        var sumY = 0.0, sumChroma = 0.0
        var neutralA: [Double] = [], neutralB: [Double] = []
        var shA: [Double] = [], shB: [Double] = []
        var hiA: [Double] = [], hiB: [Double] = []
        var hist = [Double](repeating: 0, count: 32)
        var centerY = 0.0, centerN = 0.0, cornerY = 0.0, cornerN = 0.0

        for yy in 0..<h {
            for xx in 0..<w {
                let p = yy * w + xx
                let i = p * 4
                let r = lut[Int(px.bytes[i])], g = lut[Int(px.bytes[i + 1])], b = lut[Int(px.bytes[i + 2])]
                let lab = ColorMath.linearRGBToLab(r, g, b)
                let y = ColorMath.luminance(r, g, b)
                Ls[p] = lab.L
                Ys[p] = y
                sumY += y
                let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
                sumChroma += chroma
                hist[min(31, max(0, Int(lab.L / 100.0 * 32.0)))] += 1

                // 接近中性的像素最能反映整体色偏
                if lab.L > 25, lab.L < 85, chroma < 22 { neutralA.append(lab.a); neutralB.append(lab.b) }
                if lab.L < 30, chroma < 30 { shA.append(lab.a); shB.append(lab.b) }
                if lab.L > 70, chroma < 30 { hiA.append(lab.a); hiB.append(lab.b) }

                let dx = (Double(xx) + 0.5) / Double(w) - 0.5
                let dy = (Double(yy) + 0.5) / Double(h) - 0.5
                let rr = (dx * dx + dy * dy).squareRoot() / 0.7071
                if rr < 0.3 { centerY += y; centerN += 1 } else if rr > 0.85 { cornerY += y; cornerN += 1 }
            }
        }

        let sortedL = Ls.sorted()
        let meanL = Ls.reduce(0, +) / Double(n)
        let stdL = (Ls.reduce(0) { $0 + ($1 - meanL) * ($1 - meanL) } / Double(n)).squareRoot()
        let p1 = ColorMath.percentile(sortedL, 0.01)
        let p99 = ColorMath.percentile(sortedL, 0.99)
        let medianL = ColorMath.percentile(sortedL, 0.5)
        hist = hist.map { $0 / Double(n) }

        // 色偏：中性像素的 a*/b* 中位数；样本太少时退化为全图均值的一半
        let castA: Double, castB: Double
        if neutralA.count > n / 50 {
            castA = ColorMath.median(neutralA); castB = ColorMath.median(neutralB)
        } else {
            castA = 0; castB = 0
        }
        func tint(_ a: [Double], _ b: [Double]) -> SIMD2<Double> {
            guard a.count > 50 else { return .zero }
            let ta = ColorMath.clamp(ColorMath.median(a) - castA, -18, 18)
            let tb = ColorMath.clamp(ColorMath.median(b) - castB, -18, 18)
            return SIMD2(ta, tb)
        }

        let vignetteRatio = (centerN > 0 && cornerN > 0 && centerY > 0.001)
            ? (cornerY / cornerN) / (centerY / centerN) : 1
        let (dof, sharpTop) = estimateDepthOfField(L: Ls, w: w, h: h)
        let grainNoise = estimateGrain(mpx)
        let points = countPointLights(Y: Ys, w: w, h: h)
        let faces = countFaces(medium)

        let profile = StyleProfile(
            meanLuminance: sumY / Double(n),
            medianL: medianL,
            blackPoint: p1,
            whitePoint: p99,
            contrast: ColorMath.clamp((stdL - 21) / 14, -1, 1),
            shadowLift: ColorMath.clamp((p1 - 3) / 20, 0, 1),
            highlightRolloff: ColorMath.clamp((97 - p99) / 25, 0, 1),
            saturation: ColorMath.clamp(sumChroma / Double(n) / 17, 0.2, 2.0),
            castA: ColorMath.clamp(castA, -20, 20),
            castB: ColorMath.clamp(castB, -25, 25),
            shadowTint: tint(shA, shB),
            highlightTint: tint(hiA, hiB),
            vignette: ColorMath.clamp((0.75 - vignetteRatio) / 0.45, 0, 1),
            grain: ColorMath.clamp((grainNoise - 0.006) / 0.016, 0, 1),
            sharpness: ColorMath.clamp((sharpTop - 0.05) / 0.04, -1, 1),
            depthOfField: dof,
            isNight: medianL < 28,
            pointLightCount: points,
            faceCount: faces,
            histogram: hist,
            exif: exif)

        return (profile, UIImage(cgImage: medium))
    }

    // MARK: - EXIF

    static func readEXIF(_ src: CGImageSource) -> ReferenceEXIF {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return ReferenceEXIF()
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var e = ReferenceEXIF()
        e.make = tiff[kCGImagePropertyTIFFMake] as? String
        e.model = tiff[kCGImagePropertyTIFFModel] as? String
        e.lensModel = exif[kCGImagePropertyExifLensModel] as? String
        e.fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        e.exposureTime = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        e.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue
        e.focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
        e.exposureBias = (exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue
        return e
    }

    static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - 景深：把画面分 4×4 块，比较最清晰块和普通块的拉普拉斯能量

    private static func estimateDepthOfField(L: [Double], w: Int, h: Int) -> (DepthOfField, Double) {
        let grid = 4
        var tileSum = [Double](repeating: 0, count: grid * grid)
        var tileN = [Double](repeating: 0, count: grid * grid)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = L[y * w + x]
                let lap = abs(4 * c - L[y * w + x - 1] - L[y * w + x + 1] - L[(y - 1) * w + x] - L[(y + 1) * w + x]) / 100
                let t = min(grid - 1, y * grid / h) * grid + min(grid - 1, x * grid / w)
                tileSum[t] += lap; tileN[t] += 1
            }
        }
        let tiles = zip(tileSum, tileN).map { $1 > 0 ? $0 / $1 : 0 }.sorted()
        let top = (tiles[tiles.count - 1] + tiles[tiles.count - 2]) / 2
        let median = max(tiles[tiles.count / 2], 1e-4)
        let ratio = top / median
        let dof: DepthOfField = ratio > 3.2 ? .shallow : (ratio < 1.7 ? .deep : .medium)
        return (dof, top)
    }

    // MARK: - 颗粒：在平坦区域里测高频残差

    private static func estimateGrain(_ px: RGBAPixels) -> Double {
        let side = min(400, px.width - 8, px.height - 8)
        guard side > 32 else { return 0 }
        let ox = (px.width - side) / 2, oy = (px.height - side) / 2
        var g = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let i = ((oy + y) * px.width + ox + x) * 4
                g[y * side + x] = (0.299 * Double(px.bytes[i]) + 0.587 * Double(px.bytes[i + 1]) + 0.114 * Double(px.bytes[i + 2])) / 255
            }
        }
        // 3×3 均值
        var m = [Double](repeating: 0, count: side * side)
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                var s = 0.0
                for dy in -1...1 { for dx in -1...1 { s += g[(y + dy) * side + x + dx] } }
                m[y * side + x] = s / 9
            }
        }
        var acc = 0.0, cnt = 0.0
        for y in 3..<(side - 3) {
            for x in 3..<(side - 3) {
                let activity = abs(m[y * side + x + 2] - m[y * side + x - 2]) + abs(m[(y + 2) * side + x] - m[(y - 2) * side + x])
                if activity < 0.02 {
                    let r = g[y * side + x] - m[y * side + x]
                    acc += r * r; cnt += 1
                }
            }
        }
        return cnt > 200 ? (acc / cnt).squareRoot() : 0
    }

    // MARK: - 点光源：暗背景里的局部亮点（夜景灯光、可出星芒）

    private static func countPointLights(Y: [Double], w: Int, h: Int) -> Int {
        var count = 0
        let r = 3
        guard w > 2 * r + 2, h > 2 * r + 2 else { return 0 }
        for y in r..<(h - r) {
            for x in r..<(w - r) {
                let v = Y[y * w + x]
                guard v > 0.85 else { continue }
                var isMax = true, sum = 0.0
                for dy in -r...r {
                    for dx in -r...r {
                        let u = Y[(y + dy) * w + x + dx]
                        sum += u
                        if abs(dx) <= 1, abs(dy) <= 1, u > v { isMax = false }
                    }
                }
                let mean = sum / Double((2 * r + 1) * (2 * r + 1))
                if isMax && mean < 0.3 { count += 1 }
            }
        }
        return count
    }

    // MARK: - 人脸数量（判断人像 / 合影）

    private static func countFaces(_ image: CGImage) -> Int {
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        return req.results?.count ?? 0
    }
}
