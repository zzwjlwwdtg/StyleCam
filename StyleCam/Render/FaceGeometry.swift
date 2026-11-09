import CoreImage
import Vision
import CoreML

/// 人脸几何（Vision 关键点，图像坐标、左下角原点）：用于年轻化的提拉、法令纹 / 泪沟定位。
struct FaceGeometry {
    var box: CGRect
    var contour: [CGPoint]      // 下颌线（耳侧 → 下巴 → 另一侧）
    var noseWings: [CGPoint]    // 两侧鼻翼
    var mouthCorners: [CGPoint] // 两侧嘴角
    var eyes: [[CGPoint]]       // 两只眼的轮廓

    /// 模拟器里 GPU / 神经网络引擎上的关键点结果会错位，改走 CPU（真机不受影响）
    static func configure(_ req: VNRequest) {
        #if targetEnvironment(simulator)
        if let devs = try? req.supportedComputeStageDevices {
            for (stage, list) in devs {
                if let cpu = list.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                    req.setComputeDevice(cpu, for: stage)
                }
            }
        }
        #endif
    }

    static func detect(in img: CIImage) -> [FaceGeometry] {
        let req = VNDetectFaceLandmarksRequest()
        configure(req)
        guard (try? VNImageRequestHandler(ciImage: img, options: [:]).perform([req])) != nil else { return [] }
        let e = img.extent
        let size = e.size
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x + e.minX, y: $0.y + e.minY) }
        }
        return (req.results ?? []).compactMap { f in
            guard let lm = f.landmarks else { return nil }
            let box = CGRect(x: e.minX + f.boundingBox.minX * e.width, y: e.minY + f.boundingBox.minY * e.height,
                             width: f.boundingBox.width * e.width, height: f.boundingBox.height * e.height)
            let nose = pts(lm.nose), lips = pts(lm.outerLips)
            var wings: [CGPoint] = [], corners: [CGPoint] = []
            if let l = nose.min(by: { $0.x < $1.x }), let r = nose.max(by: { $0.x < $1.x }) { wings = [l, r] }
            if let l = lips.min(by: { $0.x < $1.x }), let r = lips.max(by: { $0.x < $1.x }) { corners = [l, r] }
            let eyes = [pts(lm.leftEye), pts(lm.rightEye)].filter { $0.count >= 4 }
            return FaceGeometry(box: box, contour: pts(lm.faceContour), noseWings: wings, mouthCorners: corners, eyes: eyes)
        }
    }

    // MARK: - 从人脸分区标签求几何（不依赖 Vision 关键点）

    /// 标签图：BiSeNet 每个像素的类别 × 13（0 背景、1 皮肤、4/5 眼、10 鼻、11 口、12/13 唇、14 脖子）。
    /// square：送进模型的方块在原图里的位置；标签图第 0 行是方块的最上面
    static func fromLabels(_ pb: CVPixelBuffer, square sq: CGRect, face: CGRect) -> FaceGeometry? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        var cls = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let v: Double
                switch fmt {
                case kCVPixelFormatType_OneComponent8: v = Double(base.load(fromByteOffset: y * rb + x, as: UInt8.self))
                case kCVPixelFormatType_OneComponent16Half: v = Double(Float(base.load(fromByteOffset: y * rb + x * 2, as: Float16.self)))
                case kCVPixelFormatType_OneComponent32Float: v = Double(base.load(fromByteOffset: y * rb + x * 4, as: Float.self))
                default: return nil
                }
                cls[y * w + x] = UInt8(max(0, min(18, (v / 13).rounded())))
            }
        }
        return fromClasses(cls, width: w, height: h, square: sq, face: face)
    }

    /// 同上，标签已经是类别号（测试也直接用）
    static func fromClasses(_ cls: [UInt8], width w: Int, height h: Int, square sq: CGRect, face: CGRect) -> FaceGeometry? {
        func img(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: sq.minX + (CGFloat(x) + 0.5) / CGFloat(w) * sq.width,
                    y: sq.maxY - (CGFloat(y) + 0.5) / CGFloat(h) * sq.height)
        }
        // 各类的像素
        var byClass = [[(Int, Int)]](repeating: [], count: 19)
        for y in 0..<h { for x in 0..<w { byClass[Int(cls[y * w + x])].append((x, y)) } }
        let minPx = max(6, w * h / 40000)
        func extremes(_ px: [(Int, Int)]) -> [CGPoint] {
            guard px.count >= minPx,
                  let l = px.min(by: { $0.0 < $1.0 }), let r = px.max(by: { $0.0 < $1.0 }),
                  let t = px.min(by: { $0.1 < $1.1 }), let b = px.max(by: { $0.1 < $1.1 }) else { return [] }
            return [img(l.0, l.1), img(t.0, t.1), img(r.0, r.1), img(b.0, b.1)]
        }
        // 眼睛：侧脸时模型常把两只眼标成同一类，所以把两类合起来按横向位置分成两团
        let eyePx = byClass[4] + byClass[5]
        var eyes: [[CGPoint]] = []
        if eyePx.count >= minPx, var c0 = eyePx.map(\.0).min().map(Double.init), var c1 = eyePx.map(\.0).max().map(Double.init) {
            var g0: [(Int, Int)] = [], g1: [(Int, Int)] = []
            for _ in 0..<6 {
                g0 = []; g1 = []
                for p in eyePx { if abs(Double(p.0) - c0) <= abs(Double(p.0) - c1) { g0.append(p) } else { g1.append(p) } }
                if !g0.isEmpty { c0 = Double(g0.map(\.0).reduce(0, +)) / Double(g0.count) }
                if !g1.isEmpty { c1 = Double(g1.map(\.0).reduce(0, +)) / Double(g1.count) }
            }
            // 两团太近说明其实只看到一只眼
            if abs(c1 - c0) < Double(w) * 0.06 { g0 += g1; g1 = [] }
            eyes = [extremes(g0), extremes(g1)].filter { !$0.isEmpty }
        }

        // 嘴角：口 + 上下唇的最左、最右
        let mouth = byClass[11] + byClass[12] + byClass[13]
        var corners: [CGPoint] = []
        if mouth.count >= minPx, let l = mouth.min(by: { $0.0 < $1.0 }), let r = mouth.max(by: { $0.0 < $1.0 }) {
            corners = [img(l.0, l.1), img(r.0, r.1)]
        }
        // 鼻翼：鼻子下面 30% 行里的最左、最右
        let nose = byClass[10]
        var wings: [CGPoint] = []
        if nose.count >= minPx, let top = nose.map(\.1).min(), let bot = nose.map(\.1).max() {
            let cut = bot - Int(Double(bot - top) * 0.3)
            let low = nose.filter { $0.1 >= cut }
            if let l = low.min(by: { $0.0 < $1.0 }), let r = low.max(by: { $0.0 < $1.0 }) { wings = [img(l.0, l.1), img(r.0, r.1)] }
        }
        // 下颌线：脸部皮肤（类别 1）的下边缘 + 鼻翼以下两侧的外边缘
        let skin = byClass[1]
        var contour: [CGPoint] = []
        if skin.count >= minPx * 10 {
            var lowest = [Int: Int](), left = [Int: Int](), right = [Int: Int]()
            for (x, y) in skin {
                lowest[x] = max(lowest[x] ?? y, y)
                left[y] = min(left[y] ?? x, x); right[y] = max(right[y] ?? x, x)
            }
            let xs = lowest.keys.sorted()
            if let x0 = xs.first, let x1 = xs.last, x1 > x0 {
                let n = 16
                for i in 0...n {
                    let x = x0 + (x1 - x0) * i / n
                    if let k = xs.min(by: { abs($0 - x) < abs($1 - x) }), let y = lowest[k] { contour.append(img(k, y)) }
                }
            }
            let startRow = nose.map(\.1).max() ?? (skin.map(\.1).min()! + skin.map(\.1).max()!) / 2
            let ys = left.keys.filter { $0 >= startRow }.sorted()
            for (i, y) in ys.enumerated() where i % max(1, ys.count / 8) == 0 {
                if let l = left[y] { contour.append(img(l, y)) }
                if let r = right[y] { contour.append(img(r, y)) }
            }
        }
        guard !contour.isEmpty || !eyes.isEmpty else { return nil }
        return FaceGeometry(box: face, contour: contour, noseWings: wings, mouthCorners: corners, eyes: eyes)
    }

    /// 眼下蒙版：每只眼睛正下方一个柔和的扁椭圆（和 SubjectMasker.underEyeMask 相同的形状）
    static func underEyeMask(_ faces: [FaceGeometry], extent e: CGRect) -> CIImage? {
        let eyes = faces.flatMap(\.eyes)
        guard !eyes.isEmpty else { return nil }
        let W = 360, H = max(1, Int((360 * e.height / max(1, e.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                    colors: [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)] as CFArray,
                                    locations: [0, 1]) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let sx = CGFloat(W) / e.width, sy = CGFloat(H) / e.height
        for eye in eyes {
            let pts = eye.map { CGPoint(x: ($0.x - e.minX) * sx, y: ($0.y - e.minY) * sy) }
            guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min() else { continue }
            let w = maxX - minX
            guard w > 1 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: (minX + maxX) / 2, y: minY - w * 0.42)
            ctx.scaleBy(x: 1, y: 0.42)
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: w * 0.8, options: [])
            ctx.restoreGState()
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(W), y: e.height / CGFloat(H))
                .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            .clampedToExtent().applyingGaussianBlur(sigma: Double(e.width) / 360).cropped(to: e)
    }

    // MARK: - 纹路蒙版（法令纹、泪沟）

    /// 法令纹：鼻翼外侧 → 嘴角外下方；泪沟：内眼角下方 → 斜向脸颊。画成粗线后模糊成柔和的带状蒙版
    static func foldMask(_ faces: [FaceGeometry], extent e: CGRect) -> CIImage? {
        guard !faces.isEmpty else { return nil }
        let W = 512, H = max(1, Int((512 * e.height / max(1, e.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let sx = CGFloat(W) / e.width, sy = CGFloat(H) / e.height
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - e.minX) * sx, y: (p.y - e.minY) * sy) }
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        var drew = false
        for f in faces {
            let fw = f.box.width
            ctx.setLineWidth(max(1.5, fw * 0.045 * sx))
            // 法令纹
            if f.noseWings.count == 2, f.mouthCorners.count == 2 {
                for (wing, corner) in zip(f.noseWings, f.mouthCorners) {
                    let out: CGFloat = wing.x < f.box.midX ? -1 : 1
                    let a = CGPoint(x: wing.x + out * fw * 0.03, y: wing.y)
                    let b = CGPoint(x: corner.x + out * fw * 0.04, y: corner.y - fw * 0.03)
                    let c = CGPoint(x: (a.x + b.x) / 2 + out * fw * 0.04, y: (a.y + b.y) / 2)
                    ctx.beginPath(); ctx.move(to: m(a)); ctx.addQuadCurve(to: m(b), control: m(c)); ctx.strokePath()
                    drew = true
                }
            }
            // 泪沟
            for eye in f.eyes {
                guard let minY = eye.map(\.y).min() else { continue }
                let inner = eye.min(by: { abs($0.x - f.box.midX) < abs($1.x - f.box.midX) }) ?? eye[0]
                let out: CGFloat = inner.x < f.box.midX ? -1 : 1
                let a = CGPoint(x: inner.x, y: minY - fw * 0.035)
                let b = CGPoint(x: inner.x + out * fw * 0.14, y: minY - fw * 0.11)
                ctx.setLineWidth(max(1.5, fw * 0.035 * sx))
                ctx.beginPath(); ctx.move(to: m(a)); ctx.addLine(to: m(b)); ctx.strokePath()
                drew = true
            }
        }
        guard drew, let cg = ctx.makeImage() else { return nil }
        let fw = faces.map(\.box.width).max() ?? 100
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(W), y: e.height / CGFloat(H))
                .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            .clampedToExtent().applyingGaussianBlur(sigma: Double(fw) * 0.02).cropped(to: e)
    }

    // MARK: - 提拉位移场

    /// 下颌线下半段、脸颊下缘的点向上（略向内）推，强度按高斯衰减；眼睛以上基本不动。
    /// 返回位移图（R = dx、G = dy，单位像素，不做色彩管理）
    static func liftField(_ faces: [FaceGeometry], amount: Double, extent e: CGRect) -> CIImage? {
        guard amount > 0.01, !faces.isEmpty else { return nil }
        var region = CGRect.null
        for f in faces { region = region.union(f.box.insetBy(dx: -f.box.width * 0.6, dy: -f.box.height * 0.6)) }
        region = region.intersection(e)
        guard !region.isNull, region.width > 4, region.height > 4 else { return nil }
        let N = 128
        let gw = N, gh = max(8, Int(CGFloat(N) * region.height / region.width))
        var px = [Float](repeating: 0, count: gw * gh * 4)
        // 控制点：下颌线中低于鼻尖高度的点
        var ctrl: [(p: CGPoint, v: CGVector, sigma: CGFloat)] = []
        for f in faces {
            let fw = f.box.width, fh = f.box.height
            let level = f.noseWings.map(\.y).max() ?? f.box.midY
            for c in f.contour where c.y < level {
                let toCenter: CGFloat = c.x < f.box.midX ? 1 : -1
                // 越靠下（下颌、腮部）推得越多
                let depth = min(1, max(0, (level - c.y) / (fh * 0.5)))
                let v = CGVector(dx: toCenter * fw * 0.008 * CGFloat(amount) * depth,
                                 dy: fh * 0.035 * CGFloat(amount) * (0.4 + 0.6 * depth))
                ctrl.append((c, v, fw * 0.17))
            }
        }
        guard !ctrl.isEmpty else { return nil }
        for gy in 0..<gh {
            for gx in 0..<gw {
                let x = region.minX + (CGFloat(gx) + 0.5) / CGFloat(gw) * region.width
                let y = region.minY + (CGFloat(gy) + 0.5) / CGFloat(gh) * region.height
                var dx: CGFloat = 0, dy: CGFloat = 0, wsum: CGFloat = 0
                for c in ctrl {
                    let d2 = (x - c.p.x) * (x - c.p.x) + (y - c.p.y) * (y - c.p.y)
                    let w = exp(-d2 / (2 * c.sigma * c.sigma))
                    dx += w * c.v.dx; dy += w * c.v.dy; wsum += w
                }
                // 归一化后再乘一个“离控制点多近”的权重，避免远处被拉动
                let k = min(1, wsum)
                let n = max(1e-6, wsum)
                let o = ((gh - 1 - gy) * gw + gx) * 4   // 位图行从上到下
                px[o] = Float(dx / n * k); px[o + 1] = Float(dy / n * k); px[o + 2] = 0; px[o + 3] = 1
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let field = CIImage(bitmapData: data, bytesPerRow: gw * 16, size: CGSize(width: gw, height: gh), format: .RGBAf, colorSpace: nil)
        return field
            .transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(gw), y: region.height / CGFloat(gh))
                .concatenating(CGAffineTransform(translationX: region.minX, y: region.minY)))
            .cropped(to: region)
    }
}
