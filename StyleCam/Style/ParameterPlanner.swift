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
        if profile.faceCount == 1 && profile.depthOfField == .shallow {
            return (.wide2x, "单人 + 浅景深，判断为人像 → 48mm 人像焦段")
        }
        return (.wide, "无焦距信息，使用主摄（唯一带可变光圈的镜头）")
    }

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
        let stops = caps.apertureStops.isEmpty ? [caps.apertureRange.lowerBound] : caps.apertureStops

        // ---- 1. 物理可变光圈（18 Pro Max 新硬件 + iOS 27 API）----
        if caps.hasVariableAperture && lens.hasVariableAperture {
            var target: Float
            var why: String
            if profile.exif.isFromIPhone, let f = profile.exif.fNumber, f > 1.2 {
                target = Float(f)
                why = "参考图是 iPhone 拍的，EXIF 光圈 \(Fmt.ap(Float(f)))，直接复用"
            } else {
                switch profile.depthOfField {
                case .shallow:
                    target = stops.first ?? 1.48
                    why = "参考图背景虚化明显 → 开到最大光圈，用光学虚化而不是人像模式算法"
                case .medium:
                    target = 2.8
                    why = "参考图主体清晰、背景略虚 → 中等光圈"
                case .deep:
                    target = stops.last ?? 4
                    why = "参考图前后景都清晰 → 收小光圈加大景深"
                }
                if profile.faceCount >= 3 && target < 2.8 {
                    target = 2.8
                    why = "参考图是合影（\(profile.faceCount) 张脸）→ 至少 f/2.8 保证每张脸清晰"
                }
            }
            if starLook {
                target = stops.last ?? 4
                why = "参考图是夜景且有 \(profile.pointLightCount) 个点光源 → 收到最小光圈出星芒"
            }
            if longExposure {
                target = stops.last ?? 4
                why += "；为配合长曝光收小光圈减光（相当于内置 ND）"
            }
            let snapped = stops.min { abs($0 - target) < abs($1 - target) } ?? target
            plan.aperture = snapped
            changes.append(.init(id: "aperture", category: .newFeature, name: "物理可变光圈",
                                 before: "\(Fmt.ap(before.aperture))（自动）",
                                 after: "\(Fmt.ap(snapped)) 锁定",
                                 reason: why))
        } else if lens.hasVariableAperture == false {
            changes.append(.init(id: "aperture", category: .newFeature, name: "物理可变光圈",
                                 before: Fmt.ap(before.aperture), after: "不可调",
                                 reason: "\(lens.rawValue) 镜头为固定光圈，只有 1x/2x 主摄能调光圈",
                                 status: .unsupported("固定光圈镜头")))
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
