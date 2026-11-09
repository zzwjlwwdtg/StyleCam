import CoreImage
import CoreML
import Vision

/// 人脸分区（开源 BiSeNet 人脸解析模型，本地运行）：
/// 每张脸裁一个方块送进模型，得到“皮肤”和“需要保护的五官 / 头发”两张图，再贴回原图位置。
/// 精修时脸部范围内以模型为准——眉毛、眼睛、嘴唇、发丝不会再因为颜色像皮肤而被磨到。
enum FaceParser {
    private final class Token {}

    private static let model: VNCoreMLModel? = {
        guard let url = Bundle(for: Token.self).url(forResource: "FaceParsing", withExtension: "mlmodelc") else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let m = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
        return try? VNCoreMLModel(for: m)
    }()

    static var available: Bool { model != nil }

    struct Result {
        let skin: CIImage      // 脸部范围内的皮肤概率（全图坐标）
        let protect: CIImage   // 五官 / 头发
        let region: CIImage    // 模型覆盖到的范围（边缘柔和）
    }

    /// faces：人脸框（图像坐标）
    static func parse(_ img: CIImage, faces: [CGRect]) -> Result? {
        guard let model, !faces.isEmpty else { return nil }
        let e = img.extent
        let black = CIImage(color: .black).cropped(to: e)
        var skin = black, protect = black, region = black
        for f in faces {
            // 和训练数据（CelebA 对齐人脸）接近：脸约占方块的一半，略向上留出额头和头发
            let side = max(f.width, f.height) * 2.0
            let sq = CGRect(x: f.midX - side / 2, y: f.midY - side / 2 + f.height * 0.05, width: side, height: side)
            let crop = img.clampedToExtent().cropped(to: sq)
                .transformed(by: CGAffineTransform(translationX: -sq.minX, y: -sq.minY))
            let req = VNCoreMLRequest(model: model)
            req.imageCropAndScaleOption = .scaleFill
            guard (try? VNImageRequestHandler(ciImage: crop, options: [:]).perform([req])) != nil,
                  let obs = req.results as? [VNPixelBufferObservation] else { continue }
            func place(_ name: String) -> CIImage? {
                guard let pb = obs.first(where: { $0.featureName == name })?.pixelBuffer else { return nil }
                let m = CIImage(cvPixelBuffer: pb)
                return m.transformed(by: CGAffineTransform(scaleX: side / m.extent.width, y: side / m.extent.height)
                    .concatenating(CGAffineTransform(translationX: sq.minX, y: sq.minY))).cropped(to: e)
            }
            guard let s = place("skin"), let p = place("protect") else { continue }
            skin = maxOf(s, skin, e)
            protect = maxOf(p, protect, e)
            let r = CIImage(color: .white).cropped(to: sq.insetBy(dx: side * 0.08, dy: side * 0.08))
                .clampedToExtent().applyingGaussianBlur(sigma: Double(side) * 0.04).cropped(to: e)
            region = maxOf(r.composited(over: black), region, e)
        }
        return Result(skin: skin, protect: protect, region: region)
    }

    /// 用人脸解析修正皮肤蒙版：脸部范围内 = max(模型皮肤, 颜色判断的皮肤 × (1 − 五官))，范围外保持原样
    static func refine(_ base: CIImage, likelihood: CIImage, parsed: Result) -> CIImage {
        let e = base.extent
        let notFeature = parsed.protect.applyingFilter("CIColorInvert")
        let colorSkin = Retoucher.multiply(likelihood, notFeature)
        let inFace = maxOf(parsed.skin, colorSkin, e)
        return Retoucher.blend(inFace, over: base, mask: parsed.region)
    }

    private static func maxOf(_ a: CIImage, _ b: CIImage, _ e: CGRect) -> CIImage {
        let f = CIFilter(name: "CIMaximumCompositing")!
        f.setValue(a, forKey: kCIInputImageKey)
        f.setValue(b, forKey: kCIInputBackgroundImageKey)
        return (f.outputImage ?? a).cropped(to: e)
    }
}
