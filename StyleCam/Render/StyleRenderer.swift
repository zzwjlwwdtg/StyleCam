import CoreImage
import CoreImage.CIFilterBuiltins

/// 渲染时用到的蒙版（白 = 是）
struct RenderMasks {
    var subject: CIImage?     // 主体：用于只虚化背景
    var person: CIImage?      // 人像：用于肤色保护 / 区域美颜
    var underEye: CIImage?    // 眼下区域（美颜档，人脸关键点定位）
}

/// 实时滤镜：背景虚化 → 3D LUT（含分区调色）→ 肤色保护 → 区域美颜 → 柔光 → 锐化 → 高光光晕 → 暗角 → 颗粒 → 画幅裁切。
/// 预览与成片共用同一条管线，保证所见即所得。
final class StyleRenderer: @unchecked Sendable {

    struct State {
        var params: GradingParams
        var lut: Data
        var skinLut: Data
        var enabled: Bool
        var skinAdjustLut: Data? = nil
        var personLut: Data? = nil       // 语义追色：人物（衣服 / 头发）
        var backgroundLut: Data? = nil   // 语义追色：背景
    }

    /// 由调色参数生成完整的渲染状态（所有 LUT）
    static func makeState(_ p: GradingParams, enabled: Bool = true) -> State {
        State(params: p, lut: LUTBuilder.build(p), skinLut: LUTBuilder.build(p, skinVersion: true),
              enabled: enabled, skinAdjustLut: LUTBuilder.buildSkinAdjust(p),
              personLut: LUTBuilder.buildRegionAdjust(p.regionPerson), backgroundLut: LUTBuilder.buildRegionAdjust(p.regionBG))
    }

    private let lock = NSLock()
    private var state = State(params: GradingParams(), lut: LUTBuilder.build(GradingParams()),
                              skinLut: LUTBuilder.build(GradingParams(), skinVersion: true), enabled: true)
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func update(_ p: GradingParams) {
        let lut = LUTBuilder.build(p)
        let skin = LUTBuilder.build(p, skinVersion: true)
        let adj = LUTBuilder.buildSkinAdjust(p)
        let pl = LUTBuilder.buildRegionAdjust(p.regionPerson), bl = LUTBuilder.buildRegionAdjust(p.regionBG)
        lock.lock()
        state.params = p; state.lut = lut; state.skinLut = skin; state.skinAdjustLut = adj
        state.personLut = pl; state.backgroundLut = bl
        lock.unlock()
    }

    func setEnabled(_ on: Bool) {
        lock.lock(); state.enabled = on; lock.unlock()
    }

    func snapshotState() -> State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// 是否需要人像蒙版 / 主体蒙版（调用方据此决定要不要跑分割）
    static func needsPersonMask(_ st: State) -> Bool {
        st.enabled && st.params.strength > 0
            && (st.params.skinProtect > 0.01 || st.params.hasSkinWork || st.params.regionPerson != nil || st.params.regionBG != nil)
    }
    static func needsFaceMask(_ st: State) -> Bool { st.enabled && st.params.strength > 0 && st.params.eyeBright > 0.01 }
    static func needsSubjectMask(_ st: State) -> Bool { st.enabled && st.params.backgroundBlur > 0.002 && st.params.strength > 0 }

    func apply(_ input: CIImage, state st: State, masks: RenderMasks = RenderMasks()) -> CIImage {
        guard st.enabled else { return input }
        let p = st.params
        let s = ColorMath.clamp(p.strength, 0, 1)
        let extent = input.extent
        // 以 1920px 长边为基准，让暗角/颗粒/锐化在预览和 48MP 成片里看起来一致
        let scale = max(1, max(extent.width, extent.height) / 1920)
        let longEdge = Double(max(extent.width, extent.height))
        var img = input

        // 1. 计算补足的背景虚化（先于调色，模拟光学虚化发生在镜头里）
        if p.backgroundBlur > 0.002 && s > 0, let mask = masks.subject {
            let sigma = p.backgroundBlur * longEdge / 4 * s          // 弥散圆直径 ≈ 4σ
            let background = mask.applyingFilter("CIColorInvert")
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(3 * scale))      // 羽化边缘，避免硬边
                .cropped(to: extent)
            let blur = CIFilter.maskedVariableBlur()
            blur.inputImage = img.clampedToExtent()
            blur.mask = background
            blur.radius = Float(sigma)
            img = blur.outputImage?.cropped(to: extent) ?? img
        }
        let ungraded = img

