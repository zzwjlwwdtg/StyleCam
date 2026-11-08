import CoreImage
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

    /// 中性灰匀肤 + 自动祛痘。even：拉平程度 0…1；blemish：祛痘强度 0…1
    static func evenSkin(_ img: CIImage, skin: CIImage, even: Double, blemish: Double) -> CIImage {
        let e = img.extent
        let L = Double(max(e.width, e.height))
        let fine = maskedBlur(img, mask: skin, sigma: max(1, L * 0.0013))   // 去掉毛孔级纹理
        let broad = maskedBlur(img, mask: skin, sigma: max(4, L * 0.009))   // 只剩大尺度肤色
        // ratio = broad / fine：起伏处偏离 1（暗斑 > 1，亮斑 < 1）
        let ratio = divide(broad, by: fine).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0.6, y: 0.6, z: 0.6, w: 1),
            "inputMaxComponents": CIVector(x: 1.6, y: 1.6, z: 1.6, w: 1)
        ])
        var out = img
        if even > 0.01 {
            // img × ratio^k：k=1 完全拉平中尺度起伏，纹理（img / fine）保留
            let k = min(1, even) * 0.85
            out = multiply(img, power(ratio, k))
        }
        if blemish > 0.01 {
            // 痘痘 / 斑点：比周围明显暗的小区域 → ratio 的亮度明显大于 1
            let spot = ratio
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0),
                    "inputGVector": CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0),
                    "inputBVector": CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0),
                    "inputBiasVector": CIVector(x: -1.04, y: -1.04, z: -1.04, w: 0)
                ])
                .applyingFilter("CIColorMatrix", parameters: [      // (ratio - 1.04) × 9 → 约 4%…15% 的暗斑渐入
                    "inputRVector": CIVector(x: 9, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 9, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 9, w: 0)
                ])
                .applyingFilter("CIColorClamp")
                .clampedToExtent().applyingGaussianBlur(sigma: max(1, L * 0.0012)).cropped(to: e)
            let spotMask = multiply(spot, skin).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: min(1, blemish) * 1.6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: min(1, blemish) * 1.6, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: min(1, blemish) * 1.6, w: 0)
            ]).applyingFilter("CIColorClamp")
            // 斑点处：完全拉平并轻微柔化
            let healed = multiply(img, ratio)
            out = blend(healed, over: out, mask: spotMask)
        }
        return out.cropped(to: e)
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
            // 纹理：从旁边（右侧 2.2r，靠近边界就换左侧）借一块的“细节 / 平均”
            let dx: CGFloat = (s.center.x + r * 3 < e.maxX) ? r * 2.2 : -r * 2.2
            let donor = out.transformed(by: CGAffineTransform(translationX: -dx, y: 0)).cropped(to: e)
            // 只借细纹理：比值限制在 ±20%，不把旁边的树枝、边缘等结构搬过来
            let donorTexture = divide(donor, by: donor.clampedToExtent().applyingGaussianBlur(sigma: Double(r) * 0.25).cropped(to: e))
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0.82, y: 0.82, z: 0.82, w: 1),
                    "inputMaxComponents": CIVector(x: 1.2, y: 1.2, z: 1.2, w: 1)
                ])
            let healed = multiply(fill, donorTexture)
            out = blend(healed, over: out, mask: spotMask)
        }
        return out.cropped(to: e)
    }

    /// 整张照片的皮肤蒙版：人像分割 × 肤色可能性
    static func skinMask(for img: CIImage) -> CIImage? {
        guard let person = SemanticStats.personMask(for: img) else { return nil }
        let e = img.extent
        let likely = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": LUTBuilder.dimension,
            "inputCubeData": LUTBuilder.skinLikelihood,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any
        ]).cropped(to: e)
        let soft = person.clampedToExtent().applyingGaussianBlur(sigma: Double(max(e.width, e.height)) / 600).cropped(to: e)
        return multiply(closeHoles(likely, longEdge: max(e.width, e.height)), soft)
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
