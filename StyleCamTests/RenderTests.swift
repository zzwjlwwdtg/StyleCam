import XCTest
import CoreImage
import UIKit
@testable import StyleCam

/// 在 iPhone 模拟器里用 App 的同一套代码跑完整流程：
/// 参考图分析 → 参数规划 → 各种效果组合渲染 → 输出图片 + 统计（亮度、压黑比例、alpha 是否异常）
final class RenderTests: XCTestCase {

    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func testRenderPipeline() throws {
        let bundle = Bundle(for: RenderTests.self)
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var report = ""

        // 1. 参考图分析
        let refURL = try XCTUnwrap(bundle.url(forResource: "reference", withExtension: "jpg"))
        let (profile, _) = try StyleAnalyzer.analyze(data: Data(contentsOf: refURL))
        report += "== 参考图分析 ==\n" + describe(profile) + "\n参考图分位: \(profile.refStats.quantiles.map { Int($0.rounded()) }) 彩度 \(fmt(profile.refStats.chroma))\n"

        // 2. 参数规划（模拟 18 Pro Max 主摄能力）
        let caps = HardwareCapabilities(
            deviceName: "Simulator", apertureStops: [1.48, 1.8, 2.8, 4], apertureRange: 1.48...4,
            isoRange: 50...6400, shutterRange: 0.0001...1, biasRange: -8...8,
            supportedSignals: [], supportsCustomWB: true, supportsGlobalToneMapping: true, photoDimensions: [])
        let before = DeviceSnapshot(lens: .wide, aperture: 1.48, shutter: 1.0 / 60, iso: 200, bias: 0,
                                    wb: TempTint(temperature: 5000, tint: 0), enabledSignals: [], globalToneMapping: false)
        let (lens, why) = ParameterPlanner.chooseLens(profile: profile)
        let (plan, changes) = ParameterPlanner.makePlan(profile: profile, lens: lens, lensReason: why, caps: caps, before: before)
        report += "== 参数规划 ==\n镜头 \(lens.rawValue)：\(why)\n"
        for c in changes { report += "- [\(c.category.rawValue)] \(c.name)：\(c.before) → \(c.after)\n" }
        report += "grading: \(plan.grading)\n\n"

        // 3. 场景渲染：逐个效果组合
        var configs: [(String, EffectToggles)] = [("01_full", EffectToggles())]
        func only(_ name: String, _ body: (inout EffectToggles) -> Void) {
            var e = EffectToggles(); body(&e); configs.append((name, e))
        }
        only("02_no_halation") { $0.halation = false }
        only("03_no_grain") { $0.grain = false }
        only("04_no_skin") { $0.skin = false }
        only("05_no_region") { $0.region = false }
        only("06_no_bokeh") { $0.bokeh = false }
        only("07_no_tone") { $0.toneColor = false }
        only("08_none") {
            $0.halation = false; $0.grain = false; $0.skin = false; $0.region = false
            $0.bokeh = false; $0.toneColor = false; $0.vignette = false
        }

        let scenes = (bundle.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("scene") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(scenes.isEmpty)

        for url in scenes {
            let scene = url.deletingPathExtension().lastPathComponent
            let ci = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
            report += "== 场景 \(scene) ==\n输入: \(stats(ci))\n"
            try save(ci, outDir.appendingPathComponent("\(scene)_00_input.jpg"))

            for (name, fx) in configs {
                for variant in (name == "01_full" ? StyleVariant.allCases : [.faithful]) {
                    let renderer = StyleRenderer()
                    // 模拟实时匹配：用未调色画面的统计对齐参考图
                    var matched = plan.grading
                    if let raw = StyleMatcher.stats(of: ci, context: ctx) {
                        StyleMatcher.apply(to: &matched, raw: raw, ref: profile.refStats, variant: variant, alpha: 1)
                    }
                    var g = fx.apply(variant.apply(matched))
                    g.cropRatio = nil
                    renderer.update(g)
                    let st = renderer.snapshotState()
                    let out = renderer.apply(ci, state: st, masks: PhotoProcessor.masks(for: ci, state: st, preferPerson: true))
                    let tag = name + (variant == .faithful ? "" : "_\(variant.rawValue)")
                    report += "\(tag): \(stats(out))\n"
                    try save(out, outDir.appendingPathComponent("\(scene)_\(tag).jpg"))
                }
            }

            // 相册套用路径（按照片自适应）
            let renderer = StyleRenderer()
            var base = plan.grading
            base.cropRatio = nil
            renderer.update(base)
            let adapted = PhotoProcessor.adaptedState(renderer.snapshotState(), for: ci, ref: profile.refStats, variant: .faithful)
            let out = renderer.apply(ci, state: adapted, masks: PhotoProcessor.masks(for: ci, state: adapted, preferPerson: true))
            report += "09_album_adapted: \(stats(out))  (EV \(String(format: "%.2f", adapted.params.exposureEV)), sat \(String(format: "%.2f", adapted.params.saturation)), cast \(String(format: "%.1f/%.1f", adapted.params.castA, adapted.params.castB)))\n\n"
            try save(out, outDir.appendingPathComponent("\(scene)_09_album_adapted.jpg"))
        }

        try report.write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    // MARK: - 工具

    private func describe(_ p: StyleProfile) -> String {
        """
        亮度中位 L*\(fmt(p.medianL)) 黑位 \(fmt(p.blackPoint)) 白位 \(fmt(p.whitePoint)) 对比 \(fmt(p.contrast)) 褪色 \(fmt(p.shadowLift)) 高光压 \(fmt(p.highlightRolloff))
        饱和 \(fmt(p.saturation)) 色偏 a\(fmt(p.castA)) b\(fmt(p.castB)) 暗部 \(p.shadowTint) 高光 \(p.highlightTint)
        暗角 \(fmt(p.vignette)) 颗粒 \(fmt(p.grain)) 锐度 \(fmt(p.sharpness)) 景深 \(p.depthOfField.rawValue) 人脸 \(p.faceCount) 点光源 \(p.pointLightCount)
        光学: \(p.optics.summary) 依据 \(p.optics.source.rawValue) 主体σ \(fmt(p.optics.subjectSigma)) 远景超出σ \(fmt(p.optics.backgroundSigma)) 分割 \(p.optics.subjectMaskFound)
        画幅 \(fmt(p.aspect)) 横幅 \(p.isLandscape) 人脸框 \(String(describing: p.faceRect)) 主体框 \(String(describing: p.subjectRect))
        植物 \(String(describing: p.greenAB)) 天空 \(String(describing: p.skyAB))
        """
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// 统计：alpha 范围（检测 alpha≠1 的 bug）、L* 中位数、压黑比例（L*<5）、过曝比例（L*>98）、平均彩度
    private func stats(_ img: CIImage) -> String {
        let e = img.extent
        let s = 256 / max(e.width, e.height)
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        let w = Int(small.extent.width), h = Int(small.extent.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { ptr in
            ctx.render(small, toBitmap: ptr.baseAddress!, rowBytes: w * 16,
                       bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                       format: .RGBAf, colorSpace: srgb)
        }
        var aMin: Float = 9, aMax: Float = -9
        var Ls: [Double] = [], chroma = 0.0, dark = 0, bright = 0
        // 只统计内部区域（避开 Lanczos 边缘）
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) {
                let i = (y * w + x) * 4
                let a = buf[i + 3]
                aMin = min(aMin, a); aMax = max(aMax, a)
                let r = ColorMath.srgbToLinear(Double(min(max(buf[i], 0), 1)))
                let g = ColorMath.srgbToLinear(Double(min(max(buf[i + 1], 0), 1)))
                let b = ColorMath.srgbToLinear(Double(min(max(buf[i + 2], 0), 1)))
                let lab = ColorMath.linearRGBToLab(r, g, b)
                Ls.append(lab.L)
                chroma += (lab.a * lab.a + lab.b * lab.b).squareRoot()
                if lab.L < 5 { dark += 1 }
                if lab.L > 98 { bright += 1 }
            }
        }
        let n = Double(Ls.count)
        let sorted = Ls.sorted()
        let q = [0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99].map { Int(ColorMath.percentile(sorted, $0).rounded()) }
        return String(format: "alpha[%.2f,%.2f] L*中位 %.1f 压黑 %.1f%% 过曝 %.1f%% 彩度 %.1f 分位 ",
                      aMin, aMax, ColorMath.median(Ls), Double(dark) / n * 100, Double(bright) / n * 100, chroma / n) + "\(q)"
    }

    private func save(_ img: CIImage, _ url: URL) throws {
        let e = img.extent
        let s = min(1, 900 / max(e.width, e.height))
        let scaled = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        // 与取景器一致：叠在黑底上
        let flat = scaled.composited(over: CIImage(color: .black).cropped(to: scaled.extent))
        try ctx.writeJPEGRepresentation(of: flat, to: url, colorSpace: srgb,
                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }
}
