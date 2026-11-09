import XCTest
import CoreImage
import UIKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision
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
            // 相册套用 / 拍照成片路径：按这张图本身重新匹配影调色彩 + 质感，再套版本和效果开关
            let renderer = StyleRenderer()
            let snap = GradingSnapshot(base: plan.grading, ref: profile.refStats, refTexture: profile.refTexture,
                                       variant: .faithful, effects: EffectToggles(), matchAspect: false, enabled: true,
                                       resetExposure: true)
            let adapted = snap.state(for: ci, context: ctx)
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
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 3), spacing: 16) {
                ForEach(LookPresets.all) { p in
                    VStack(spacing: 4) {
                        CanisterArt(preset: p).frame(width: 80, height: 130)
                        Text(p.name).font(.system(size: 8)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
            }
            .padding()
        }
        .background(CabinetBackground(tint: .brown))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2100)
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

// MARK: - 美颜：关 / 自然 / 美颜 三档在人像上的效果（只应改变皮肤区域）
final class BeautyTests: XCTestCase {
    func testBeautyModes() throws {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let bundle = Bundle(for: BeautyTests.self)
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out/beauty", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = try XCTUnwrap(bundle.url(forResource: "scene_forest", withExtension: "jpg"))
        let ci = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        var report = ""
        var settings: [(String, BeautySettings)] = []
        settings.append(("0_off", BeautySettings(mode: .off)))
        settings.append(("1_natural", BeautySettings()))
        settings.append(("2_natural_coolwhite", BeautySettings(mode: .natural, smooth: 0.6, bright: 0.5, tone: .coolWhite)))
        settings.append(("3_beauty", BeautySettings(mode: .beauty, smooth: 0.5, bright: 0.4, tone: .cream, eye: 0.8, dull: 0.6)))
        // 人脸位置（用来裁出脸部放大图）
        let faceReq = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(ciImage: ci, options: [:]).perform([faceReq])
        let face = faceReq.results?.first?.boundingBox
        report += "人脸: \(face.map { "\($0)" } ?? "未检测到")\n"
        for (name, b) in settings {
            let snap = GradingSnapshot(base: GradingParams(), ref: nil, refTexture: nil, variant: .faithful,
                                       effects: EffectToggles(), matchAspect: false, enabled: true, beauty: b)
            var st = snap.state(for: ci, context: ctx)
            st.params.grain = 0
            let masks = PhotoProcessor.masks(for: ci, state: st, preferPerson: true)
            let out = StyleRenderer().apply(ci, state: st, masks: masks)
            report += "\(name): 人像蒙版 \(masks.person != nil) 眼下蒙版 \(masks.underEye != nil) 有皮肤处理 \(st.params.hasSkinWork)\n"
            var crop = out
            if let f = face {
                let e = ci.extent
                let r = CGRect(x: e.minX + f.minX * e.width, y: e.minY + f.minY * e.height, width: f.width * e.width, height: f.height * e.height)
                    .insetBy(dx: -f.width * e.width * 0.6, dy: -f.height * e.height * 0.6)
                crop = out.cropped(to: r)
            }
            let s = min(4, 700 / max(crop.extent.width, crop.extent.height))
            let scaled = crop.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            try ctx.writeJPEGRepresentation(of: scaled, to: outDir.appendingPathComponent("face_\(name).jpg"), colorSpace: srgb,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        }
        try report.write(to: outDir.appendingPathComponent("beauty.txt"), atomically: true, encoding: .utf8)
    }
}

// MARK: - 精修（中性灰 / 祛痘 / 点修）与语义追色
final class RetouchTests: XCTestCase {
    let ctx = CIContext(options: [.cacheIntermediates: false])
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func outDir() throws -> URL {
        let d = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out/retouch", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func save(_ img: CIImage, _ name: String, crop: CGRect? = nil) throws {
        var c = img
        if let crop { c = img.cropped(to: crop) }
        let s = min(4, 700 / max(c.extent.width, c.extent.height))
        let scaled = c.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        try ctx.writeJPEGRepresentation(of: scaled, to: try outDir().appendingPathComponent(name), colorSpace: srgb,
                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    }

    /// 某个点周围的平均亮度（sRGB 0…255）
    private func lum(_ img: CIImage, at p: CGPoint, r: CGFloat) -> Double {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let avg = img.cropped(to: rect).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: avg.extent, format: .RGBA8, colorSpace: srgb)
        return 0.3 * Double(px[0]) + 0.59 * Double(px[1]) + 0.11 * Double(px[2])
    }

    /// 在图上加几个暗斑（模拟痘痘）
    private func addSpots(_ img: CIImage, _ pts: [CGPoint], radius: CGFloat) -> CIImage {
        var out = img
        for p in pts {
            let g = CIFilter.radialGradient()
            g.center = p; g.radius0 = Float(radius * 0.4); g.radius1 = Float(radius)
            g.color0 = CIColor(red: 0.8, green: 0.64, blue: 0.62); g.color1 = CIColor.white
            let spot = g.outputImage!.cropped(to: img.extent)
            out = Retoucher.multiply(out, spot)
        }
        return out
    }

    func testRetouchAndSemantic() throws {
        let bundle = Bundle(for: RetouchTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "scene_forest", withExtension: "jpg"))
        let ci = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        let e = ci.extent
        var report = ""

        // 人脸区域
        let faceReq = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(ciImage: ci, options: [:]).perform([faceReq])
        let fb = try XCTUnwrap(faceReq.results?.first?.boundingBox)
        let face = CGRect(x: e.minX + fb.minX * e.width, y: e.minY + fb.minY * e.height, width: fb.width * e.width, height: fb.height * e.height)
        report += "人脸 \(face)\n"
        report += "自定义滤镜已加载：\(Retoucher.kernelsLoaded)\n"
        // 测试图里人脸很小：把脸部附近裁出来放大到约 1200 像素，模拟近距离人像
        let around = face.insetBy(dx: -face.width * 2.5, dy: -face.height * 2.5).intersection(e)
        let up = 1200 / max(around.width, around.height)
        let portrait = ci.cropped(to: around)
            .transformed(by: CGAffineTransform(translationX: -around.minX, y: -around.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: up, kCIInputAspectRatioKey: 1])
        let pf = CGRect(x: (face.minX - around.minX) * up, y: (face.minY - around.minY) * up, width: face.width * up, height: face.height * up)
        let crop = pf.insetBy(dx: -pf.width * 0.6, dy: -pf.height * 0.6)

        // 1) 自动祛痘 + 中性灰：在脸上加 3 个暗斑，看补平程度
        let r = max(2, pf.width * 0.05)
        let pts = [CGPoint(x: pf.midX - pf.width * 0.18, y: pf.midY - pf.height * 0.1),
                   CGPoint(x: pf.midX + pf.width * 0.15, y: pf.midY - pf.height * 0.2),
                   CGPoint(x: pf.midX, y: pf.midY + pf.height * 0.05)]
        let spotted = addSpots(portrait, pts, radius: r)
        // 模拟器里人像分割模型几乎不出结果：用围住人物的椭圆当人像蒙版（真机上用 Vision）
        func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ ext: CGRect) -> CIImage {
            let g = CIFilter.radialGradient()
            g.center = .zero; g.radius0 = 0.85; g.radius1 = 1
            g.color0 = CIColor.white; g.color1 = CIColor.black
            return g.outputImage!.transformed(by: CGAffineTransform(scaleX: rx, y: ry).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
                .cropped(to: ext)
        }
        SemanticStats.overridePersonMask = { img in
            img.extent.width == portrait.extent.width
                ? ellipse(CGPoint(x: pf.midX, y: pf.midY - pf.height * 0.6), pf.width * 1.9, pf.height * 2.2, img.extent)
                : ellipse(CGPoint(x: face.midX, y: face.midY - face.height * 1.6), face.width * 2.3, face.height * 3.2, img.extent)
        }
        defer { SemanticStats.overridePersonMask = nil }
        let skin = try XCTUnwrap(Retoucher.skinMask(for: spotted), "未识别到人像")
        let fixed = Retoucher.blend(Retoucher.evenSkin(spotted, skin: skin, even: 0.6, blemish: 0.8), over: spotted, mask: skin)
        for (i, p) in pts.enumerated() {
            let ring = CGPoint(x: p.x + r * 2.2, y: p.y)
            report += String(format: "斑点 %d：原图 %.0f · 加斑 %.0f · 祛痘后 %.0f（旁边 %.0f）\n", i,
                             lum(portrait, at: p, r: r * 0.4), lum(spotted, at: p, r: r * 0.4), lum(fixed, at: p, r: r * 0.4), lum(portrait, at: ring, r: r * 0.4))
        }
        let evenOnly = Retoucher.blend(Retoucher.evenSkin(portrait, skin: skin, even: 0.8, blemish: 0), over: portrait, mask: skin)
        let diff = CIFilter.differenceBlendMode()
        diff.inputImage = evenOnly; diff.backgroundImage = portrait
        report += String(format: "中性灰改变量（脸部平均）%.1f / 255\n", lum(diff.outputImage!, at: CGPoint(x: pf.midX, y: pf.midY), r: pf.width * 0.4))
        for (i, p) in pts.enumerated() { report += String(format: "斑点 %d 处皮肤蒙版 %.0f / 255\n", i, lum(skin, at: p, r: 1)) }
        try save(portrait, "0_portrait.jpg", crop: crop)
        do {   // 中间结果
            let L = Double(max(spotted.extent.width, spotted.extent.height))
            let fine = Retoucher.maskedBlur(spotted, mask: skin, sigma: L * 0.0013)
            let broad = Retoucher.maskedBlur(spotted, mask: skin, sigma: L * 0.009)
            let ratio = Retoucher.divide(broad, by: fine)
            try save(fine, "d_fine.jpg", crop: crop)
            try save(broad, "d_broad.jpg", crop: crop)
            try save(ratio.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0), "inputBiasVector": CIVector(x: -2.5, y: -2.5, z: -2.5, w: 0)]), "d_ratio.jpg", crop: crop)
            for (i, p) in pts.enumerated() {
                report += String(format: "斑点 %d：fine %.0f broad %.0f ratio×100 %.0f\n", i, lum(fine, at: p, r: 1), lum(broad, at: p, r: 1),
                                 lum(ratio.applyingFilter("CIColorMatrix", parameters: [
                                    "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                                    "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0)]), at: p, r: 1) * 2 / 255 * 100)
            }
        }
        try save(spotted, "1_spotted.jpg", crop: crop)
        try save(fixed, "2_auto_fixed.jpg", crop: crop)
        try save(Retoucher.blend(Retoucher.evenSkin(portrait, skin: skin, even: 0.8, blemish: 0), over: portrait, mask: skin), "3_even_only.jpg", crop: crop)
        try save(skin, "0_skin_mask.jpg", crop: crop)

        // 2) 点修：在背景上加一个大暗斑，再点修掉
        let bgPoint = CGPoint(x: e.minX + e.width * 0.2, y: e.minY + e.height * 0.7)
        let bigR = e.width * 0.03
        let blot = addSpots(ci, [bgPoint], radius: bigR)
        let healed = Retoucher.heal(blot, spots: [(center: bgPoint, radius: bigR * 1.1)])
        let ringAvg = [0.0, 90, 180, 270].map { d -> Double in
            let rad = d * .pi / 180
            return lum(ci, at: CGPoint(x: bgPoint.x + cos(rad) * bigR * 1.6, y: bgPoint.y + sin(rad) * bigR * 1.6), r: bigR * 0.3)
        }.reduce(0, +) / 4
        report += String(format: "点修：原图 %.0f · 加斑 %.0f · 点修后 %.0f（周围平均 %.0f）\n",
                         lum(ci, at: bgPoint, r: bigR * 0.4), lum(blot, at: bgPoint, r: bigR * 0.4), lum(healed, at: bgPoint, r: bigR * 0.4), ringAvg)
        let bgCrop = CGRect(x: bgPoint.x - bigR * 4, y: bgPoint.y - bigR * 4, width: bigR * 8, height: bigR * 8)
        try save(blot, "4_blot.jpg", crop: bgCrop)
        try save(healed, "5_healed.jpg", crop: bgCrop)

        // 3) 语义追色：把人物（非皮肤）调蓝，再以原图为参考追色，看人物区域能否追回来
        try report.write(to: try outDir().appendingPathComponent("retouch.txt"), atomically: true, encoding: .utf8)
        let pm = try XCTUnwrap(SemanticStats.personMask(for: ci))
        try save(pm, "7_person_mask.jpg")
        let refSem = try XCTUnwrap(SemanticStats.measure(ci, person: pm, context: ctx))
        let refStats = try XCTUnwrap(StyleMatcher.stats(of: ci, context: ctx))
        let blueish = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.25, w: 0)
        ])
        let shifted = Retoucher.blend(blueish, over: ci, mask: pm)
        func personAB(_ img: CIImage) -> String {
            guard let s = SemanticStats.measure(img, person: pm, context: ctx) else { return "?" }
            let p = s.person, k = s.skin, b = s.background
            return String(format: "人物 a%.1f b%.1f | 皮肤 a%.1f b%.1f | 背景 a%.1f b%.1f",
                          p?.a ?? .nan, p?.b ?? .nan, k?.a ?? .nan, k?.b ?? .nan, b?.a ?? .nan, b?.b ?? .nan)
        }
        report += "参考（原图）：\(personAB(ci))\n人物调蓝后：\(personAB(shifted))\n"
        for (name, sem) in [("整体追色", nil), ("语义追色", refSem)] as [(String, SemanticStats?)] {
            var fx = EffectToggles(); fx.grain = false
            let snap = GradingSnapshot(base: GradingParams(), ref: refStats, refTexture: nil, variant: .faithful, effects: fx,
                                       matchAspect: false, enabled: true, beauty: BeautySettings(mode: .off), refSemantic: sem)
            var st = snap.state(for: shifted, context: ctx)
            st.params.grain = 0
            let masks = PhotoProcessor.masks(for: shifted, state: st, preferPerson: true)
            let out = StyleRenderer().apply(shifted, state: st, masks: masks)
            report += "\(name)：\(personAB(out))  · 人物调整 \(st.params.regionPerson.map { String(format: "a%+.1f b%+.1f ×%.2f", $0.tint.x, $0.tint.y, $0.sat) } ?? "无")\n"
            try save(out, "6_\(name).jpg")
        }
        try save(shifted, "6_调蓝输入.jpg")
        try report.write(to: try outDir().appendingPathComponent("retouch.txt"), atomically: true, encoding: .utf8)
    }
}

