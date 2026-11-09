import CoreImage
import Vision
import CoreImage.CIFilterBuiltins

/// 皮肤精修：中性灰匀肤、自动祛痘、点修。
///
/// 中性灰（加深减淡）的思路：皮肤 = 大尺度肤色 × 中尺度明暗起伏（痘印、暗沉、凹凸）× 细节纹理（毛孔）。
/// 只把“中尺度起伏”拉平，细节纹理原样保留，所以不会像模糊磨皮那样塑料感。
/// 计算都在皮肤蒙版内做“归一化模糊”（只用皮肤像素求平均），眉眼、嘴唇、头发不会被混进来，边缘不出光晕。
enum Retoucher {
    /// 蒙版内的高斯模糊（预乘透明度后模糊）
    private static func premultipliedBlur(_ img: CIImage, mask: CIImage, sigma: Double) -> CIImage {
        let e = img.extent
        let f = CIFilter.blendWithMask()
        f.inputImage = img
        f.backgroundImage = CIImage.empty().cropped(to: e)
        f.maskImage = mask
        return (f.outputImage ?? img).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
    }

    /// 皮肤用：蒙版内模糊，再叠回原图（蒙版外 / 边缘保持原图）——不会出现除以零
    static func maskedBlur(_ img: CIImage, mask: CIImage, sigma: Double) -> CIImage {
        premultipliedBlur(img, mask: mask, sigma: sigma).composited(over: img).cropped(to: img.extent)
    }

    /// 点修用：真正的归一化卷积 blur(img·m) / blur(m)
    static func normalizedBlur(_ img: CIImage, mask: CIImage, sigma: Double) -> CIImage {
        premultipliedBlur(img, mask: mask, sigma: sigma).applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// 自定义 Core Image 滤镜（RetouchKernels.ci.metal）
    private static let kernels: (dodge: CIColorKernel?, heal: CIColorKernel?) = {
        guard let url = Bundle(for: KernelBundle.self).url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return (nil, nil) }
        return (try? CIColorKernel(functionName: "scDodgeBurn", fromMetalLibraryData: data),
                try? CIColorKernel(functionName: "scHealTexture", fromMetalLibraryData: data))
    }()
    private final class KernelBundle {}
    static var kernelsLoaded: Bool { kernels.dodge != nil && kernels.heal != nil }

    /// 画面里有代表性的脸宽（像素）：取最大的脸；没检测到脸时按画面长边的 15% 估计
    static func typicalFaceWidth(_ faces: [CGRect], extent: CGRect) -> CGFloat {
        faces.map { max($0.width, $0.height) }.max() ?? max(extent.width, extent.height) * 0.15
    }

    /// 脸越小，磨皮越弱：脸宽 60 像素以下几乎不磨，240 像素以上全强度
    static func sizeFactor(_ faceW: CGFloat) -> Double {
        ColorMath.smoothstep(60, 240, Double(faceW))
    }

    /// 中性灰匀肤 + 自动祛痘。even：拉平程度 0…1；blemish：祛痘强度 0…1；faceWidth：脸宽（像素），决定处理的尺度
    static func evenSkin(_ img: CIImage, skin: CIImage, even: Double, blemish: Double, faceWidth: CGFloat? = nil) -> CIImage {
        let e = img.extent
        guard let k = kernels.dodge, even > 0.01 || blemish > 0.01 else { return img }
        let fw = Double(faceWidth ?? max(e.width, e.height) * 0.15)
        // 毛孔约为脸宽的 1%，痘印 / 暗沉约 3%～8%：细尺度只去毛孔，粗尺度只保留大块肤色
        let fine = maskedBlur(img, mask: skin, sigma: max(0.7, fw * 0.010))
        let broad = maskedBlur(img, mask: skin, sigma: max(2.5, fw * 0.065))
        return k.apply(extent: e, arguments: [img, fine, broad, Float(even), Float(blemish)])?.cropped(to: e) ?? img
    }

    /// 点修：每个点用周围皮肤补平（大尺度颜色取圆环内的平均，纹理借用旁边一块）
    static func heal(_ img: CIImage, spots: [(center: CGPoint, radius: CGFloat)]) -> CIImage {
        var out = img
        let e = img.extent
        for s in spots {
            let r = max(2, s.radius)
            // 圆形软蒙版（中心 1，边缘渐出）
            let disk = CIFilter.radialGradient()
            disk.center = s.center
            disk.radius0 = Float(r * 0.75)
            disk.radius1 = Float(r * 1.25)
            disk.color0 = CIColor.white
            disk.color1 = CIColor.black
            guard let spotMask = disk.outputImage?.cropped(to: e) else { continue }
            let inverse = spotMask.applyingFilter("CIColorInvert")
            // 大尺度颜色：只用圆外的像素求平均，填进圆里
            let fill = normalizedBlur(out, mask: inverse, sigma: Double(r) * 0.9)
            // 纹理：从旁边（右侧 2.2r，靠近边界就换左侧）借一块的细纹理，比值限制在 ±20%
            let dx: CGFloat = (s.center.x + r * 3 < e.maxX) ? r * 2.2 : -r * 2.2
            let donor = out.transformed(by: CGAffineTransform(translationX: -dx, y: 0)).cropped(to: e)
            let donorBlur = donor.clampedToExtent().applyingGaussianBlur(sigma: Double(r) * 0.25).cropped(to: e)
            let healed = kernels.heal?.apply(extent: e, arguments: [fill, donor, donorBlur]) ?? fill
            out = blend(healed, over: out, mask: spotMask)
        }
        return out.cropped(to: e)
    }

