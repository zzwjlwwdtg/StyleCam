import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Photos
import Vision
import UIKit

/// 成片处理：套用与预览相同的滤镜 → 写 HEIC（保留原 EXIF，并把本次参数写进 UserComment）→ 存相册
enum PhotoProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func process(data: Data,
                        metadata: [String: Any],
                        renderer: StyleRenderer,
                        state: StyleRenderer.State,
                        summary: String,
                        preferPerson: Bool,
                        saveOriginal: Bool,
                        rawData: Data? = nil,
                        completion: @escaping (UIImage?, String?) -> Void) {
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            completion(nil, "照片解码失败"); return
        }
        let out = renderer.apply(ci, state: state, masks: masks(for: ci, state: state, preferPerson: preferPerson))
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let cg = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: p3) else {
            completion(nil, "渲染失败"); return
        }

        // 方向已经烘焙进像素，元数据里改为 1；参数写入 UserComment，日后可在 EXIF 里查到
        var meta = metadata
        meta[kCGImagePropertyOrientation as String] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            meta[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        var exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment as String] = summary
        meta[kCGImagePropertyExifDictionary as String] = exif
        meta[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.heic.identifier as CFString, 1, nil) else {
            completion(nil, "无法创建 HEIC"); return
        }
        CGImageDestinationAddImage(dest, cg, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { completion(nil, "HEIC 编码失败"); return }

        let thumb = UIImage(cgImage: cg).preparingThumbnail(of: CGSize(width: 240, height: 320))

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(thumb, "没有相册写入权限"); return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: outData as Data, options: nil)
                // ProRAW：DNG 作为同一张照片的“RAW 底片”一起保存（相册里显示 RAW 标记，可切换）
                if let rawData { req.addResource(with: .alternatePhoto, data: rawData, options: nil) }
                if saveOriginal {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }) { ok, err in
                completion(thumb, ok ? nil : "保存失败：\(err?.localizedDescription ?? "未知错误")")
            }
        }
    }

    /// 成片用高质量分割
    static func masks(for ci: CIImage, state: StyleRenderer.State, preferPerson: Bool) -> RenderMasks {
        var m = RenderMasks()
        let needPerson = StyleRenderer.needsPersonMask(state)
        let needSubject = StyleRenderer.needsSubjectMask(state)
        guard needPerson || needSubject else { return m }
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        if needPerson || preferPerson, let pb = SubjectMasker.personMask(handler, quality: .accurate) {
            m.person = SubjectMasker.ciMask(pb, fitting: ci.extent)
        }
        if needSubject {
            if preferPerson, let p = m.person {
                m.subject = p
            } else if let pb = SubjectMasker.foregroundMask(handler) {
                m.subject = SubjectMasker.ciMask(pb, fitting: ci.extent)
            } else {
                m.subject = m.person
            }
        }
        return m
    }

    // MARK: - 视频保存

    static func saveVideo(_ url: URL, completion: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("没有相册写入权限"); return
            }
            PHPhotoLibrary.shared().performChanges({
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = true
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: opts)
            }) { ok, err in
                completion(ok ? nil : "视频保存失败：\(err?.localizedDescription ?? "未知错误")")
            }
        }
    }

    // MARK: - 已有照片套用当前风格

    /// 参考图的目标统计（用于按每张照片自适应）
    struct Targets {
        var medianL: Double
        var chroma: Double
        var cast: SIMD2<Double>
    }

    /// 已有照片没有“实时闭环”，所以按这张照片本身的亮度/彩度/色偏重新算一次曝光、饱和度和色偏
    static func adaptedState(_ base: StyleRenderer.State, for ci: CIImage, targets t: Targets, variant: StyleVariant) -> StyleRenderer.State {
        let e = ci.extent
        let s = 128 / max(e.width, e.height)
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 4, h > 4, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return base }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            context.render(small, toBitmap: b, rowBytes: w * 4,
                           bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                           format: .RGBA8, colorSpace: srgb)
        }
        let lut = ColorMath.srgbToLinearLUT
        var Ls: [Double] = [], chroma = 0.0, nA: [Double] = [], nB: [Double] = []
        for p in 0..<(w * h) {
            let i = p * 4
            let lab = ColorMath.linearRGBToLab(lut[Int(buf[i])], lut[Int(buf[i + 1])], lut[Int(buf[i + 2])])
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            Ls.append(lab.L); chroma += c
            if lab.L > 25, lab.L < 85, c < 22 { nA.append(lab.a); nB.append(lab.b) }
        }
        let n = Double(w * h)
        let medL = ColorMath.median(Ls)
        let meanC = chroma / n
        var p = base.params
        func y(_ L: Double) -> Double { pow((L + 16) / 116, 3) }
        p.exposureEV = ColorMath.clamp(log2(max(y(t.medianL), 0.002) / max(y(medL), 0.002)) * 0.8, -1.5, 1.5)
        if meanC > 0.5 { p.saturation = ColorMath.clamp(t.chroma * variant.chromaFactor / meanC, 0.3, 1.8) }
        if nA.count > Int(n) / 50 {
            let target = t.cast * variant.castFactor
            p.castA = ColorMath.clamp(target.x - ColorMath.median(nA), -15, 15)
            p.castB = ColorMath.clamp(target.y - ColorMath.median(nB), -15, 15)
        }
        return StyleRenderer.State(params: p, lut: LUTBuilder.build(p),
                                   skinLut: LUTBuilder.build(p, skinVersion: true), enabled: base.enabled)
    }

    /// 读取已有照片（保留原 EXIF）→ 自适应 → 套用 → 另存为新照片（原图不动）
    static func processExisting(data: Data, renderer: StyleRenderer, base: StyleRenderer.State,
                                targets: Targets, variant: StyleVariant, preferPerson: Bool,
                                summary: String, completion: @escaping (UIImage?, String?) -> Void) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            completion(nil, "无法读取照片"); return
        }
        let state = adaptedState(base, for: ci, targets: targets, variant: variant)
        process(data: data, metadata: props, renderer: renderer, state: state, summary: summary,
                preferPerson: preferPerson, saveOriginal: false, completion: completion)
    }
}
