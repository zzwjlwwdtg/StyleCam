import Foundation
import AVFoundation

/// 把“风格画像”翻译成 iPhone 18 Pro Max 的具体参数，并生成“改了哪些参数”的清单
enum ParameterPlanner {

    // MARK: 选镜头

    static func chooseLens(profile: StyleProfile) -> (LensChoice, String) {
        if let f = profile.exif.focalLength35mm, f > 8 {
            let lens = LensChoice.nearest(toFocal35: f)
            return (lens, "参考图 EXIF 等效焦距 \(Int(f))mm → 最接近的光学焦段")
        }
        let main = Optics.lens(.wide), tele = Optics.lens(.tele)
        let mainMax = main.pupil(1.48), teleD = tele.pupil(tele.fixedF ?? 2.8)
        if (1...2).contains(profile.faceCount), let d = profile.optics.pupilMM, d > mainMax * 1.25 {
            return (.tele, "参考图虚化需要入瞳约 \(mm(d))，超过主摄极限 \(mm(mainMax))；4x 长焦入瞳 \(mm(teleD)) 更大，同样构图下背景更虚（要站到约 4 倍远保持构图）")
        }
        if profile.faceCount == 1 && profile.depthOfField != .deep {
            return (.wide2x, "单人人像 → 48mm 人像焦段（仍是主摄，可调光圈）")
        }
        return (.wide, "无焦距信息，使用主摄（唯一带可变光圈的镜头）")
    }

    static func mm(_ v: Double) -> String { String(format: v < 10 ? "%.1fmm" : "%.0fmm", v) }

    // MARK: 生成完整计划

