import CoreImage
import CoreImage.CIFilterBuiltins

/// 实时滤镜：3D LUT → 柔光 → 锐化 → 暗角 → 颗粒。预览与成片共用同一条管线，保证所见即所得。
final class StyleRenderer: @unchecked Sendable {

    struct State {
        var params: GradingParams
        var lut: Data
        var enabled: Bool
    }

    private let lock = NSLock()
    private var state = State(params: GradingParams(), lut: LUTBuilder.build(GradingParams()), enabled: true)
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func update(_ p: GradingParams) {
        let lut = LUTBuilder.build(p)
        lock.lock(); state.params = p; state.lut = lut; lock.unlock()
    }

    func setEnabled(_ on: Bool) {
        lock.lock(); state.enabled = on; lock.unlock()
    }

    func snapshotState() -> State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// subjectMask：主体蒙版（白 = 主体），用于只虚化背景
    func apply(_ input: CIImage, state st: State, subjectMask: CIImage? = nil) -> CIImage {
        guard st.enabled else { return input }
        let p = st.params
        let s = ColorMath.clamp(p.strength, 0, 1)
        let extent = input.extent
        // 以 1920px 长边为基准，让暗角/颗粒/锐化在预览和 48MP 成片里看起来一致
        let scale = max(1, max(extent.width, extent.height) / 1920)
        var img = input

        // 计算补足的背景虚化（先于调色，模拟光学虚化发生在镜头里）
        if p.backgroundBlur > 0.002 && s > 0, let mask = subjectMask {
            let longEdge = Double(max(extent.width, extent.height))
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

        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = img
        cube.cubeDimension = Float(LUTBuilder.dimension)
        cube.cubeData = st.lut
        cube.colorSpace = srgb
        img = cube.outputImage ?? img

        if p.softGlow > 0.01 && s > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = img
            bloom.radius = Float(10 * scale)
            bloom.intensity = Float(p.softGlow * 0.8 * s)
            img = bloom.outputImage?.cropped(to: extent) ?? img
        }

        if p.sharpen > 0.01 && s > 0 {
            let sh = CIFilter.sharpenLuminance()
            sh.inputImage = img
            sh.sharpness = Float(p.sharpen * 0.8 * s)
            sh.radius = Float(1.69 * scale)
            img = sh.outputImage ?? img
        }

        if p.vignette > 0.01 && s > 0 {
            let v = CIFilter.vignette()
            v.inputImage = img
            v.intensity = Float(p.vignette * 1.4 * s)
            v.radius = 1.6
            img = v.outputImage ?? img
        }

        if p.grain > 0.01 && s > 0 {
            img = addGrain(img, amount: p.grain * s, scale: scale)
        }

        img = img.cropped(to: extent)
        if let r = p.cropRatio, r > 1 { img = Self.centerCrop(img, ratio: r) }
        return img
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

    /// 单色胶片颗粒：随机噪声 → 灰度 → 柔光叠加
    private func addGrain(_ img: CIImage, amount: Double, scale: CGFloat) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return img }
        let grainSize = scale * 1.2
        let moved = noise
            .transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
            .transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0...512), y: CGFloat.random(in: 0...512)))
            .transformed(by: CGAffineTransform(translationX: img.extent.minX, y: img.extent.minY))

        let amp = CGFloat(min(0.4, amount * 0.3))
        let w = amp / 3
        let mono = CIFilter.colorMatrix()
        mono.inputImage = moved
        mono.rVector = CIVector(x: w, y: w, z: w, w: 0)
        mono.gVector = CIVector(x: w, y: w, z: w, w: 0)
        mono.bVector = CIVector(x: w, y: w, z: w, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        mono.biasVector = CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 0)
        guard let grain = mono.outputImage?.cropped(to: img.extent) else { return img }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = img
        return blend.outputImage ?? img
    }
}
