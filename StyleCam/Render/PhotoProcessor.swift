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
                        refTexture: TextureStats? = nil,
                        completion: @escaping (UIImage?, String?) -> Void) {
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            completion(nil, "照片解码失败"); return
        }
        // 质感按这张照片本身重新算差值（成片的降噪/锐化与取景帧不同）
        var state = state
        if let refTexture, let tex = TextureEstimator.measure(ci, context: context) {
            TextureEstimator.apply(to: &state.params, raw: tex, ref: refTexture)
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

    /// 已有照片没有实时匹配，所以按这张照片本身的统计做一次风格匹配（与实时预览同一套 StyleMatcher）
    static func adaptedState(_ base: StyleRenderer.State, for ci: CIImage, ref: SceneStats, variant: StyleVariant) -> StyleRenderer.State {
        guard let raw = StyleMatcher.stats(of: ci, context: context, maxSide: 160) else { return base }
        var p = base.params
        p.exposureEV = 0
        StyleMatcher.apply(to: &p, raw: raw, ref: ref, variant: variant, alpha: 1)
        return StyleRenderer.State(params: p, lut: LUTBuilder.build(p),
                                   skinLut: LUTBuilder.build(p, skinVersion: true), enabled: base.enabled)
    }

    /// 读取已有照片（保留原 EXIF）→ 自适应 → 套用 → 另存为新照片（原图不动）
    static func processExisting(data: Data, renderer: StyleRenderer, base: StyleRenderer.State,
                                ref: SceneStats, refTexture: TextureStats?, variant: StyleVariant, preferPerson: Bool,
                                summary: String, completion: @escaping (UIImage?, String?) -> Void) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            completion(nil, "无法读取照片"); return
        }
        let state = adaptedState(base, for: ci, ref: ref, variant: variant)
        process(data: data, metadata: props, renderer: renderer, state: state, summary: summary,
                preferPerson: preferPerson, saveOriginal: false, refTexture: refTexture, completion: completion)
    }
}
