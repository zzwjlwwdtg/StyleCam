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
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: outData as Data, options: nil)
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
}
