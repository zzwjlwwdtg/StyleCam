import XCTest
import CoreImage
import UIKit
import SwiftUI
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
        report += String(format: "参考图质感: 颗粒σ %.4f 边缘 %.2f 暗角 %.2f\n", profile.refTexture.grain, profile.refTexture.edge, profile.refTexture.vignette)
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
            let it = TextureEstimator.measure(ci, context: ctx)
            report += "== 场景 \(scene) ==\n输入: \(stats(ci))" + String(format: " | 颗粒σ %.4f 边缘 %.2f 暗角 %.2f\n", it?.grain ?? -1, it?.edge ?? -1, it?.vignette ?? -1)
            try save(ci, outDir.appendingPathComponent("\(scene)_00_input.jpg"))

            for (name, fx) in configs {
                for variant in (name == "01_full" ? StyleVariant.allCases : [.faithful]) {
                    let renderer = StyleRenderer()
                    // 模拟实时匹配：用未调色画面的统计对齐参考图
                    var matched = plan.grading
                    if let raw = StyleMatcher.stats(of: ci, context: ctx) {
                        StyleMatcher.apply(to: &matched, raw: raw, ref: profile.refStats, variant: variant, alpha: 1)
                    }
                    if let tex = TextureEstimator.measure(ci, context: ctx) {
                        TextureEstimator.apply(to: &matched, raw: tex, ref: profile.refTexture)
                    }
                    var g = fx.apply(variant.apply(matched))
                    g.cropRatio = nil
                    renderer.update(g)
                    let st = renderer.snapshotState()
                    let out = renderer.apply(ci, state: st, masks: PhotoProcessor.masks(for: ci, state: st, preferPerson: true))
                    let tag = name + (variant == .faithful ? "" : "_\(variant.rawValue)")
                    let ot = TextureEstimator.measure(out, context: ctx)
                    report += "\(tag): \(stats(out))" + String(format: " | 颗粒σ %.4f 边缘 %.2f 暗角 %.2f [补颗粒 %.4f 柔化 %.2f 锐化 %.2f 暗角 %.2f]\n",
                        ot?.grain ?? -1, ot?.edge ?? -1, ot?.vignette ?? -1, g.grainAddSigma * g.grain, g.blurSigmaView, g.sharpen, g.vignette)
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

// MARK: - 颗粒标定：不同输出分辨率下，颗粒参数 → 观看尺度（长边 1440）测到的 σ
final class GrainCalibrationTests: XCTestCase {
    func testGrainCalibration() throws {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let bundle = Bundle(for: GrainCalibrationTests.self)
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var report = "== 实拍/参考图在观看尺度（长边1440）的颗粒 σ ==\n"
        for name in ["noise_reference", "noise_iphone_stock", "noise_stylecam_rich"] {
            guard let url = bundle.url(forResource: name, withExtension: "jpg"),
                  let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { continue }
            let native = GrainEstimator.sigma(of: ci, context: ctx, jpegGridAligned: true) ?? -1
            let noGrid = GrainEstimator.sigma(of: ci, context: ctx, jpegGridAligned: false) ?? -1
            report += String(format: "%@ %.0fx%.0f  σ(排除块边界)=%.4f  σ(不排除)=%.4f\n",
                             name, ci.extent.width, ci.extent.height, native, noGrid)
        }
        report += "\n== 标定：灰度 0.5 平面，颗粒 amount → σ ==\n"
        for long in [1440.0, 1920.0, 4032.0, 5712.0, 8064.0] {
            let rect = CGRect(x: 0, y: 0, width: long * 0.75, height: long)
            let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: rect)
            var line = String(format: "长边 %5.0f:", long)
            for amount in [0.1, 0.3, 0.6, 1.0] {
                var p = GradingParams()
                p.grain = amount
                p.skinProtect = 0
                let r = StyleRenderer()
                r.update(p)
                let out = r.apply(gray, state: r.snapshotState())
                let s = GrainEstimator.sigma(of: out, context: ctx) ?? -1
                line += String(format: "  a%.1f→σ%.4f", amount, s)
            }
            report += line + "\n"
        }
        report += "\n== 标定：暗角 intensity → 四角/中心（灰 0.5）==\n"
        for v in [0.1, 0.25, 0.5, 1.0] {
            let rect = CGRect(x: 0, y: 0, width: 3024, height: 4032)
            let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: rect)
            var p = GradingParams(); p.vignette = v; p.skinProtect = 0
            let r = StyleRenderer(); r.update(p)
            let t = TextureEstimator.measure(r.apply(gray, state: r.snapshotState()), context: ctx)
            report += String(format: "  v%.2f → 暗角比 %.3f\n", v, t?.vignette ?? -1)
        }
        if let url = bundle.url(forResource: "noise_iphone_stock", withExtension: "jpg"),
           let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            report += "\n== 标定：锐化/柔化 → 边缘 σ（iPhone 原片）==\n"
            for (sh, bl) in [(0.0, 0.0), (0.3, 0.0), (0.6, 0.0), (0.0, 0.3), (0.0, 0.6), (0.0, 1.0)] {
                var p = GradingParams(); p.sharpen = sh; p.blurSigmaView = bl; p.skinProtect = 0
                let r = StyleRenderer(); r.update(p)
                let t = TextureEstimator.measure(r.apply(ci, state: r.snapshotState()), context: ctx)
                report += String(format: "  锐化%.1f 柔化%.1f → 边缘 %.2f 颗粒 %.4f\n", sh, bl, t?.edge ?? -1, t?.grain ?? -1)
            }
        }
        try report.write(to: outDir.appendingPathComponent("grain-calibration.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}

// MARK: - 内置滤镜：每个富士 / 佳能同款在测试场景上的效果 + 统计
final class PresetTests: XCTestCase {
    func testPresets() throws {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let bundle = Bundle(for: PresetTests.self)
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out/presets", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var report = "内置滤镜 \(LookPresets.all.count) 个\n"
        // id 不重复、名称都带“同款”
        XCTAssertEqual(Set(LookPresets.all.map(\.id)).count, LookPresets.all.count)
        for p in LookPresets.all { XCTAssertTrue(p.name.hasSuffix("同款"), p.name) }

        for sceneName in ["scene_office2", "scene_forest"] {
            let url = try XCTUnwrap(bundle.url(forResource: sceneName, withExtension: "jpg"))
            let ci = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
            let tex = TextureEstimator.measure(ci, context: ctx)
            let raw = StyleMatcher.stats(of: ci, context: ctx)
            report += String(format: "\n== %@ == 输入 中位 L*%.1f 彩度 %.1f 颗粒σ %.4f\n", sceneName, raw?.median ?? -1, raw?.chroma ?? -1, tex?.grain ?? -1)
            for p in LookPresets.all {
                var g = p.grading
                if let tex { TextureEstimator.applyGrainTarget(to: &g, raw: tex) }
                let renderer = StyleRenderer()
                renderer.update(g)
                let out = renderer.apply(ci, state: renderer.snapshotState())
                let st = StyleMatcher.stats(of: out, context: ctx)
                let ot = TextureEstimator.measure(out, context: ctx)
                let qs: [Int] = (st?.quantiles ?? []).enumerated().compactMap { (i: Int, v: Double) -> Int? in
                    [0, 4, 10, 16, 20].contains(i) ? Int(v.rounded()) : nil
                }
                let qStr: String = "\(qs)"
                report += String(format: "%@ 中位 L*%.1f 分位%@ 彩度 %.1f 色偏 a*%.1f b*%.1f | 补颗粒 %.4f → 实测 σ %.4f（目标 %.4f）\n",
                                 p.id, st?.median ?? -1, qStr,
                                 st?.chroma ?? -1, st?.cast?.x ?? 0, st?.cast?.y ?? 0,
                                 g.grainAddSigma, ot?.grain ?? -1, g.grainTarget ?? 0)
                let e = out.extent
                let s = min(1, 600 / max(e.width, e.height))
                let scaled = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                let flat = scaled.composited(over: CIImage(color: .black).cropped(to: scaled.extent))
                try ctx.writeJPEGRepresentation(of: flat, to: outDir.appendingPathComponent("\(sceneName)_\(p.id).jpg"), colorSpace: srgb,
                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
            }
        }
        try report.write(to: outDir.appendingPathComponent("presets.txt"), atomically: true, encoding: .utf8)
    }
}

// MARK: - 胶卷柜界面截图（检查复古 + 液态玻璃的整体效果）

final class FilmCabinetSnapshotTests: XCTestCase {
    @MainActor
    func testCabinetSnapshot() throws {
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out/presets", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("没有窗口场景")
        }
        let model = AppModel()
        for (name, height) in [("cabinet_top", 874.0), ("cabinet_long", 3200.0)] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
            window.rootViewController = UIHostingController(rootView: FilmCabinetView().environmentObject(model))
            window.makeKeyAndVisible()
            window.rootViewController?.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(6))
            let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try img.jpegData(compressionQuality: 0.85)?.write(to: outDir.appendingPathComponent("\(name).jpg"))
            window.isHidden = true
        }
        // 片盒一览（放大看纹样）
        let gallery = ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(120)), count: 3), spacing: 14) {
                ForEach(LookPresets.all) { p in
                    VStack(spacing: 4) {
                        CanisterArt(preset: p).frame(width: 84, height: 136)
                        Text(p.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white)
                    }
                }
            }
            .padding()
        }
        .background(CabinetBackground(tint: .brown))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 1500)
        window.rootViewController = UIHostingController(rootView: gallery)
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try img.jpegData(compressionQuality: 0.85)?.write(to: outDir.appendingPathComponent("canisters.jpg"))
        window.isHidden = true
    }
}
