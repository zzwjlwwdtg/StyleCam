import SwiftUI
import Combine
import PhotosUI
import CoreImage

/// 串起整个流程：参考图 → 分析 → 选镜头 → 读“修改前” → 规划 → 应用 → 回读“实测”
@MainActor
final class AppModel: ObservableObject {
    let camera = CameraManager()
    let recipes = RecipeStore()
    let level = LevelMonitor()

    @Published var referenceImage: UIImage?
    @Published var profile: StyleProfile?
    @Published var plan: CapturePlan?
    @Published var changes: [ParameterChange] = []
    @Published var isAnalyzing = false
    @Published var errorMessage: String?

    @Published var strength: Double = 1 {
        didSet { if !suppressSync { camera.setStrength(strength) } }
    }
    @Published var wbFollow = true { didSet { camera.setWBFollow(wbFollow) } }
    @Published var autoMatchExposure = true { didSet { camera.setAutoMatch(autoMatchExposure) } }
    @Published var use48MP = false { didSet { camera.setUse48MP(use48MP) } }
    @Published var saveOriginal = false { didSet { camera.setSaveOriginal(saveOriginal) } }
    @Published var variant: StyleVariant = .faithful {
        didSet {
            camera.setVariant(variant)
            if let id = currentRecipeID, var r = recipes.recipes.first(where: { $0.id == id }), r.variant != variant.rawValue {
                r.variant = variant.rawValue
                recipes.update(r)
            }
        }
    }
    @Published var overlayMode: OverlayMode = .off
    @Published var overlayOpacity: Double = 0.35
    @Published var outlineImage: UIImage?
    @Published var currentRecipeID: UUID?
    /// 当前使用的内置滤镜（与参考图二选一）
    @Published var currentPreset: LookPreset?
    var hasStyle: Bool { referenceImage != nil || currentPreset != nil }
    static let lastPresetKey = "lastPresetID"
    @Published var batchProgress: String?
    @Published var effects = EffectToggles() { didSet { camera.setEffects(effects) } }
    /// 闪光灯：CCD / 拍立得滤镜在主界面显示，选中时默认打开（直闪是这类相机的标志性观感）
    @Published var flash: FlashSetting = .off { didSet { camera.setFlash(flash.avMode) } }
    var showsFlash: Bool { currentPreset.map { $0.kind != .film } ?? false }

    /// 美颜（只作用于皮肤）：默认自然档
    @Published var beauty: BeautySettings = AppModel.loadBeauty() {
        didSet {
            camera.setBeauty(beauty)
            if let d = try? JSONEncoder().encode(beauty) { UserDefaults.standard.set(d, forKey: "beauty") }
        }
    }

    private static func loadBeauty() -> BeautySettings {
        guard let d = UserDefaults.standard.data(forKey: "beauty"),
              let b = try? JSONDecoder().decode(BeautySettings.self, from: d) else { return BeautySettings() }
        return b
    }

    /// 优先苹果画质（暗光 / 大光比时用）：不锁曝光，只调色
    @Published var preferAppleQuality = UserDefaults.standard.bool(forKey: "preferAppleQuality") {
        didSet {
            guard preferAppleQuality != oldValue else { return }
            UserDefaults.standard.set(preferAppleQuality, forKey: "preferAppleQuality")
            camera.setAppleQuality(preferAppleQuality)
        camera.setBeauty(beauty)
            Task { await reapplyHardware() }
        }
    }
    /// 按参考图画幅裁切（默认关闭）
    @Published var matchAspect = false {
        didSet {
            camera.setMatchAspect(matchAspect)
            if let i = changes.firstIndex(where: { $0.id == "crop" }) {
                changes[i].status = matchAspect ? .applied : .info
            }
        }
    }
    private(set) var referenceData: Data?
    private var readySub: AnyCancellable?

    private var suppressSync = false

    var hardwareChangeCount: Int { changes.filter { $0.category != .grading && !isUnsupported($0) && $0.status != .info }.count }
    var modifiedCount: Int { changes.filter { $0.status != .info }.count }

