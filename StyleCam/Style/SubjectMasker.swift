import Vision
import CoreImage
import CoreVideo

/// 主体分割（Apple 端侧模型）：人像优先用人像分割（头发边缘更好），其他主体用“前景实例”分割。
enum SubjectMasker {

    /// 返回主体蒙版（白 = 主体），分辨率为模型输出分辨率；调用方再缩放到目标尺寸
    static func mask(handler: VNImageRequestHandler,
                     preferPerson: Bool,
                     personQuality: VNGeneratePersonSegmentationRequest.QualityLevel) -> CVPixelBuffer? {
        if preferPerson, let pb = personMask(handler, quality: personQuality) { return pb }
        if let pb = foregroundMask(handler) { return pb }
        if !preferPerson { return personMask(handler, quality: personQuality) }
        return nil
    }

    static func personMask(_ handler: VNImageRequestHandler,
                           quality: VNGeneratePersonSegmentationRequest.QualityLevel) -> CVPixelBuffer? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([req])) != nil, let pb = req.results?.first?.pixelBuffer else { return nil }
        return coverage(pb) > 0.01 ? pb : nil
    }

    static func foregroundMask(_ handler: VNImageRequestHandler) -> CVPixelBuffer? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first,
              !obs.allInstances.isEmpty,
              let pb = try? obs.generateMask(forInstances: obs.allInstances) else { return nil }
        return pb
    }

    /// 蒙版 → CIImage，并缩放对齐到目标画面
    static func ciMask(_ pb: CVPixelBuffer, fitting extent: CGRect) -> CIImage {
        let m = CIImage(cvPixelBuffer: pb)
        let sx = extent.width / m.extent.width, sy = extent.height / m.extent.height
        return m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// 蒙版 → w×h 布尔数组（行从上到下，与 CGImage 位图一致）
    static func boolMask(_ pb: CVPixelBuffer, width w: Int, height h: Int) -> [Bool] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let mw = CVPixelBufferGetWidth(pb), mh = CVPixelBufferGetHeight(pb)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb), mw > 0, mh > 0 else { return [] }
        let isFloat = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent32Float
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let my = min(mh - 1, y * mh / h)
            let row = base.advanced(by: my * rb)
            for x in 0..<w {
                let mx = min(mw - 1, x * mw / w)
                let v: Float = isFloat
                    ? row.load(fromByteOffset: mx * 4, as: Float.self)
                    : Float(row.load(fromByteOffset: mx, as: UInt8.self)) / 255
                out[y * w + x] = v > 0.5
            }
        }
        return out
    }

    private static func coverage(_ pb: CVPixelBuffer) -> Double {
        let m = boolMask(pb, width: 64, height: 64)
        guard !m.isEmpty else { return 0 }
        return Double(m.filter { $0 }.count) / Double(m.count)
    }

    /// 眼下区域蒙版（美颜档）：人脸关键点找到双眼，在眼睛正下方画柔和的椭圆
    static func underEyeMask(_ handler: VNImageRequestHandler, extent: CGRect,
                             request: VNDetectFaceLandmarksRequest = VNDetectFaceLandmarksRequest()) -> CIImage? {
        guard (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty else { return nil }
        let W = 360, H = max(1, Int((360 * extent.height / max(1, extent.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                    colors: [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)] as CFArray,
                                    locations: [0, 1]) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let size = CGSize(width: W, height: H)
        var drew = false
        for face in faces {
            guard let lm = face.landmarks else { continue }
            for eye in [lm.leftEye, lm.rightEye].compactMap({ $0 }) {
                let pts = eye.pointsInImage(imageSize: size)      // 左下角为原点，与 CGContext 一致
                guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
                      let minY = pts.map(\.y).min() else { continue }
                let w = maxX - minX
                guard w > 2 else { continue }
                let c = CGPoint(x: (minX + maxX) / 2, y: minY - w * 0.42)
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.scaleBy(x: 1, y: 0.42)
                ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: w * 0.8, options: [])
                ctx.restoreGState()
                drew = true
            }
        }
        guard drew, let cg = ctx.makeImage() else { return nil }
        let m = CIImage(cgImage: cg)
        return m.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(W), y: extent.height / CGFloat(H))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .clampedToExtent().applyingGaussianBlur(sigma: Double(extent.width) / 360).cropped(to: extent)
    }
}
