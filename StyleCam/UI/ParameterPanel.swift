import SwiftUI

/// “修改了哪些参数”面板：修改前 → 修改后 → 实测值 + 原因
struct ParameterPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraManager

    var body: some View {
        NavigationStack {
            List {
                if let profile = model.profile {
                    Section { referenceCard(profile) }
                }

                if model.changes.isEmpty {
                    Section {
                        Text("还没有参考图。点左上角选一张喜欢的照片，App 会自动分析风格、调整相机，并在这里列出每一项改动。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                ForEach(ParameterChange.Category.allCases, id: \.self) { cat in
                    let items = model.changes.filter { $0.category == cat }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { ChangeRow(change: $0) }
                        } header: {
                            Text("\(cat.rawValue)（\(items.count)）")
                        }
                    }
                }

                Section("拍摄选项") {
                    Toggle("白平衡偏移跟随场景", isOn: $model.wbFollow)
                    Toggle("实时对齐亮度 / 饱和度 / 色偏", isOn: $model.autoMatchExposure)
                    if let st = camera.autoMatchStatus, model.autoMatchExposure {
                        Text("当前：" + st).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let p = model.profile, abs(p.aspect - 4.0 / 3.0) > 0.08 {
                        Toggle(String(format: "按参考图画幅裁切（%.2f:1）", p.aspect), isOn: $model.matchAspect)
                    }
                    Toggle("48MP 拍摄", isOn: $model.use48MP)
                    if camera.proRAWSupported {
                        Toggle("同时保存 ProRAW 底片（DNG）", isOn: Binding(
                            get: { camera.proRAWEnabled },
                            set: { camera.setProRAW($0) }))
                    }
                    Toggle("同时保存未调色原图", isOn: $model.saveOriginal)
                }

                Section("本机相机能力（\(camera.capabilities.deviceName)）") {
                    let c = camera.capabilities
                    info("可变光圈", c.hasVariableAperture ? c.apertureStops.map(Fmt.ap).joined(separator: " / ") : "无（固定光圈）")
                    if c.hasVariableAperture {
                        let lo = Optics.lens(camera.lens)
                        info("光圈 ≈ 全画幅等效（入瞳）", c.apertureStops.map {
                            "\(Fmt.ap($0))≈\(Optics.fmtF(lo.equivalentF(Double($0))))（\(ParameterPlanner.mm(lo.pupil(Double($0))))）"
                        }.joined(separator: "\n"))
                    }
                    info("ISO 范围", "\(Int(c.isoRange.lowerBound))–\(Int(c.isoRange.upperBound))")
                    info("快门范围", "\(Fmt.shutter(c.shutterRange.lowerBound)) – \(Fmt.shutter(c.shutterRange.upperBound))")
                    info("曝光信号（iOS 27）", Fmt.signals(c.supportedSignals))
                    info("自定义白平衡增益", c.supportsCustomWB ? "支持" : "不支持")
                    info("全局色调映射", c.supportsGlobalToneMapping ? "支持" : "不支持")
                }

                if let exif = model.profile?.exif, exif.hasExposureInfo || exif.model != nil {
                    Section("参考图 EXIF") {
                        if let m = exif.model { info("机型", [exif.make, m].compactMap { $0 }.joined(separator: " ")) }
                        if let l = exif.lensModel { info("镜头", l) }
                        if let f = exif.fNumber { info("光圈", Fmt.ap(Float(f))) }
                        if let t = exif.exposureTime { info("快门", Fmt.shutter(t)) }
                        if let i = exif.iso { info("ISO", "\(Int(i))") }
                        if let fl = exif.focalLength35mm { info("等效焦距", "\(Int(fl))mm") }
                    }
                }
            }
            .navigationTitle(model.changes.isEmpty ? "参数" : "已修改 \(model.modifiedCount) 项参数")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func referenceCard(_ p: StyleProfile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let img = model.referenceImage {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 72, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("参考图风格分析").font(.subheadline.bold())
                Group {
                    Text("影调：亮度 L*\(Int(p.medianL)) · 对比 \(Fmt.signed(p.contrast * 100)) · 黑位 L*\(Int(p.blackPoint))")
                    Text("色彩：饱和 \(Fmt.percent(p.saturation)) · 色偏 \(ColorMath.hueName(a: p.castA, b: p.castB)) \(String(format: "%.1f", (p.castA * p.castA + p.castB * p.castB).squareRoot()))")
                    Text("质感：颗粒 \(Fmt.percent(p.grain)) · 暗角 \(Fmt.percent(p.vignette))")
                    Text("场景：" + sceneText(p))
                    Text("光学：" + p.optics.summary)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func sceneText(_ p: StyleProfile) -> String {
        var parts: [String] = [p.depthOfField.rawValue]
        if p.isNight { parts.append("夜景") }
        if p.faceCount > 0 { parts.append("\(p.faceCount) 张人脸") }
        if p.pointLightCount > 0 { parts.append("\(p.pointLightCount) 个点光源") }
        return parts.joined(separator: " · ")
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            .font(.caption)
    }
}

struct ChangeRow: View {
    let change: ParameterChange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(change.name).font(.subheadline.weight(.semibold))
                Spacer()
                badge
            }
            HStack(spacing: 6) {
                Text(change.before).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(change.after).foregroundStyle(.yellow).bold()
            }
            .font(.caption.monospacedDigit())

            if let a = change.actual {
                Label("实测：\(a)", systemImage: "checkmark.seal").font(.caption2).foregroundStyle(.green)
            }
            if case .adjusted(let why) = change.status {
                Label(why, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
            if case .unsupported(let why) = change.status {
                Label(why, systemImage: "nosign").font(.caption2).foregroundStyle(.secondary)
            }
            Text(change.reason).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badge: some View {
        switch change.status {
        case .info: tag("说明", .blue)
        case .planned: tag("待生效", .gray)
        case .applied: tag("已生效", .green)
        case .adjusted: tag("已调整", .orange)
        case .unsupported: tag("不支持", .gray)
        }
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.25), in: Capsule())
            .foregroundStyle(c)
    }
}