// MARK: - 真实人脸样图：大 / 中 / 小三种脸的比例，看精修是否保住细节
final class FaceSampleTests: XCTestCase {
    let ctx = CIContext(options: [.cacheIntermediates: false])
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 区域内的拉普拉斯方差（细节量）
    private func detail(_ img: CIImage, in r: CGRect) -> Double {
        let w = max(8, Int(r.width)), h = max(8, Int(r.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(img, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: r.minX, y: r.minY, width: CGFloat(w), height: CGFloat(h)),
                   format: .RGBA8, colorSpace: srgb)
        func g(_ x: Int, _ y: Int) -> Double { let o = (y * w + x) * 4; return 0.3 * Double(px[o]) + 0.59 * Double(px[o + 1]) + 0.11 * Double(px[o + 2]) }
        var s = 0.0, s2 = 0.0, n = 0.0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let l = 4 * g(x, y) - g(x - 1, y) - g(x + 1, y) - g(x, y - 1) - g(x, y + 1)
            s += l; s2 += l * l; n += 1
        } }
        return n > 0 ? s2 / n - (s / n) * (s / n) : 0
    }

    /// 前后对比图：脸部按原像素裁出（小脸用最近邻放大，看清像素）
    private func sideBySide(_ a: CIImage, _ b: CIImage, crop: CGRect) -> CIImage {
        let k = max(1, min(6, 420 / crop.width))
        func prep(_ i: CIImage) -> CIImage {
            i.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .samplingNearest().transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        let left = prep(a), right = prep(b)
        return right.transformed(by: CGAffineTransform(translationX: left.extent.width + 8, y: 0)).composited(over: left)
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: left.extent.width * 2 + 8, height: left.extent.height)))
    }

    func testFaceSamples() throws {
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTPUT_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-out/faces", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var sources: [(String, CIImage)] = []
        if let dir = ProcessInfo.processInfo.environment["FACE_SAMPLES_DIR"],
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files.sorted() where f.lowercased().hasSuffix(".jpg") {
                if let ci = CIImage(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f), options: [.applyOrientationProperty: true]) {
                    sources.append((f, ci))
                }
            }
        }
        if let u = Bundle(for: FaceSampleTests.self).url(forResource: "scene_forest", withExtension: "jpg"),
           let ci = CIImage(contentsOf: u, options: [.applyOrientationProperty: true]) { sources.append(("scene_forest.jpg", ci)) }
        var report = "样图 \(sources.count) 张 · 人脸分区模型已加载：\(FaceParser.available)\n"

        for (name, raw) in sources {
            // 统一到原点；同一张图再缩成 40% 和 15%，模拟同样的皮肤问题在中 / 小比例下的样子
            let base = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
            for scale in name.hasPrefix("scene_") ? [1.0] : [1.0, 0.4, 0.15] {
                let img = scale == 1 ? base : base.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                let faces = Retoucher.faces(in: img)
                let tag = "\((name as NSString).deletingPathExtension)_\(Int(scale * 100))"
                guard let face = faces.max(by: { $0.width < $1.width }) else {
                    report += "\(tag)：\(Int(img.extent.width))×\(Int(img.extent.height)) 没检测到人脸\n"
                    continue
                }
                let fw = Retoucher.typicalFaceWidth(faces, extent: img.extent)
                let share = face.width / img.extent.width
                let snap = GradingSnapshot(base: GradingParams(), ref: nil, refTexture: nil, variant: .faithful,
                                           effects: EffectToggles(), matchAspect: false, enabled: true, beauty: BeautySettings())
                var st = snap.state(for: img, context: ctx)
                st.params.grain = 0
                let t0 = Date()
                let masks = PhotoProcessor.masks(for: img, state: st, preferPerson: true)
                let out = StyleRenderer().apply(img, state: st, masks: masks)
                let crop = face.insetBy(dx: -face.width * 0.25, dy: -face.height * 0.25).intersection(img.extent).integral
                let inner = face.insetBy(dx: face.width * 0.2, dy: face.height * 0.2).integral
                let d0 = detail(img, in: inner), d1 = detail(out, in: inner)
                _ = ctx.createCGImage(out, from: crop)   // 计时用：确保真正渲染了
                let ms = Date().timeIntervalSince(t0) * 1000
                report += String(format: "%@：脸宽 %.0f px（占画面宽 %.0f%%）· 尺度系数 %.2f · 细节保留 %.0f%% · 人像蒙版 %@ · 人脸分区 %@ · %.0f ms\n",
                                 tag, fw, share * 100, Retoucher.sizeFactor(fw), d0 > 0 ? d1 / d0 * 100 : 0,
                                 masks.person != nil ? "有" : "无", masks.faceParse != nil ? "有" : "无", ms)
                if let fp = masks.faceParse {
                    let mpair = sideBySide(fp.skin, fp.protect, crop: crop)
                    try ctx.writeJPEGRepresentation(of: mpair, to: outDir.appendingPathComponent("\(tag)_parse.jpg"), colorSpace: srgb,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
                }
                let pair = sideBySide(img, out, crop: crop)
                try ctx.writeJPEGRepresentation(of: pair, to: outDir.appendingPathComponent("\(tag)_face.jpg"), colorSpace: srgb,
                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])

                // 年轻化（美颜档，提拉 / 淡化纹路 / 眼袋 拉满，便于看清效果）
                if scale == 1 {
                    var b = BeautySettings(); b.mode = .beauty; b.lift = 1; b.folds = 1; b.eyeBag = 1
                    let ysnap = GradingSnapshot(base: GradingParams(), ref: nil, refTexture: nil, variant: .faithful,
                                                effects: EffectToggles(), matchAspect: false, enabled: true, beauty: b)
                    var yst = ysnap.state(for: img, context: ctx)
                    yst.params.grain = 0
                    let ym = PhotoProcessor.masks(for: img, state: yst, preferPerson: true)
                    let yout = StyleRenderer().apply(img, state: yst, masks: ym)
                    let folds = FaceGeometry.foldMask(ym.geometry, extent: img.extent)
                    let field = FaceGeometry.liftField(ym.geometry, amount: 1, extent: img.extent)
                    var maxShift: Float = 0
                    if let field {
                        let fe = field.extent.integral
                        var px = [Float](repeating: 0, count: 4)
                        // 抽查下巴附近的位移
                        if let g = ym.geometry.first, let chin = g.contour.min(by: { $0.y < $1.y }), fe.contains(chin) {
                            ctx.render(field, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: chin.x, y: chin.y, width: 1, height: 1),
                                       format: .RGBAf, colorSpace: nil)
                            maxShift = (px[0] * px[0] + px[1] * px[1]).squareRoot()
                        }
                    }
                    report += String(format: "  └ 年轻化：关键点 %d 张脸 · 纹路蒙版 %@ · 眼下蒙版 %@ · 下巴上提 %.1f px（脸高 %.0f px）\n",
                                     ym.geometry.count, folds != nil ? "有" : "无", ym.underEye != nil ? "有" : "无",
                                     maxShift, ym.geometry.first?.box.height ?? 0)
                    try ctx.writeJPEGRepresentation(of: sideBySide(out, yout, crop: crop), to: outDir.appendingPathComponent("\(tag)_youth.jpg"),
                                                    colorSpace: srgb, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
                    // 关键点可视化：下颌线（绿）、鼻翼 / 嘴角（红）、眼睛（蓝）
                    if !ym.geometry.isEmpty {
                        let e = img.extent
                        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                        if let c = CGContext(data: nil, width: Int(e.width), height: Int(e.height), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            let r = max(2, e.width / 300)
                            func dots(_ ps: [CGPoint], _ col: CGColor) {
                                c.setFillColor(col)
                                for p in ps { c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
                            }
                            for g in ym.geometry {
                                dots(g.contour, CGColor(red: 0, green: 1, blue: 0, alpha: 1))
                                dots(g.noseWings + g.mouthCorners, CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                                dots(g.eyes.flatMap { $0 }, CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
                                c.setStrokeColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1)); c.setLineWidth(r / 2); c.stroke(g.box)
                            }
                            if let cg = c.makeImage() {
                                let lm = CIImage(cgImage: cg).composited(over: img)
                                try ctx.writeJPEGRepresentation(of: sideBySide(lm, yout, crop: crop), to: outDir.appendingPathComponent("\(tag)_landmarks.jpg"),
                                                                colorSpace: srgb, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
                            }
                        }
                    }
                    if let folds {
                        let vis = yout.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                        let tint = CIImage(color: CIColor(red: 1, green: 0.2, blue: 0.4)).cropped(to: img.extent)
                        let overlay = tint.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: vis, kCIInputMaskImageKey: folds])
                        try ctx.writeJPEGRepresentation(of: sideBySide(overlay, ym.underEye ?? vis, crop: crop),
                                                        to: outDir.appendingPathComponent("\(tag)_youthmask.jpg"), colorSpace: srgb,
                                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
                    }
                }
                let s = min(1, 900 / max(img.extent.width, img.extent.height))
                let full = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                try ctx.writeJPEGRepresentation(of: full, to: outDir.appendingPathComponent("\(tag)_full.jpg"), colorSpace: srgb,
                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
            }
        }
        report += "\n样图来源：Wikimedia Commons（自由许可），文件名见上；scene_forest 为项目自带测试图。\n"
        try report.write(to: outDir.appendingPathComponent("faces.txt"), atomically: true, encoding: .utf8)
    }
}