    static func makePlan(profile: StyleProfile,
                         lens: LensChoice,
                         lensReason: String,
                         caps: HardwareCapabilities,
                         before: DeviceSnapshot) -> (CapturePlan, [ParameterChange]) {
        var plan = CapturePlan()
        var changes: [ParameterChange] = []
        plan.lens = lens

        if before.lens != lens {
            changes.append(.init(id: "lens", category: .hardware, name: "镜头 / 焦段",
                                 before: "\(before.lens.rawValue)（\(Int(before.lens.focal35))mm）",
                                 after: "\(lens.rawValue)（\(Int(lens.focal35))mm）",
                                 reason: lensReason))
        }

        let longExposure = (profile.exif.exposureTime ?? 0) >= 1.0 / 8.0
        let starLook = profile.isNight && profile.pointLightCount >= 4

        // ---- 1. 光圈：在“入瞳直径”空间匹配参考图（等效光圈原理）----
        let o = profile.optics
        let lensO = Optics.lens(lens)
        var usedF: Double = lensO.fixedF ?? Double(before.aperture)
        if caps.hasVariableAperture && lens.hasVariableAperture {
            let nMin = Double(caps.apertureRange.lowerBound), nMax = Double(caps.apertureRange.upperBound)
            let dMax = lensO.pupil(nMin), dMin = lensO.pupil(nMax)
            var n = nMin
            var why = ""
            let refDesc = "参考图 ≈ 全画幅 \(Int(o.focal35 ?? Optics.assumedFocal35))mm \(Optics.fmtF(o.equivalentF ?? 0))，入瞳 \(mm(o.pupilMM ?? 0))"
            if profile.exif.isFromIPhone, let f = profile.exif.fNumber, f > 1.2,
               abs((profile.exif.focalLength35mm ?? 0) - lens.focal35) < 5 {
                n = f
                why = "参考图是 iPhone 同焦段拍的，EXIF 光圈 \(Fmt.ap(Float(f))) 直接复用"
            } else if let d = o.pupilMM {
                if d <= dMin {
                    n = nMax
                    why = refDesc + "，比 iPhone \(Fmt.ap(Float(nMax))) 的入瞳 \(mm(dMin)) 还小 → 收到最小光圈，景深足够"
                } else if d <= dMax {
                    n = lensO.focalActual / d
                    why = refDesc + " → iPhone 用 \(Fmt.ap(Float(n))) 时入瞳相同，同样构图下背景虚化一致"
                } else {
                    n = nMin
                    why = refDesc + "，超过 iPhone 物理极限（\(Fmt.ap(Float(nMin))) 入瞳 \(mm(dMax)) ≈ 全画幅 \(Optics.fmtF(lensO.equivalentF(nMin)))）→ 开到最大，差的部分用计算虚化补足"
                }
            }
            if profile.faceCount >= 3 && n < 2.8 {
                n = 2.8
                why = "参考图是合影（\(profile.faceCount) 张脸）→ 至少 f/2.8 保证每张脸清晰"
            }
            if starLook {
                n = nMax
                why = "参考图是夜景且有 \(profile.pointLightCount) 个点光源 → 收到最小光圈出星芒"
            }
            if longExposure {
                n = nMax
                why += "；为配合长曝光收小光圈减光（相当于内置 ND）"
            }
            n = min(max((n * 20).rounded() / 20, nMin), nMax)
            usedF = n
            plan.aperture = Float(n)
            changes.append(.init(id: "aperture", category: .newFeature, name: "物理可变光圈",
                                 before: "\(Fmt.ap(before.aperture))（自动）",
                                 after: "\(Fmt.ap(Float(n))) 锁定（≈全画幅 \(Optics.fmtF(lensO.equivalentF(n)))）",
                                 reason: why))
        } else if lens.hasVariableAperture == false {
            changes.append(.init(id: "aperture", category: .newFeature, name: "物理可变光圈",
                                 before: Fmt.ap(before.aperture), after: "不可调",
                                 reason: "\(lens.rawValue) 镜头为固定光圈 \(Optics.fmtF(usedF))（≈全画幅 \(Optics.fmtF(lensO.equivalentF(usedF)))），只有 1x/2x 主摄能调光圈",
                                 status: .unsupported("固定光圈镜头")))
        }

        // ---- 1b. 光学等效说明 + 超出物理极限的虚化用计算补足 ----
        let usedPupil = lensO.pupil(usedF)
        let m = o.magnification ?? Optics.assumedMagnification
        let opticalBlur = Optics.backgroundBlurFraction(pupilMM: usedPupil, magnification: m)
        let extraBlur = (max(0, o.blurFraction * o.blurFraction - opticalBlur * opticalBlur)).squareRoot()

        changes.append(.init(id: "opt.ref", category: .optics, name: "参考图光学推算",
                             before: "依据：\(o.source.rawValue)",
                             after: o.summary,
                             reason: "用 Apple 端侧模型分割\(o.subjectMaskFound ? "主体" : "（分割失败，按人脸/中央区域）")，分别测量主体与背景边缘的离焦量；背景比主体多出的模糊即光学虚化。" +
                                (o.source == .face ? "按人脸高度≈20cm 推算构图放大率。" : "") +
                                (o.source == .assumed ? "没有人脸和 EXIF，构图按“中景”假设，等效光圈仅供参考。" : ""),
                             status: .info))
        changes.append(.init(id: "opt.phone", category: .optics, name: "iPhone 光学等效",
                             before: "\(lens.rawValue) 实际焦距 \(String(format: "%.1f", lensO.focalActual))mm · 裁切系数 \(String(format: "%.1f", lensO.crop))",
                             after: "\(Optics.fmtF(usedF)) ≈ 全画幅 \(Int(lens.focal35))mm \(Optics.fmtF(lensO.equivalentF(usedF)))，入瞳 \(mm(usedPupil))",
                             reason: "构图相同时，背景虚化只由入瞳直径（实际焦距 ÷ f 值）决定。手机传感器小、实际焦距短，同样的 f 值虚化弱得多，所以要按入瞳而不是按 f 值匹配。",
                             status: .info))
        if let s = o.subjectDistanceM, let f35 = o.focal35, let n = o.equivalentF, s < 30 {
            let refDOF = Optics.depthOfField(focal35: f35, equivalentF: n, subjectM: s)
            let sPhone = Optics.subjectDistance(focal35: lens.focal35, magnification: m)
            let phoneDOF = Optics.depthOfField(focal35: lens.focal35, equivalentF: lensO.equivalentF(usedF), subjectM: sPhone)
            changes.append(.init(id: "opt.dof", category: .optics, name: "景深范围（同样构图）",
                                 before: "参考图：主体 \(String(format: "%.1f", s))m，\(Optics.fmtDOF(refDOF))",
                                 after: "iPhone：主体 \(String(format: "%.1f", sPhone))m，\(Optics.fmtDOF(phoneDOF))",
                                 reason: "全画幅等效空间计算，容许弥散圆 0.03mm。按这个距离站位，画面里主体大小与参考图一致。",
                                 status: .info))
        }
        if extraBlur > 0.003 && !starLook {
            plan.grading.backgroundBlur = extraBlur
            let pct = { (v: Double) in String(format: "%.1f%%", v * 100) }
            changes.append(.init(id: "bokeh", category: .grading, name: "背景虚化（计算补足）",
                                 before: "光学 \(pct(opticalBlur)) 画幅",
                                 after: "目标 \(pct(o.blurFraction))（补 \(pct(extraBlur))）",
                                 reason: "iPhone 入瞳只有 \(mm(usedPupil))，光学虚化能还原约 \(Int(min(1, opticalBlur / max(o.blurFraction, 1e-6)) * 100))%；剩余部分用主体分割蒙版只模糊背景，实时预览和成片一致",
                                 status: .applied))
        }

        // ---- 2. 快门（长曝光 / 运动模糊）----
        if longExposure, let t = profile.exif.exposureTime {
            let s = min(t, caps.shutterRange.upperBound)
            plan.shutter = s
            changes.append(.init(id: "shutter", category: .hardware, name: "快门速度",
                                 before: "\(Fmt.shutter(before.shutter))（自动）",
                                 after: "\(Fmt.shutter(s)) 锁定",
                                 reason: "参考图 EXIF 快门 \(Fmt.shutter(t))，属于长曝光风格，保留拖影/丝滑水流" +
                                    (s < t ? "（已限制在本机最长 \(Fmt.shutter(s))）" : "")))
        }

        // ---- 3. ISO：交给 iOS 27 的优先模式自动补偿 ----
        if plan.aperture != nil || plan.shutter != nil {
            changes.append(.init(id: "iso", category: .newFeature, name: "ISO（优先模式）",
                                 before: "ISO \(Int(before.iso))（全自动）",
                                 after: plan.shutter != nil ? "自动（光圈+快门优先）" : "自动（光圈优先）",
                                 reason: "iOS 27 新增 autoLensAperture/autoISO 优先模式：锁定光圈或快门后，由系统只调 ISO 维持亮度"))
        }

        // ---- 4. 曝光补偿：匹配参考图的明暗基调 ----
        let rawBias = log2(max(profile.meanLuminance, 0.004) / 0.18) * 0.6
        var bias = Float((rawBias * 3).rounded() / 3)
        bias = ColorMath.clamp(bias, max(caps.biasRange.lowerBound, -2), min(caps.biasRange.upperBound, 2))
        plan.bias = bias
        if abs(bias - before.bias) >= 0.3 {
            let key = bias > 0 ? "高调（明亮）" : "低调（暗沉）"
            changes.append(.init(id: "bias", category: .hardware, name: "曝光补偿",
                                 before: Fmt.ev(before.bias), after: Fmt.ev(bias),
                                 reason: "参考图整体偏\(key)，亮度中位数 L*=\(Int(profile.medianL))"))
        }

        // ---- 5. 白平衡：锁定为“自动值 + 参考图色偏” ----
        let dK = ColorMath.clamp(profile.castB * 90, -2000, 2000)
        let dTint = ColorMath.clamp(profile.castA * 3, -40, 40)
        let hasCast = abs(profile.castB) > 1.5 || abs(profile.castA) > 1.5
        if hasCast && caps.supportsCustomWB {
            plan.wbOffset = TempTint(temperature: dK, tint: dTint)
            let target = TempTint(temperature: before.wb.temperature + dK, tint: before.wb.tint + dTint)
            let warm = dK > 0 ? "偏暖" : "偏冷"
            changes.append(.init(id: "wb", category: .hardware, name: "白平衡（传感器增益）",
                                 before: "自动 \(Fmt.wb(before.wb))",
                                 after: "锁定 \(Fmt.wb(target))",
                                 reason: "参考图中性色\(warm)（b*=\(Fmt.signed(profile.castB, 1))，a*=\(Fmt.signed(profile.castA, 1))）→ 在自动白平衡基础上偏移 \(Fmt.signed(dK))K，换场景时自动跟随"))
        } else if hasCast {
            plan.grading.castA = profile.castA
            plan.grading.castB = profile.castB
        }

        // ---- 6. iOS 27 曝光信号 ----
        if !caps.supportedSignals.isEmpty {
            var disabled: [(AVCaptureDeviceExposureSignal, String)] = []
            if starLook { disabled.append((.starburst, "系统默认会开大光圈消除星芒，这里要保留星芒")) }
            if longExposure { disabled.append((.subjectMotion, "系统检测到运动会缩短快门，这里要保留拖影")) }
            if profile.depthOfField == .shallow { disabled.append((.groupPhoto, "多张脸时系统会收光圈加大景深，这里要保留背景虚化")) }
            for (sig, why) in disabled where caps.supportedSignals.contains(sig) {
                plan.disabledSignals.insert(sig)
                changes.append(.init(id: "signal.\(sig.rawValue)", category: .newFeature,
                                     name: "曝光信号：\(Fmt.signalName(sig))",
                                     before: before.enabledSignals.contains(sig) ? "开启（系统自动）" : "关闭",
                                     after: "关闭", reason: why))
            }
        }

        // ---- 7. 全局色调映射（更平、更像胶片的影调）----
        if caps.supportsGlobalToneMapping && (profile.contrast < -0.15 || profile.shadowLift > 0.25) {
            plan.globalToneMapping = true
            if !before.globalToneMapping {
                changes.append(.init(id: "tonemap", category: .hardware, name: "全局色调映射",
                                     before: "关（局部 HDR 处理）", after: "开",
                                     reason: "参考图影调偏平/褪色，关闭局部 HDR 感，影调更统一自然"))
            }
        }

        // ---- 8. 分辨率 ----
        let can48 = caps.photoDimensions.contains { Int($0.width) * Int($0.height) > 40_000_000 }
        if can48 && profile.depthOfField == .deep && !profile.isNight && profile.grain < 0.3 {
            plan.use48MP = true
            changes.append(.init(id: "resolution", category: .hardware, name: "照片分辨率",
                                 before: "24MP", after: "48MP",
                                 reason: "参考图是清晰的大景深画面，用 48MP 保留细节"))
        }

        // ---- 9. 拍照质量优先级（苹果文档要求）----
        if plan.hasManualExposure {
            changes.append(.init(id: "quality", category: .hardware, name: "拍照处理优先级",
                                 before: "质量优先（多帧合成）", after: "速度优先",
                                 reason: "苹果文档：要让锁定的光圈/快门/ISO 在拍照时真正生效，必须用 speed，否则系统会在暗光下改写曝光"))
        }

        // ---- 10. 软件调色 ----
        var g = plan.grading
        g.contrast = profile.contrast * 0.8
        g.shadowLift = profile.shadowLift
        g.highlightRolloff = profile.highlightRolloff
        g.saturation = ColorMath.clamp(profile.saturation, 0.25, 1.6)
        g.shadowTint = profile.shadowTint
        g.highlightTint = profile.highlightTint
        g.vignette = profile.vignette
        g.grain = profile.grain
        g.sharpen = profile.sharpness > 0.3 ? profile.sharpness * 0.5 : 0
        g.softGlow = profile.sharpness < -0.4 ? -profile.sharpness * 0.6 : 0
        plan.grading = g

        func gradingRow(_ id: String, _ name: String, _ after: String, _ reason: String) {
            changes.append(.init(id: id, category: .grading, name: name, before: "原始", after: after,
                                 reason: reason, status: .applied))
        }
        if abs(g.contrast) > 0.08 {
            gradingRow("contrast", "对比度（S 曲线）", Fmt.signed(g.contrast * 100), g.contrast > 0 ? "参考图反差大" : "参考图反差小、偏柔和")
        }
        if g.shadowLift > 0.05 {
            gradingRow("lift", "黑位提升（褪色）", Fmt.percent(g.shadowLift), "参考图最暗处 L*=\(Int(profile.blackPoint))，没有纯黑，胶片/日系常见")
        }
        if g.highlightRolloff > 0.05 {
            gradingRow("rolloff", "高光压缩", Fmt.percent(g.highlightRolloff), "参考图最亮处 L*=\(Int(profile.whitePoint))，高光不死白")
        }
        if abs(g.saturation - 1) > 0.08 {
            gradingRow("sat", "饱和度", Fmt.percent(g.saturation), g.saturation > 1 ? "参考图色彩浓郁" : "参考图色彩淡雅")
        }
        if g.castA != 0 || g.castB != 0 {
            gradingRow("cast", "整体色偏（软件）", "a*\(Fmt.signed(g.castA, 1)) b*\(Fmt.signed(g.castB, 1))", "当前镜头不支持自定义白平衡增益，改用软件补偿")
        }
        if Fmt.tint(g.shadowTint) != "无" {
            gradingRow("shadowTint", "暗部色调（分离色调）", Fmt.tint(g.shadowTint), "参考图暗部偏\(ColorMath.hueName(a: g.shadowTint.x, b: g.shadowTint.y))")
        }
        if Fmt.tint(g.highlightTint) != "无" {
            gradingRow("highlightTint", "高光色调（分离色调）", Fmt.tint(g.highlightTint), "参考图亮部偏\(ColorMath.hueName(a: g.highlightTint.x, b: g.highlightTint.y))")
        }
        if g.vignette > 0.05 { gradingRow("vignette", "暗角", Fmt.percent(g.vignette), "参考图四角明显比中心暗") }
        if g.grain > 0.05 { gradingRow("grain", "胶片颗粒", Fmt.percent(g.grain), "参考图平坦区域有明显颗粒（用软件模拟，而不是提高 ISO 造噪点）") }
        if g.sharpen > 0.05 { gradingRow("sharpen", "锐化", Fmt.percent(g.sharpen), "参考图焦点处细节锐利") }
        if g.softGlow > 0.05 { gradingRow("glow", "柔光（Bloom）", Fmt.percent(g.softGlow), "参考图整体偏柔焦、有光晕感") }

        return (plan, changes)
    }