        // 2. 调色 LUT
        img = cube(ungraded, st.lut)

        // 皮肤蒙版：人像区域 × 肤色可能性（肤色保护和区域美颜共用）
        var skinMask: CIImage?
        if (p.skinProtect > 0.01 || p.hasSkinWork || p.regionPerson != nil) && s > 0, let person = masks.person {
            let likelihood = cube(ungraded, LUTBuilder.skinLikelihood)
            let personMask = person.clampedToExtent().applyingGaussianBlur(sigma: Double(2 * scale)).cropped(to: extent)
            let combined = CIFilter.multiplyCompositing()
            combined.inputImage = likelihood
            combined.backgroundImage = personMask
            skinMask = combined.outputImage?.cropped(to: extent)
        }

        // 3. 肤色保护：皮肤用“只调影调、不偏色”的版本
        if p.skinProtect > 0.01, let m = skinMask {
            img = blend(cube(ungraded, st.skinLut), over: img, mask: scaled(m, p.skinProtect), extent: extent)
        }

        // 3a. 语义追色：人物（衣服 / 头发）和背景各自向参考图靠拢
        if s > 0, let person = masks.person, st.personLut != nil || st.backgroundLut != nil {
            let pm = person.clampedToExtent().applyingGaussianBlur(sigma: Double(3 * scale)).cropped(to: extent)
            if let bl = st.backgroundLut {
                img = blend(cube(img, bl), over: img, mask: scaled(pm.applyingFilter("CIColorInvert"), s), extent: extent)
            }
            if let pl = st.personLut {
                var m = pm
                if let sm = skinMask {
                    let f = CIFilter.multiplyCompositing()
                    f.inputImage = pm
                    f.backgroundImage = sm.applyingFilter("CIColorInvert")
                    m = f.outputImage?.cropped(to: extent) ?? pm
                }
                img = blend(cube(img, pl), over: img, mask: scaled(m, s), extent: extent)
            }
        }

