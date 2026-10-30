import SwiftUI
import Combine

/// 串起整个流程：参考图 → 分析 → 选镜头 → 读“修改前” → 规划 → 应用 → 回读“实测”
@MainActor
final class AppModel: ObservableObject {
    let camera = CameraManager()

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

    private var suppressSync = false

    var hardwareChangeCount: Int { changes.filter { $0.category != .grading && !isUnsupported($0) && $0.status != .info }.count }
    var modifiedCount: Int { changes.filter { $0.status != .info }.count }

    init() {
        camera.setAutoMatch(true)
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

    func loadReference(_ data: Data) async {
        isAnalyzing = true
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            let (profile, thumb) = try await Task.detached(priority: .userInitiated) {
                try StyleAnalyzer.analyze(data: data)
            }.value
            referenceImage = thumb
            self.profile = profile
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
    }

    private func isUnsupported(_ c: ParameterChange) -> Bool {
        if case .unsupported = c.status { return true }
        return false
    }
}
