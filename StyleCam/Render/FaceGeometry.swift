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
                let v = CGVector(dx: toCenter * fw * 0.006 * CGFloat(amount) * depth,
                                 dy: fh * 0.022 * CGFloat(amount) * (0.4 + 0.6 * depth))
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