    init() {
        camera.setAutoMatch(true)
        camera.setAppleQuality(preferAppleQuality)
        camera.setBeauty(beauty)
        // 相机就绪后自动恢复上次的风格（保存一次，以后打开就是同一风格）
        readySub = camera.$isReady.filter { $0 }.first().sink { [weak self] _ in
            Task { @MainActor in await self?.restoreLast() }
        }
        // Camera Control 实体键拨动后，同步界面和“已修改参数”
        camera.onStrengthFromControl = { [weak self] v in
            guard let self else { return }
            self.suppressSync = true
            self.strength = v
            self.suppressSync = false
        }
        camera.onApertureFromControl = { [weak self] f in
            guard let self else { return }
            self.plan?.aperture = f
            if let i = self.changes.firstIndex(where: { $0.id == "aperture" }) {
                let eq = Optics.lens(self.camera.lens).equivalentF(Double(f))
                self.changes[i].after = "\(Fmt.ap(f)) 锁定（≈全画幅 \(Optics.fmtF(eq))，Camera Control 手动）"
                self.changes[i].actual = Fmt.ap(f)
                self.changes[i].status = .applied
            }
        }
    }

    // MARK: - 载入参考图

    func loadReference(_ data: Data, recipe: StyleRecipe? = nil) async {
        isAnalyzing = true
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            let (profile, thumb) = try await Task.detached(priority: .userInitiated) {
                try StyleAnalyzer.analyze(data: data)
            }.value
            referenceImage = thumb
            referenceData = data
            currentPreset = nil
            flash = .off
            UserDefaults.standard.removeObject(forKey: Self.lastPresetKey)
            self.profile = profile
            if let recipe {
                currentRecipeID = recipe.id
                recipes.markLast(recipe)
                if let v = StyleVariant(rawValue: recipe.variant) { variant = v }
                strength = recipe.strength
            } else {
                currentRecipeID = nil
                recipes.saveLastReference(data)
            }
            Task.detached(priority: .utility) {
                let outline = AppModel.makeOutline(thumb)
                await MainActor.run { self.outlineImage = outline }
            }
            camera.setReference(profile)
            let (lens, why) = ParameterPlanner.chooseLens(profile: profile)
            await rebuildPlan(profile: profile, lens: lens, lensReason: why)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 手动切换焦段时，按新镜头重新规划（例如切到 4x 后光圈不可调）
    func selectLens(_ lens: LensChoice) async {
        if let profile {
            isAnalyzing = true
            defer { isAnalyzing = false }
            await rebuildPlan(profile: profile, lens: lens, lensReason: "你手动选择了 \(lens.rawValue)")
        } else {
            await withCheckedContinuation { cont in camera.switchLens(lens) { cont.resume() } }
        }
    }

    func clearReference() {
        recipes.clearLast()
        currentPreset = nil
        flash = .off
        UserDefaults.standard.removeObject(forKey: Self.lastPresetKey)
        currentRecipeID = nil
        referenceData = nil
        outlineImage = nil
        overlayMode = .off
        referenceImage = nil
        profile = nil
        plan = nil
        changes = []
        camera.setReference(nil)
        camera.resetAndSnapshot { _ in }
        camera.apply(CapturePlan(lens: camera.lens)) { _ in }
    }

    private func rebuildPlan(profile: StyleProfile, lens: LensChoice, lensReason: String) async {
        let previousLens = camera.lens
        await withCheckedContinuation { cont in camera.switchLens(lens) { cont.resume() } }

        guard var before = await withCheckedContinuation({ (cont: CheckedContinuation<DeviceSnapshot?, Never>) in
            camera.resetAndSnapshot { cont.resume(returning: $0) }
        }) else {
            errorMessage = "相机尚未就绪"
            return
        }
        before.lens = previousLens

        var (newPlan, newChanges) = ParameterPlanner.makePlan(
            profile: profile, lens: lens, lensReason: lensReason,
            caps: camera.capabilities, before: before)
        newPlan.grading.strength = strength

        plan = newPlan
        changes = newChanges
        use48MP = newPlan.use48MP

        let report = await withCheckedContinuation { (cont: CheckedContinuation<ApplyReport, Never>) in
            camera.apply(newPlan) { cont.resume(returning: $0) }
        }
        ParameterPlanner.merge(report: report, plan: newPlan, into: &changes)
        if matchAspect, let i = changes.firstIndex(where: { $0.id == "crop" }) { changes[i].status = .applied }
        markAppleQuality()
    }

    /// 切换“优先苹果画质”后重新下发硬件参数
    private func reapplyHardware() async {
        if let profile {
            isAnalyzing = true
            defer { isAnalyzing = false }
            await rebuildPlan(profile: profile, lens: camera.lens, lensReason: "保持当前镜头")
        } else if let plan {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<ApplyReport, Never>) in
                camera.apply(plan) { cont.resume(returning: $0) }
            }
        }
    }

    /// 参数面板：开启“优先苹果画质”时，被交还给苹果的几项标注出来
    private func markAppleQuality() {
        guard preferAppleQuality else { return }
        let note = "已开启「优先苹果画质」：保持自动，交给苹果的多帧合成 / Smart HDR"
        for id in ["aperture", "shutter", "iso", "tonemap", "quality"] {
            for i in changes.indices where changes[i].id == id { changes[i].status = .adjusted(note) }
        }
        if !changes.contains(where: { $0.id == "applequality" }) {
            changes.append(ParameterChange(id: "applequality", category: .hardware, name: "优先苹果画质",
                                           before: "关", after: "开",
                                           reason: "暗光 / 大光比时画质更好；光圈景深与锁定曝光不再按参考图设置，风格只靠调色", status: .applied))
        }
    }

    private func isUnsupported(_ c: ParameterChange) -> Bool {
        if case .unsupported = c.status { return true }
        return false
    }

    // MARK: - 给相册里已有的照片套用当前风格（另存新照片，原图不动）

    func applyStyle(to items: [PhotosPickerItem]) async {
        guard hasStyle, !items.isEmpty else { return }
        let renderer = camera.renderer
        let grading = camera.gradingSnapshot()
        let v = variant, person = (profile?.faceCount ?? 1) > 0
        let summary = "StyleCam 后期套用 | \(currentPreset?.name ?? "参考图") | \(v.rawValue) | 强度 \(Fmt.percent(strength))"
        var ok = 0
        for (i, item) in items.enumerated() {
            batchProgress = "正在套用 \(i + 1)/\(items.count)…"
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let err: String? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    PhotoProcessor.processExisting(data: data, renderer: renderer, grading: grading,
                                                   preferPerson: person, summary: summary) { thumb, err in
                        if let thumb { DispatchQueue.main.async { self.camera.lastPhoto = thumb } }
                        cont.resume(returning: err)
                    }
                }
            }
            if err == nil { ok += 1 }
        }
        batchProgress = nil
        camera.statusMessage = "已套用 \(ok)/\(items.count) 张，另存到相册"
    }

    // MARK: - 风格库

    func saveRecipe(name: String) {
        guard let data = referenceData else { return }
        let r = recipes.save(name: name, referenceData: data, thumbnail: referenceImage, variant: variant, strength: strength)
        currentRecipeID = r.id
    }

    func applyRecipe(_ r: StyleRecipe) async {
        guard let data = recipes.referenceData(r) else {
            errorMessage = "找不到这个风格的参考图"
            return
        }
        await loadReference(data, recipe: r)
    }

    // MARK: - 内置滤镜（富士 / 佳能同款）

    func applyPreset(_ p: LookPreset) async {
        // 内置滤镜不需要参考图：清掉参考图与实时匹配，只换调色
        recipes.clearLast()
        currentRecipeID = nil
        referenceData = nil
        referenceImage = nil
        outlineImage = nil
        overlayMode = .off
        profile = nil
        matchAspect = false
        let wasFlashStyle = showsFlash
        currentPreset = p
        UserDefaults.standard.set(p.id, forKey: Self.lastPresetKey)
        if p.kind != .film { if !wasFlashStyle { flash = .on } } else { flash = .off }
        camera.setReference(nil)
        _ = await withCheckedContinuation { (cont: CheckedContinuation<DeviceSnapshot?, Never>) in
            camera.resetAndSnapshot { cont.resume(returning: $0) }
        }
        var plan = CapturePlan(lens: camera.lens)
        plan.grading = p.grading
        plan.grading.strength = strength
        self.plan = plan
        changes = LookPresets.changes(for: p)
        _ = await withCheckedContinuation { (cont: CheckedContinuation<ApplyReport, Never>) in
            camera.apply(plan) { cont.resume(returning: $0) }
        }
    }

    private func restoreLast() async {
        guard profile == nil else { return }
        if let id = UserDefaults.standard.string(forKey: Self.lastPresetKey), let p = LookPresets.preset(id: id) {
            await applyPreset(p)
        } else if let r = recipes.lastUsed {
            await applyRecipe(r)
        } else if let data = recipes.lastReferenceData() {
            await loadReference(data)
        }
    }

    // MARK: - 构图轮廓：参考图边缘 → 黄色线稿

    nonisolated static func makeOutline(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let e = ci.extent
        let edges = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(1, Double(e.width) / 800))
            .cropped(to: e)
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 8])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.0, kCIInputBrightnessKey: -0.05])
        let yellow = CIImage(color: CIColor(red: 1, green: 0.85, blue: 0.15)).cropped(to: e)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: e)
        let out = yellow.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: edges
        ])
        let ctx = CIContext()
        guard let result = ctx.createCGImage(out, from: e, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return UIImage(cgImage: result)
    }
}