    /// 把回读结果合并进变更清单
    static func merge(report: ApplyReport, plan: CapturePlan, into changes: inout [ParameterChange]) {
        for i in changes.indices {
            let id = changes[i].id
            if case .unsupported = changes[i].status { continue }
            if changes[i].status == .info { continue }
            if changes[i].category == .grading { continue }
            if let a = report.actual[id] { changes[i].actual = a }
            if id.hasPrefix("signal."), let a = report.actual["signals"] { changes[i].actual = "当前启用：\(a)" }

            var status: ParameterChange.Status = .applied
            if (id == "aperture" || id == "shutter" || id == "iso"), let es = report.exposureStatus {
                status = es
            } else if id == "aperture", let want = plan.aperture, abs(report.actualAperture - want) > 0.1 {
                status = .adjusted("请求 \(Fmt.ap(want))，传感器实际 \(Fmt.ap(report.actualAperture))")
            } else if id == "shutter", let want = plan.shutter, report.actualShutter > 0,
                      max(want, report.actualShutter) / min(want, report.actualShutter) > 1.3 {
                status = .adjusted("请求 \(Fmt.shutter(want))，预览实际 \(Fmt.shutter(report.actualShutter))（长快门在拍照时才完整生效）")
            }
            changes[i].status = status
        }
    }
}