        // 3b. 区域美颜（只在皮肤上）
        if p.hasSkinWork, let m = skinMask {
            // 中性灰匀肤 + 自动祛痘：拉平中尺度明暗起伏，保留毛孔纹理
            if p.skinEven > 0.01 || p.blemish > 0.01 {
                let evened = Retoucher.evenSkin(img, skin: m, even: p.skinEven * s, blemish: p.blemish * s)
                img = blend(evened, over: img, mask: m, extent: extent)
            }
            // 柔肤：保边平滑（以原图为引导的上采样），五官和头发的边缘不被抹掉
            if p.skinSmooth > 0.01 {
                img = blend(edgeSmooth(img), over: img, mask: scaled(m, min(1, p.skinSmooth * 0.85) * s), extent: extent)
            }
            // 去暗沉（美颜档）：皮肤上的阴影提亮
            if p.skinClarity > 0.01 {
                let lifted = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputShadowAmount": 0.7 * p.skinClarity, "inputHighlightAmount": 1.0, "inputRadius": 8 * scale
                ]).cropped(to: extent)
                img = blend(lifted, over: img, mask: scaled(m, s), extent: extent)
            }
            // 肤色：提亮 / 冷白 / 奶油 / 粉嫩
            if let adj = st.skinAdjustLut {
                img = blend(cube(img, adj), over: img, mask: scaled(m, s), extent: extent)
            }
        }

        // 3c. 眼下提亮（美颜档）
        if p.eyeBright > 0.01 && s > 0, let eye = masks.underEye {
            let brighter = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.5 * p.eyeBright * s])
            let soft = edgeSmooth(brighter)
            img = blend(soft, over: img, mask: eye.cropped(to: extent), extent: extent)
        }

        // 4. 柔光
        if p.softGlow > 0.01 && s > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = img
            bloom.radius = Float(10 * scale)
            bloom.intensity = Float(p.softGlow * 0.8 * s)
            img = bloom.outputImage?.cropped(to: extent) ?? img
        }

        // 4b. 柔化（参考图比当前画面软时，按观看尺度换算到当前分辨率）
        if p.blurSigmaView > 0.05 && s > 0 {
            img = img.clampedToExtent()
                .applyingGaussianBlur(sigma: p.blurSigmaView * longEdge / 1440 * s)
                .cropped(to: extent)
        }

        // 5. 锐化
        if p.sharpen > 0.01 && s > 0 {
            let sh = CIFilter.sharpenLuminance()
            sh.inputImage = img
            sh.sharpness = Float(p.sharpen * 0.8 * s)
            sh.radius = Float(1.69 * pow(scale, 0.5))
            img = sh.outputImage ?? img
        }

        // 6. 胶片高光光晕（halation）：高光向外渗出的橙红色光
        if p.halation > 0.01 && s > 0 {
            img = addHalation(img, amount: p.halation * s, longEdge: longEdge)
        }

        // 7. 暗角
        if p.vignette > 0.01 && s > 0 {
            let v = CIFilter.vignette()
            v.inputImage = img
            v.intensity = Float(p.vignette * s)
            v.radius = 1.6
            img = v.outputImage ?? img
        }

        // 8. 颗粒
        // 颗粒：只补差值（观看尺度 σ），按标定换算成颗粒参数
        let grainAmount = p.grain * p.grainAddSigma / TextureEstimator.grainSigmaPerAmount
        if grainAmount > 0.01 && s > 0 {
            img = addGrain(img, amount: grainAmount * s, scale: scale)
        }

        img = img.cropped(to: extent)
        if let r = p.cropRatio, r > 1 { img = Self.centerCrop(img, ratio: r) }
        return img
    }

    private func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = top
        f.backgroundImage = bottom
        f.maskImage = mask
        return f.outputImage?.cropped(to: extent) ?? bottom
    }

    /// 蒙版整体乘一个系数
    private func scaled(_ m: CIImage, _ k: Double) -> CIImage {
        m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)
        ])
    }

    /// 保边平滑：缩小到约 360 长边并轻微模糊，再以原图为引导做保边上采样
    /// （平滑掉毛孔、细纹和小瑕疵，保留五官、发丝等明暗边缘）
    private func edgeSmooth(_ img: CIImage) -> CIImage {
        let e = img.extent
        let f = min(1, 360 / max(e.width, e.height))
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1])
            .clampedToExtent().applyingGaussianBlur(sigma: 0.8)
        let smallCropped = small.cropped(to: CGRect(x: e.minX * f, y: e.minY * f, width: e.width * f, height: e.height * f))
        let up = CIFilter.edgePreserveUpsample()
        up.inputImage = img
        up.smallImage = smallCropped
        up.spatialSigma = 3
        up.lumaSigma = 0.08
        return up.outputImage?.cropped(to: e) ?? img
    }

    private func cube(_ img: CIImage, _ data: Data) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = img
        f.cubeDimension = Float(LUTBuilder.dimension)
        f.cubeData = data
        f.colorSpace = srgb
        return f.outputImage ?? img
    }

    /// 沿画面长边方向裁成 长:短 = ratio
    static func centerCrop(_ img: CIImage, ratio r: Double) -> CIImage {
        let e = img.extent
        let w = Double(e.width), h = Double(e.height)
        let long = max(w, h), short = min(w, h)
        var nl = long, ns = long / r
        if ns > short { ns = short; nl = short * r }
        let (nw, nh) = w >= h ? (nl, ns) : (ns, nl)
        let rect = CGRect(x: Double(e.midX) - nw / 2, y: Double(e.midY) - nh / 2, width: nw, height: nh).integral
        return img.cropped(to: rect)
    }

    /// 高光光晕：取亮度 > 0.75 的部分 → 大半径模糊 → 染成橙红 → 叠加回去
    private func addHalation(_ img: CIImage, amount: Double, longEdge: Double) -> CIImage {
        let extent = img.extent
        // 只取真正的高光（亮度 > 0.85），亮度 1.0 时为满值
        let k: CGFloat = 6.67
        let luma = CIVector(x: 0.2126 * k, y: 0.7152 * k, z: 0.0722 * k, w: 0)
        let highlights = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -5.67, y: -5.67, z: -5.67, w: 1)
        ]).applyingFilter("CIColorClamp")
        let a = CGFloat(min(0.4, amount * 0.35))
        let glow = highlights
            .clampedToExtent()
            .applyingGaussianBlur(sigma: longEdge * 0.008)
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.0 * a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.35 * a, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.15 * a, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        // 用“滤色”叠加：结果 alpha 始终为 1（加法叠加会让 alpha 变成 2，后续滤镜反预乘后整张图被压暗）
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = glow
        screen.backgroundImage = img
        return screen.outputImage?.cropped(to: extent) ?? img
    }

    /// 胶片颗粒：两种尺度的单色噪声混合；按亮度调制，中间调最明显、高光和暗部较弱（与真实胶片一致）
    /// 注意：CIRandomGenerator 的 alpha 也是随机的，必须把 alpha 固定为 1，否则叠加后会变成大片黑白噪点
    private func addGrain(_ img: CIImage, amount: Double, scale: CGFloat) -> CIImage {
        let extent = img.extent
        let amp = CGFloat(min(0.28, amount * 0.2))           // 颗粒幅度（围绕 0.5 上下）
        func noiseLayer(size: CGFloat) -> CIImage? {
            guard let noise = CIFilter.randomGenerator().outputImage else { return nil }
            let w = amp / 3
            return noise
                .transformed(by: CGAffineTransform(scaleX: size, y: size))
                .transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0...512) + extent.minX,
                                                   y: CGFloat.random(in: 0...512) + extent.minY))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: w, y: w, z: w, w: 0),
                    "inputGVector": CIVector(x: w, y: w, z: w, w: 0),
                    "inputBVector": CIVector(x: w, y: w, z: w, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 1)
                ])
                .cropped(to: extent)
        }
        // 颗粒尺寸不随分辨率等比放大（否则 24/48MP 成片里会变成糊的斑块），只轻微增大
        let base = max(1, pow(scale, 0.5))
        guard let fine = noiseLayer(size: base),
              let coarse = noiseLayer(size: base * 1.8) else { return img }
        // 两层取加权平均（0.6 细 + 0.4 粗）
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = fine
        mix.targetImage = coarse
        mix.time = 0.25
        guard let grain = mix.outputImage?.cropped(to: extent).applyingFilter("CIColorClamp") else { return img }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = img
        guard let grained = blend.outputImage?.cropped(to: extent) else { return img }

        // 中间调蒙版：亮度经曲线 0→0.2, 0.5→1, 1→0.15
        let lumaV = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let mid = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": lumaV, "inputGVector": lumaV, "inputBVector": lumaV,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).applyingFilter("CIColorClamp").applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0.2),
            "inputPoint1": CIVector(x: 0.25, y: 0.75),
            "inputPoint2": CIVector(x: 0.5, y: 1),
            "inputPoint3": CIVector(x: 0.75, y: 0.7),
            "inputPoint4": CIVector(x: 1, y: 0.15)
        ])
        let out = CIFilter.blendWithMask()
        out.inputImage = grained
        out.backgroundImage = img
        out.maskImage = mid
        return out.outputImage?.cropped(to: extent) ?? grained
    }
}
