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
        var greenA: [Double] = [], greenB: [Double] = [], skyA: [Double] = [], skyB: [Double] = []
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
                // 分区颜色：植物（色相 100°–170°）、天空（画面上半部、色相 220°–290°、较亮）
                var hue = atan2(lab.b, lab.a) * 180 / .pi
                if hue < 0 { hue += 360 }
                if chroma > 10, hue > 100, hue < 170 { greenA.append(lab.a); greenB.append(lab.b) }
                if chroma > 6, hue > 220, hue < 290, lab.L > 45, yy < h / 2 { skyA.append(lab.a); skyB.append(lab.b) }

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
        let grainNoise = estimateGrain(mpx)
        let points = countPointLights(Y: Ys, w: w, h: h)
        let faceRects = detectFaces(medium)
        let (optics, subjectBox) = analyzeOptics(image: medium, px: mpx, exif: exif, faces: faceRects)
        func regionAB(_ a: [Double], _ b: [Double]) -> SIMD2<Double>? {
            a.count > n / 50 ? SIMD2(ColorMath.median(a), ColorMath.median(b)) : nil
        }
        // 景深分类按“远景弥散圆占画面长边的比例”（全画幅参照）：
        // 24mm f/8 风景 ≈ 0%，35mm f/2.8 环境人像 ≈ 0.2%，85mm f/1.8 半身 ≈ 3%
        let dof: DepthOfField = optics.blurFraction < 0.001 ? .deep : (optics.blurFraction < 0.008 ? .medium : .shallow)

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
            sharpness: ColorMath.clamp((1.15 - optics.subjectSigma) / 0.5, -1, 1),
            depthOfField: dof,
            isNight: medianL < 28,
            pointLightCount: points,
            faceCount: faceRects.count,
            histogram: hist,
            exif: exif,
            optics: optics,
            refStats: StyleMatcher.stats(rgba: px.bytes, width: px.width, height: px.height),
            aspect: Double(max(medium.width, medium.height)) / Double(max(1, min(medium.width, medium.height))),
            isLandscape: medium.width > medium.height,
            faceRect: faceRects.max(by: { $0.height < $1.height }).map(NormRect.fromVision),
            subjectRect: subjectBox,
            greenAB: regionAB(greenA, greenB),
            skyAB: regionAB(skyA, skyB))

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
        e.focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
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

    // MARK: - 人脸（Vision 归一化坐标，原点在左下）

    private static func detectFaces(_ image: CGImage) -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        return (req.results ?? []).map(\.boundingBox).filter { $0.height > 0.015 }
    }

    // MARK: - 光学分析：主体分割 → 离焦量 → 等效入瞳 / 等效光圈

    static func analyzeOptics(image: CGImage, px: RGBAPixels, exif: ReferenceEXIF, faces: [CGRect]) -> (ReferenceOptics, CGRect?) {
        let w = px.width, h = px.height, n = w * h
        var gray = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let j = i * 4
            gray[i] = (0.299 * Float(px.bytes[j]) + 0.587 * Float(px.bytes[j + 1]) + 0.114 * Float(px.bytes[j + 2])) / 255
        }

        var o = ReferenceOptics()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var subject: [Bool]
        if let pb = SubjectMasker.mask(handler: handler, preferPerson: !faces.isEmpty, personQuality: .accurate) {
            subject = SubjectMasker.boolMask(pb, width: w, height: h)
            o.subjectMaskFound = true
        } else {
            subject = fallbackSubject(w, h, faces)
        }
        let coverage = Double(subject.filter { $0 }.count) / Double(n)
        if coverage < 0.02 || coverage > 0.9 {
            subject = fallbackSubject(w, h, faces)
            o.subjectMaskFound = false
        }

        let r = DefocusEstimator.estimate(gray: gray, width: w, height: h, subject: subject)
        let longEdge = Double(max(w, h))
        o.subjectSigma = r.subjectSigma
        o.backgroundSigma = r.excessSigma
        o.blurFraction = r.blurDiameterPx / longEdge

        // 放大率：人脸框高度（≈20cm）在全画幅长边 36mm 里占多少
        if let face = faces.max(by: { $0.height < $1.height }) {
            let faceFrac = Double(face.height) * Double(h) / longEdge
            o.magnification = faceFrac * Optics.ffLongEdge / Optics.faceHeightMM
        }
        if let f35 = exif.focalLength35mm, f35 > 8 {
            o.focal35 = f35
            o.focal35Assumed = false
        }

        if let fn = exif.fNumber, fn > 0.7, let fa = exif.focalLength, fa > 0, let f35 = exif.focalLength35mm, f35 > 8 {
            // EXIF 齐全：直接精确换算
            let pupil = fa / fn
            o.pupilMM = pupil
            o.equivalentF = fn * f35 / fa
            o.source = .exif
            if o.magnification == nil, o.blurFraction > 0.002 {
                o.magnification = o.blurFraction * Optics.ffLongEdge / (pupil * Optics.backgroundFactor)
            }
        } else {
            let m = o.magnification ?? Optics.assumedMagnification
            o.source = o.magnification != nil ? .face : .assumed
            let f35 = o.focal35 ?? Optics.assumedFocal35
            o.focal35 = f35
            let eqF = min(32, f35 / max(Optics.pupilNeeded(blurFraction: o.blurFraction, magnification: m), 0.01))
            o.equivalentF = eqF
            o.pupilMM = f35 / eqF
        }
        if let m = o.magnification, let f35 = o.focal35, !o.focal35Assumed {
            o.subjectDistanceM = Optics.subjectDistance(focal35: f35, magnification: m)
        }
        // 主体外接框（归一化、左上角原点），用于构图叠加
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where subject[y * w + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let box: CGRect? = maxX > minX && maxY > minY
            ? CGRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                     width: Double(maxX - minX) / Double(w), height: Double(maxY - minY) / Double(h))
            : nil
        return (o, box)
    }

    /// 分割失败时的主体区域：有人脸就取“脸 + 身体”区域，否则取画面中央椭圆
    private static func fallbackSubject(_ w: Int, _ h: Int, _ faces: [CGRect]) -> [Bool] {
        var m = [Bool](repeating: false, count: w * h)
        if !faces.isEmpty {
            for f in faces {
                let fw = Double(f.width) * Double(w), fh = Double(f.height) * Double(h)
                let x0 = Double(f.minX) * Double(w) - 0.6 * fw, x1 = Double(f.maxX) * Double(w) + 0.6 * fw
                let top = (1 - Double(f.maxY)) * Double(h) - 0.3 * fh, bottom = top + 4.5 * fh
                let ys = max(0, Int(top)), ye = min(h, Int(bottom))
                let xs = max(0, Int(x0)), xe = min(w, Int(x1))
                guard ys < ye, xs < xe else { continue }
                for y in ys..<ye {
                    for x in xs..<xe { m[y * w + x] = true }
                }
            }
        } else {
            for y in 0..<h {
                for x in 0..<w {
                    let dx = (Double(x) / Double(w) - 0.5) / 0.22, dy = (Double(y) / Double(h) - 0.5) / 0.3
                    m[y * w + x] = dx * dx + dy * dy < 1
                }
            }
        }
        return m
    }
}