    /// 人脸框（图像坐标）
    static func faces(in img: CIImage) -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(ciImage: img, options: [:]).perform([req])) != nil else { return [] }
        let e = img.extent
        return (req.results ?? []).map {
            CGRect(x: e.minX + $0.boundingBox.minX * e.width, y: e.minY + $0.boundingBox.minY * e.height,
                   width: $0.boundingBox.width * e.width, height: $0.boundingBox.height * e.height)
        }
    }

    /// 人像分割失败时的退路：每张脸画一个覆盖整张脸和下巴的椭圆
    static func faceEllipseMask(_ faces: [CGRect], extent: CGRect) -> CIImage? {
        guard !faces.isEmpty else { return nil }
        var out = CIImage(color: .black).cropped(to: extent)
        for f in faces {
            let g = CIFilter.radialGradient()
            g.center = .zero; g.radius0 = 0.8; g.radius1 = 1
            g.color0 = CIColor.white; g.color1 = CIColor.black
            guard let unit = g.outputImage else { continue }
            let ell = unit.transformed(by: CGAffineTransform(scaleX: f.width * 0.78, y: f.height * 1.0)
                .concatenating(CGAffineTransform(translationX: f.midX, y: f.midY - f.height * 0.08))).cropped(to: extent)
            let mx = CIFilter.maximumCompositing()
            mx.inputImage = ell; mx.backgroundImage = out
            out = mx.outputImage?.cropped(to: extent) ?? out
        }
        return out
    }

    /// 整张照片的皮肤蒙版：人像分割（失败时用人脸椭圆）× 肤色可能性
    static func skinMask(for img: CIImage, faces: [CGRect]? = nil) -> CIImage? {
        let fs = faces ?? Self.faces(in: img)
        guard let person = SemanticStats.personMask(for: img) ?? faceEllipseMask(fs, extent: img.extent) else { return nil }
        let e = img.extent
        let likely = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": LUTBuilder.dimension,
            "inputCubeData": LUTBuilder.skinLikelihood,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any
        ]).cropped(to: e)
        let soft = person.clampedToExtent().applyingGaussianBlur(sigma: Double(max(e.width, e.height)) / 600).cropped(to: e)
        let closed = closeHoles(likely, longEdge: max(e.width, e.height))
        let base = multiply(closed, soft)
        // 脸部范围内用人脸分区模型修正（五官、发丝不算皮肤）
        if let fp = FaceParser.parse(img, faces: fs) { return FaceParser.refine(base, likelihood: closed, parsed: fp) }
        return base
    }

    /// 填掉肤色蒙版里的小洞（痘痘、斑点本身颜色可能不像皮肤），眼睛、眉毛、嘴这类大块不受影响
    static func closeHoles(_ m: CIImage, longEdge: CGFloat) -> CIImage {
        let r = max(1, Double(longEdge) * 0.004)
        let e = m.extent
        return m.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
            .cropped(to: e)
    }

    // MARK: - 小工具

    static func divide(_ a: CIImage, by b: CIImage) -> CIImage {
        // CIDivideBlendMode：背景 / 输入；两边都加一点点，避免纯黑处除以零
        let eps: (CIImage) -> CIImage = {
            $0.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.002, y: 0.002, z: 0.002, w: 0)])
        }
        let f = CIFilter.divideBlendMode()
        f.inputImage = eps(b)
        f.backgroundImage = eps(a)
        return (f.outputImage ?? a).cropped(to: a.extent)
    }

    /// 逐通道限制在 [lo, hi]（CIColorClamp 会把上限截到 1，比值图不能用它）
    static func clamp(_ img: CIImage, _ lo: CGFloat, _ hi: CGFloat) -> CIImage {
        let e = img.extent
        let hiImg = CIImage(color: CIColor(red: hi, green: hi, blue: hi, alpha: 1)).cropped(to: e)
        let loImg = CIImage(color: CIColor(red: lo, green: lo, blue: lo, alpha: 1)).cropped(to: e)
        let mn = CIFilter.minimumCompositing()
        mn.inputImage = img; mn.backgroundImage = hiImg
        let mx = CIFilter.maximumCompositing()
        mx.inputImage = mn.outputImage ?? img; mx.backgroundImage = loImg
        return (mx.outputImage ?? img).cropped(to: e)
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.multiplyCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return (f.outputImage ?? a).cropped(to: a.extent)
    }

    static func power(_ a: CIImage, _ k: Double) -> CIImage {
        a.applyingFilter("CIGammaAdjust", parameters: ["inputPower": k])
    }

    static func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = top
        f.backgroundImage = bottom
        f.maskImage = mask
        return (f.outputImage ?? bottom).cropped(to: bottom.extent)
    }
}
