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
                        grading: GradingSnapshot,
                        summary: String,
                        preferPerson: Bool,
                        saveOriginal: Bool,
                        rawData: Data? = nil,
                        completion: @escaping (UIImage?, String?) -> Void) {
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            completion(nil, "照片解码失败"); return
        }
        // 成片和取景预览走的是苹果不同的处理流程（拍照会多帧合成 / Smart HDR），
        // 所以影调、色彩、质感都按这张成片本身重新算一遍差值，而不是沿用预览时的参数
        let state = grading.state(for: ci, context: context)
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
        let needFace = StyleRenderer.needsFaceMask(state)
        guard needPerson || needSubject || needFace else { return m }
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        if needFace { m.underEye = SubjectMasker.underEyeMask(handler, extent: ci.extent) }
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

    /// 读取已有照片（保留原 EXIF）→ 按这张照片重新匹配 → 套用 → 另存为新照片（原图不动）
    static func processExisting(data: Data, renderer: StyleRenderer, grading: GradingSnapshot, preferPerson: Bool,
                                summary: String, saveOriginal: Bool = false, completion: @escaping (UIImage?, String?) -> Void) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            completion(nil, "无法读取照片"); return
        }
        var g = grading
        g.resetExposure = true
        process(data: data, metadata: props, renderer: renderer, grading: g, summary: summary,
                preferPerson: preferPerson, saveOriginal: saveOriginal, completion: completion)
    }
}

/// 拍照 / 套用相册时的调色快照：计划里的参数 + 参考图统计 + 当前版本与效果开关。
/// 对每张成片单独算：按这张图本身的统计对齐参考图（影调 / 彩度 / 色偏 / 分离色调），按它本身的噪点和锐度补差值，
/// 最后再套版本（忠实 / 柔和 / 浓郁）和效果开关，和实时预览的顺序完全一致。
struct GradingSnapshot {
    var base: GradingParams
    var ref: SceneStats?
    var refTexture: TextureStats?
    var variant: StyleVariant
    var effects: EffectToggles
    var matchAspect: Bool
    var enabled: Bool
    var resetExposure = false
    var beauty = BeautySettings()

    /// 实时取景用的轻量版：只对齐影调色彩（不测质感，颗粒沿用计划里的值）。
    /// 返回“匹配后、套版本前”的参数，下一次以它为起点做时间平滑
    func liveMatch(for ci: CIImage, context: CIContext, previous: GradingParams?) -> GradingParams {
        var g = previous ?? base
        g.exposureEV = 0
        if let ref, let raw = StyleMatcher.stats(of: ci, context: context, maxSide: 96) {
            StyleMatcher.apply(to: &g, raw: raw, ref: ref, variant: variant, alpha: previous == nil ? 1 : 0.4)
        }
        return g
    }

    func renderState(from matched: GradingParams) -> StyleRenderer.State {
        var o = beauty.apply(effects.apply(variant.apply(matched)))
        o.cropRatio = nil
        return StyleRenderer.makeState(o, enabled: enabled)
    }

    func state(for ci: CIImage, context: CIContext) -> StyleRenderer.State {
        var g = base
        if resetExposure { g.exposureEV = 0 }
        if let ref, let raw = StyleMatcher.stats(of: ci, context: context, maxSide: 160) {
            StyleMatcher.apply(to: &g, raw: raw, ref: ref, variant: variant, alpha: 1)
        }
        if let tex = TextureEstimator.measure(ci, context: context) {
            if let refTexture {
                TextureEstimator.apply(to: &g, raw: tex, ref: refTexture)
            } else {
                TextureEstimator.applyGrainTarget(to: &g, raw: tex)
            }
        }
        var o = beauty.apply(effects.apply(variant.apply(g)))
        if !matchAspect { o.cropRatio = nil }
        return StyleRenderer.makeState(o, enabled: enabled)
    }
}
