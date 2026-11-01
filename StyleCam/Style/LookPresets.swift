import Foundation
import SwiftUI

/// 内置滤镜：佳能 / 富士常用的网红风格，按情绪分组。
/// 参数是按各胶片模拟 / 照片风格公开的观感特征仿制的近似值，并非厂商官方配置。
/// Lab 色相参考：红 ~30°，橙/肤色 ~60°，黄 ~90°，绿 ~135°，青 ~200°，蓝 ~265°，品红 ~330°
enum PresetMood: String, CaseIterable, Identifiable {
    case gentle = "温柔治愈"
    case nostalgic = "复古怀旧"
    case cool = "清冷高级"
    case vivid = "浓郁热烈"
    case cinematic = "电影叙事"
    case mono = "黑白经典"
    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .gentle: return "🌸"
        case .nostalgic: return "📼"
        case .cool: return "🌫️"
        case .vivid: return "🔥"
        case .cinematic: return "🎬"
        case .mono: return "🖤"
        }
    }
}

enum PresetBrand: String, CaseIterable, Identifiable {
    case fuji = "富士"
    case canon = "佳能"
    var id: String { rawValue }
}

struct LookPreset: Identifiable {
    let id: String
    let name: String          // 显示名：xxx 同款
    let brand: PresetBrand
    let mood: PresetMood
    let note: String          // 观感说明
    let grading: GradingParams
}

enum LookPresets {
    /// 富士式“高光 / 阴影”色调（-2…+4）→ 21 点影调曲线
    static func toneCurve(highlights h: Double = 0, shadows s: Double = 0, mids m: Double = 0) -> [Double] {
        StyleMatcher.grid.map { L in
            let shadowBump = exp(-pow((L - 22) / 14, 2))
            let highBump = exp(-pow((L - 80) / 13, 2))
            let midBump = exp(-pow((L - 50) / 18, 2))
            return ColorMath.clamp(L - s * 3.0 * shadowBump + h * 3.0 * highBump + m * 3.0 * midBump, 0, 100)
        }
    }

    static let typicalPhoneGrain = 0.0028

    private static func make(_ body: (inout GradingParams) -> Void) -> GradingParams {
        var g = GradingParams()
        g.skinProtect = 0.5
        body(&g)
        if let t = g.grainTarget {
            // 颗粒按“目标总颗粒”给出；实际补多少由实时测得的画面噪点反推，这里先按 iPhone 原片约 0.0028 估一个初值
            g.grain = 1
            g.grainAddSigma = (max(0, t * t - typicalPhoneGrain * typicalPhoneGrain)).squareRoot()
        }
        return g
    }


    static let all: [LookPreset] = [
        // MARK: 温柔治愈
        LookPreset(id: "canon-portrait", name: "佳能 人像·奶油肤色同款", brand: .canon, mood: .gentle,
                   note: "佳能照片风格“人像”：肤色偏粉嫩通透，影调柔和，绿色不抢戏",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: -0.5, shadows: -0.5, mids: 0.5)
                       $0.saturation = 0.95; $0.castA = 1.2; $0.castB = 1.5
                       $0.hsl = [HSLBand(hue: 55, width: 30, dHue: -5, sat: 0.92, dL: 2.5),
                                 HSLBand(hue: 135, width: 40, sat: 0.85)]
                       $0.highlightRolloff = 0.08
                       $0.skinProtect = 0
                   }),
        LookPreset(id: "fuji-astia", name: "富士 Astia 同款", brand: .fuji, mood: .gentle,
                   note: "柔和人像：低反差、肤色细腻，蓝天和衣物颜色仍然清透",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: -1, shadows: -1)
                       $0.saturation = 1.05
                       $0.hsl = [HSLBand(hue: 265, sat: 1.1), HSLBand(hue: 60, width: 30, sat: 0.95, dL: 1.5)]
                   }),
        LookPreset(id: "fuji-reggie-portra", name: "富士 Reggie's Portra 配方同款", brand: .fuji, mood: .gentle,
                   note: "Fuji X Weekly 热门配方（Classic Chrome 底）：Portra 胶片的暖调与柔和肤色，万能日常",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: -1, shadows: -0.5)
                       $0.saturation = 0.9; $0.castA = 1.5; $0.castB = 4
                       $0.shadowLift = 0.04; $0.highlightRolloff = 0.08
                       $0.hsl = [HSLBand(hue: 135, width: 40, dHue: -10, sat: 0.8), HSLBand(hue: 60, width: 30, sat: 1.05)]
                       $0.grainTarget = 0.0048
                   }),
        LookPreset(id: "fuji-reala-ace", name: "富士 Reala Ace 同款", brand: .fuji, mood: .gentle,
                   note: "富士最新胶片模拟：颜色真实自然、反差适中，日系清新直出",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: 0.5)
                       $0.saturation = 1.05; $0.castB = 1
                   }),

        // MARK: 复古怀旧
        LookPreset(id: "fuji-classic-chrome", name: "富士 Classic Chrome 同款", brand: .fuji, mood: .nostalgic,
                   note: "经典纪实感：颜色克制偏灰、暗部更沉，蓝色偏青、红色偏砖红",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: 1.5)
                       $0.saturation = 0.75; $0.castB = 1
                       $0.hsl = [HSLBand(hue: 265, dHue: -15, sat: 0.85), HSLBand(hue: 30, dHue: 6, sat: 0.85),
                                 HSLBand(hue: 135, width: 40, dHue: 8, sat: 0.8)]
                       $0.grainTarget = 0.0042
                   }),
        LookPreset(id: "fuji-kodachrome64", name: "富士 Kodachrome 64 配方同款", brand: .fuji, mood: .nostalgic,
                   note: "Fuji X Weekly 长年第一的配方：Classic Chrome 底 + 暖白平衡，红黄浓、蓝色深，老杂志感",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: 1.5)
                       $0.saturation = 1.0; $0.castA = 2; $0.castB = 5
                       $0.hsl = [HSLBand(hue: 30, sat: 1.2), HSLBand(hue: 90, sat: 1.1),
                                 HSLBand(hue: 265, dHue: -10, sat: 1.1, dL: -4), HSLBand(hue: 135, width: 40, sat: 0.85)]
                       $0.grainTarget = 0.0048
                   }),
        LookPreset(id: "fuji-kodak-gold", name: "富士 Kodak Gold 200 配方同款", brand: .fuji, mood: .nostalgic,
                   note: "金黄暖调的夏日胶片：黄色和肤色暖、绿色偏黄，适合阳光街拍",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0, shadows: 1)
                       $0.saturation = 1.05; $0.castA = 1.5; $0.castB = 8
                       $0.hsl = [HSLBand(hue: 90, sat: 1.2), HSLBand(hue: 135, width: 40, dHue: -12, sat: 0.9)]
                       $0.highlightTint = SIMD2(1, 3)
                       $0.grainTarget = 0.0055
                   }),
        LookPreset(id: "fuji-nostalgic-neg", name: "富士 Nostalgic Neg 同款", brand: .fuji, mood: .nostalgic,
                   note: "70 年代美国新彩色摄影风：高光琥珀暖色、暗部浓郁，整体柔和",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: -1.5, shadows: 0.5)
                       $0.saturation = 1.0; $0.castB = 2
                       $0.highlightTint = SIMD2(2, 7); $0.shadowTint = SIMD2(0, -1)
                       $0.highlightRolloff = 0.1
                       $0.grainTarget = 0.0048
                   }),
        LookPreset(id: "fuji-classic-neg", name: "富士 Classic Neg 同款", brand: .fuji, mood: .nostalgic,
                   note: "仿 Superia 负片：反差硬、暗部偏青、高光偏品红，绿色发青黄，街头感强",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 1, shadows: 2)
                       $0.saturation = 0.85
                       $0.shadowTint = SIMD2(-3, -4); $0.highlightTint = SIMD2(2, 3)
                       $0.hsl = [HSLBand(hue: 135, width: 40, dHue: 15, sat: 0.85), HSLBand(hue: 30, dHue: -8, sat: 0.9)]
                       $0.grainTarget = 0.0055
                   }),
        LookPreset(id: "canon-ccd", name: "佳能 IXUS CCD 同款", brand: .canon, mood: .nostalgic,
                   note: "千禧年卡片机风：偏冷青、高光通透略过曝、轻微光晕，复古数码感",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 2, shadows: 1, mids: 1)
                       $0.saturation = 1.1; $0.castA = -1; $0.castB = -3
                       $0.hsl = [HSLBand(hue: 265, dHue: -12, sat: 1.15), HSLBand(hue: 135, width: 40, dHue: -10, sat: 1.1)]
                       $0.softGlow = 0.35; $0.sharpen = 0.3
                       $0.grainTarget = 0.0042
                   }),

        // MARK: 清冷高级
        LookPreset(id: "fuji-pacific-blues", name: "富士 Pacific Blues 配方同款", brand: .fuji, mood: .cool,
                   note: "Fuji X Weekly 最热门的 Classic Neg 配方：清冷蓝青调，海边、城市阴天很出片",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0, shadows: 1)
                       $0.saturation = 0.9; $0.castA = -1; $0.castB = -4
                       $0.hsl = [HSLBand(hue: 265, dHue: -8, sat: 1.15), HSLBand(hue: 135, width: 40, dHue: 20, sat: 0.85)]
                       $0.shadowTint = SIMD2(-2, -3)
                       $0.grainTarget = 0.0048
                   }),
        LookPreset(id: "canon-neutral-cool", name: "佳能 中性·清冷同款", brand: .canon, mood: .cool,
                   note: "照片风格“中性”加冷白平衡：低饱和、干净克制的高级灰",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: -0.5, shadows: -0.5)
                       $0.saturation = 0.75; $0.castB = -3
                       $0.highlightTint = SIMD2(-1, -2)
                   }),

        // MARK: 浓郁热烈
        LookPreset(id: "fuji-velvia", name: "富士 Velvia 同款", brand: .fuji, mood: .vivid,
                   note: "风光反转片：高饱和、高反差，蓝天绿植极其浓郁",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 1, shadows: 2)
                       $0.saturation = 1.35
                       $0.hsl = [HSLBand(hue: 135, width: 40, sat: 1.2), HSLBand(hue: 265, sat: 1.2, dL: -3)]
                   }),
        LookPreset(id: "canon-landscape", name: "佳能 风景同款", brand: .canon, mood: .vivid,
                   note: "照片风格“风景”：蓝绿鲜明、轮廓清晰",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: 1)
                       $0.saturation = 1.15
                       $0.hsl = [HSLBand(hue: 135, width: 40, dHue: 5, sat: 1.25), HSLBand(hue: 265, sat: 1.25)]
                       $0.sharpen = 0.3
                   }),
        LookPreset(id: "canon-g7x", name: "佳能 G7X 网红色同款", brand: .canon, mood: .vivid,
                   note: "vlog 网红卡片机直出：明亮、红润、颜色讨喜",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: -0.5, mids: 1.5)
                       $0.saturation = 1.15; $0.castA = 2; $0.castB = 1
                       $0.hsl = [HSLBand(hue: 30, sat: 1.15), HSLBand(hue: 350, sat: 1.15), HSLBand(hue: 60, width: 30, dHue: -4, dL: 2)]
                       $0.skinProtect = 0
                   }),

        // MARK: 电影叙事
        LookPreset(id: "fuji-eterna", name: "富士 Eterna 电影同款", brand: .fuji, mood: .cinematic,
                   note: "电影负片：低饱和、低反差、暗部偏青，适合拍故事感的画面",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: -1.5, shadows: -1.5)
                       $0.saturation = 0.65; $0.shadowLift = 0.05
                       $0.shadowTint = SIMD2(-2, -3); $0.highlightTint = SIMD2(1, 2)
                   }),
        LookPreset(id: "fuji-bleach-bypass", name: "富士 Eterna 漂白效果同款", brand: .fuji, mood: .cinematic,
                   note: "银留（Bleach Bypass）：去饱和、高反差，冷硬的电影质感",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 2, shadows: 2.5)
                       $0.saturation = 0.45
                       $0.grainTarget = 0.0055
                   }),
        LookPreset(id: "fuji-cinestill", name: "富士 CineStill 800T 配方同款", brand: .fuji, mood: .cinematic,
                   note: "Fuji X Weekly 配方（Eterna 底）：钨丝灯片偏冷、灯光带红色光晕，夜景霓虹神器",
                   grading: make {
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: 1)
                       $0.saturation = 0.95; $0.castA = 1; $0.castB = -7
                       $0.shadowTint = SIMD2(-2, -3)
                       $0.hsl = [HSLBand(hue: 30, sat: 1.15)]
                       $0.halation = 0.55
                       $0.grainTarget = 0.006
                   }),

        // MARK: 黑白经典
        LookPreset(id: "fuji-acros", name: "富士 Acros 同款", brand: .fuji, mood: .mono,
                   note: "富士黑白：层次细腻、中灰丰富、颗粒细",
                   grading: make {
                       $0.monochrome = true
                       $0.toneCurve = toneCurve(highlights: 0.5, shadows: 1)
                       $0.grainTarget = 0.0055
                   }),
        LookPreset(id: "fuji-trix", name: "富士 Tri-X 400 配方同款", brand: .fuji, mood: .mono,
                   note: "Fuji X Weekly 最热门黑白配方（Acros 底）：高反差、粗颗粒，经典街拍黑白",
                   grading: make {
                       $0.monochrome = true
                       $0.toneCurve = toneCurve(highlights: 1.5, shadows: 2.5)
                       $0.grainTarget = 0.0085
                   }),
        LookPreset(id: "canon-mono", name: "佳能 单色·暖调同款", brand: .canon, mood: .mono,
                   note: "照片风格“单色”+ 棕褐色调：温暖柔和的黑白",
                   grading: make {
                       $0.monochrome = true
                       $0.castA = 1.5; $0.castB = 5
                       $0.toneCurve = toneCurve(highlights: -0.5, shadows: 0.5)
                   }),
    ]

    static func preset(id: String) -> LookPreset? { all.first { $0.id == id } }

    static func hueName(_ h: Double) -> String {
        switch (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) {
        case ..<15, 345...: return "品红"
        case ..<45: return "红"
        case ..<75: return "橙/肤色"
        case ..<110: return "黄"
        case ..<170: return "绿"
        case ..<230: return "青"
        case ..<300: return "蓝"
        default: return "紫"
        }
    }

    /// 参数面板里列出的“这个滤镜改了什么”
    static func changes(for p: LookPreset) -> [ParameterChange] {
        let g = p.grading
        var rows: [ParameterChange] = []
        func row(_ id: String, _ name: String, _ after: String, _ why: String) {
            rows.append(ParameterChange(id: "preset-" + id, category: .grading, name: name, before: "原片",
                                        after: after, reason: why, status: .applied))
        }
        rows.append(ParameterChange(id: "preset", category: .grading, name: "内置滤镜", before: "无",
                                    after: p.name, reason: p.note + "（仿色风格，非厂商官方配置）", status: .info))
        if let c = g.toneCurve {
            let d = { (i: Int) in c[i] - StyleMatcher.grid[i] }
            row("tone", "影调曲线", "暗部 \(Fmt.signed(d(4), 1)) · 中间 \(Fmt.signed(d(10), 1)) · 高光 \(Fmt.signed(d(16), 1)) L*",
                "按胶片模拟的高光 / 阴影色调设定（负值 = 压暗，正值 = 提亮）")
        }
        if g.monochrome {
            row("mono", "黑白", g.castA != 0 || g.castB != 0 ? "黑白 + 染色 a*\(Fmt.signed(g.castA, 1)) b*\(Fmt.signed(g.castB, 1))" : "黑白", "去掉颜色，只保留明暗层次")
        } else {
            if abs(g.saturation - 1) > 0.01 { row("sat", "饱和度", Fmt.percent(g.saturation), g.saturation > 1 ? "颜色更浓" : "颜色更克制") }
            if g.castA != 0 || g.castB != 0 {
                row("cast", "整体色偏", "\(ColorMath.hueName(a: g.castA, b: g.castB)) a*\(Fmt.signed(g.castA, 1)) b*\(Fmt.signed(g.castB, 1))", "模拟白平衡 / 胶片片基的色调")
            }
            if g.shadowTint != .zero || g.highlightTint != .zero {
                row("split", "分离色调", "暗部 \(ColorMath.hueName(a: g.shadowTint.x, b: g.shadowTint.y)) · 高光 \(ColorMath.hueName(a: g.highlightTint.x, b: g.highlightTint.y))", "暗部和高光分别染色")
            }
            for (i, b) in g.hsl.enumerated() {
                var parts: [String] = []
                if b.dHue != 0 { parts.append("色相 \(Fmt.signed(b.dHue))°") }
                if b.sat != 1 { parts.append("饱和 \(Fmt.percent(b.sat))") }
                if b.dL != 0 { parts.append("亮度 \(Fmt.signed(b.dL, 1))") }
                row("hsl\(i)", "\(hueName(b.hue))色", parts.joined(separator: " · "), "按色相单独调整")
            }
        }
        if let t = g.grainTarget {
            row("grain", "颗粒", String(format: "目标总颗粒 σ %.4f", t), "按取景画面已有的噪点反推只补差值，不和 iPhone 降噪 / 压缩噪点叠加")
        }
        if g.halation > 0 { row("halation", "高光光晕", Fmt.percent(g.halation), "模拟胶片高光周围的红色光晕") }
        if g.softGlow > 0 { row("glow", "柔光", Fmt.percent(g.softGlow), "高光微微发散") }
        if g.sharpen > 0 { row("sharpen", "锐化", Fmt.percent(g.sharpen), "轮廓更清晰") }
        if g.vignette > 0 { row("vignette", "暗角", Fmt.percent(g.vignette), "四角压暗") }
        rows.append(ParameterChange(id: "preset-exposure", category: .hardware, name: "曝光 / 白平衡", before: "自动",
                                    after: "自动", reason: "内置滤镜不锁定硬件参数，只改调色；需要按某张照片调光圈快门时请用参考图", status: .info))
        return rows
    }
}

// MARK: - 胶卷外观（胶卷柜里的片盒颜色、片边印字、感光度）

struct FilmStock {
    let code: String      // 片边印字
    let iso: Int
}

extension LookPreset {
    var stock: FilmStock {
        switch id {
        case "canon-portrait":     return FilmStock(code: "PORTRAIT", iso: 200)
        case "fuji-astia":         return FilmStock(code: "ASTIA 100F", iso: 100)
        case "fuji-reggie-portra": return FilmStock(code: "PORTRA 400 RCP", iso: 400)
        case "fuji-reala-ace":     return FilmStock(code: "REALA ACE", iso: 100)
        case "fuji-classic-chrome":return FilmStock(code: "CLASSIC CHROME", iso: 200)
        case "fuji-kodachrome64":  return FilmStock(code: "KODACHROME 64 RCP", iso: 64)
        case "fuji-kodak-gold":    return FilmStock(code: "GOLD 200 RCP", iso: 200)
        case "fuji-nostalgic-neg": return FilmStock(code: "NOSTALGIC NEG", iso: 400)
        case "fuji-classic-neg":   return FilmStock(code: "CLASSIC NEG", iso: 400)
        case "canon-ccd":          return FilmStock(code: "IXUS CCD", iso: 100)
        case "fuji-pacific-blues": return FilmStock(code: "PACIFIC BLUES RCP", iso: 400)
        case "canon-neutral-cool": return FilmStock(code: "NEUTRAL COOL", iso: 100)
        case "fuji-velvia":        return FilmStock(code: "VELVIA 50", iso: 50)
        case "canon-landscape":    return FilmStock(code: "LANDSCAPE", iso: 100)
        case "canon-g7x":          return FilmStock(code: "G7X VLOG", iso: 200)
        case "fuji-eterna":        return FilmStock(code: "ETERNA 250D", iso: 250)
        case "fuji-bleach-bypass": return FilmStock(code: "ETERNA BB", iso: 500)
        case "fuji-cinestill":     return FilmStock(code: "800T RCP", iso: 800)
        case "fuji-acros":         return FilmStock(code: "ACROS 100", iso: 100)
        case "fuji-trix":          return FilmStock(code: "TRI-X 400 RCP", iso: 400)
        case "canon-mono":         return FilmStock(code: "MONO SEPIA", iso: 100)
        default:                   return FilmStock(code: name, iso: 200)
        }
    }
}

// MARK: - 片盒标签名（原创命名，不使用厂商包装）与网上样片链接

extension LookPreset {
    var labelTitle: String {
        [
            "canon-portrait": "奶油肌", "fuji-astia": "柔光", "fuji-reggie-portra": "暖人像", "fuji-reala-ace": "清透日常",
            "fuji-classic-chrome": "纪实灰", "fuji-kodachrome64": "老杂志", "fuji-kodak-gold": "金色夏日",
            "fuji-nostalgic-neg": "琥珀年代", "fuji-classic-neg": "街头负片", "canon-ccd": "千禧数码",
            "fuji-pacific-blues": "海风蓝", "canon-neutral-cool": "高级灰", "fuji-velvia": "浓郁风光",
            "canon-landscape": "山野", "canon-g7x": "元气", "fuji-eterna": "电影感", "fuji-bleach-bypass": "银留",
            "fuji-cinestill": "霓虹夜", "fuji-acros": "细腻黑白", "fuji-trix": "街拍黑白", "canon-mono": "棕调黑白"
        ][id] ?? name
    }

    /// 小红书上搜这个风格的关键词
    private var searchKeyword: String {
        [
            "canon-portrait": "佳能 人像 直出", "fuji-astia": "富士 Astia 直出", "fuji-reggie-portra": "富士 Reggie's Portra 配方",
            "fuji-reala-ace": "富士 Reala Ace 直出", "fuji-classic-chrome": "富士 Classic Chrome 直出",
            "fuji-kodachrome64": "富士 Kodachrome 64 配方", "fuji-kodak-gold": "富士 Kodak Gold 200 配方",
            "fuji-nostalgic-neg": "富士 Nostalgic Neg 直出", "fuji-classic-neg": "富士 Classic Neg 直出",
            "canon-ccd": "佳能 IXUS CCD 直出", "fuji-pacific-blues": "富士 Pacific Blues 配方",
            "canon-neutral-cool": "佳能 中性 冷调 直出", "fuji-velvia": "富士 Velvia 直出", "canon-landscape": "佳能 风景 照片风格",
            "canon-g7x": "佳能 G7X 直出", "fuji-eterna": "富士 Eterna 直出", "fuji-bleach-bypass": "富士 Eterna Bleach Bypass",
            "fuji-cinestill": "富士 CineStill 800T 配方", "fuji-acros": "富士 Acros 直出", "fuji-trix": "富士 Tri-X 400 配方",
            "canon-mono": "佳能 单色 棕褐"
        ][id] ?? name
    }

    /// 网上同款样片：原配方 / 介绍页（有的话）+ 小红书搜索
    var sampleLinks: [SampleLink] {
        var out: [SampleLink] = []
        let pages: [String: String] = [
            "fuji-reggie-portra": "https://fujixweekly.com/2022/06/11/fujifilm-x-trans-iv-film-simulation-recipe-reggies-portra/",
            "fuji-kodachrome64": "https://fujixweekly.com/2019/08/02/my-fujifilm-x-t30-kodachrome-64-film-simulation-recipe/",
            "fuji-kodak-gold": "https://fujixweekly.com/2023/10/24/kodak-gold-200-fujifilm-x-t5-x-trans-v-film-simulation-recipe/",
            "fuji-pacific-blues": "https://fujixweekly.com/2022/08/04/fujifilm-x-e4-x-trans-iv-film-simulation-recipe-pacific-blues/",
            "fuji-cinestill": "https://fujixweekly.com/2024/04/16/cinestill-800t-fujifilm-x-trans-v-film-simulation-recipe/",
            "fuji-trix": "https://fujixweekly.com/2020/06/18/fujifilm-x100v-film-simulation-recipe-kodak-tri-x-400/",
            "fuji-classic-chrome": "https://fujixweekly.com/2024/03/11/my-15-favorite-film-simulation-recipes-that-use-classic-chrome/",
            "fuji-classic-neg": "https://fujixweekly.com/2024/03/20/my-15-favorite-film-simulation-recipes-that-use-classic-negative/",
            "fuji-nostalgic-neg": "https://fujixweekly.com/2024/03/27/my-5-favorite-film-simulation-recipes-that-use-nostalgic-neg/",
            "fuji-acros": "https://fujixweekly.com/2024/05/04/my-5-favorite-film-simulation-recipes-that-use-acros/",
            "fuji-reala-ace": "https://fujixweekly.com/tag/reala-ace-recipe"
        ]
        if let s = pages[id], let u = URL(string: s) { out.append(SampleLink(title: "Fuji X Weekly 原配方样片", url: u)) }
        var c = URLComponents(string: "https://www.xiaohongshu.com/search_result")!
        c.queryItems = [URLQueryItem(name: "keyword", value: searchKeyword)]
        if let u = c.url { out.append(SampleLink(title: "小红书搜「\(searchKeyword)」", url: u)) }
        return out
    }

    /// 片盒配色：几种典型颜色经过这个滤镜后的样子（肤色、天空、植物、红、金、暗部、纸白）
    var palette: [Color] {
        let base: [(Double, Double, Double)] = [(0.87, 0.67, 0.55), (0.45, 0.65, 0.88), (0.35, 0.60, 0.30),
                                                (0.80, 0.22, 0.20), (0.95, 0.80, 0.30), (0.18, 0.18, 0.20), (0.93, 0.91, 0.86)]
        var g = grading
        g.strength = 1
        return base.map { c in
            let o = LUTBuilder.mapColor(c.0, c.1, c.2, g)
            return Color(red: o.0, green: o.1, blue: o.2)
        }
    }

    /// 稳定的伪随机种子（按 id）
    var seed: UInt64 { id.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 } }
}

struct SampleLink: Identifiable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - StyleCam 自有包装配色：全部由滤镜本身推导

struct Packaging {
    let primary: Color      // 主色块：这个滤镜最“提”的那个颜色
    let secondary: Color    // 副色块：与主色色相拉开的颜色
    let paper: Color        // 底色：纸白经过滤镜后的颜色
    let ink: Color          // 文字 / 图标
    let darkBody: Bool      // 深色盒身（电影 / 黑白）
}

extension LookPreset {
    var packaging: Packaging {
        let base: [(Double, Double, Double)] = [(0.87, 0.67, 0.55), (0.45, 0.65, 0.88), (0.35, 0.60, 0.30),
                                                (0.80, 0.22, 0.20), (0.95, 0.80, 0.30)]
        var g = grading
        g.strength = 1
        func lab(_ c: (Double, Double, Double)) -> (L: Double, a: Double, b: Double) {
            ColorMath.linearRGBToLab(ColorMath.srgbToLinear(c.0), ColorMath.srgbToLinear(c.1), ColorMath.srgbToLinear(c.2))
        }
        func color(_ c: (Double, Double, Double)) -> Color { Color(red: c.0, green: c.1, blue: c.2) }
        let mapped = base.map { LUTBuilder.mapColor($0.0, $0.1, $0.2, g) }
        let paperC = LUTBuilder.mapColor(0.93, 0.91, 0.86, g)
        let inkC = LUTBuilder.mapColor(0.14, 0.13, 0.13, g)
        if grading.monochrome {
            let mid = LUTBuilder.mapColor(0.55, 0.55, 0.55, g)
            return Packaging(primary: color(inkC), secondary: color(mid), paper: color(paperC), ink: color(inkC), darkBody: false)
        }
        // 主色：输出彩度 ×（滤镜对它的增强比例）^1.5，取最有性格的那个
        let scored: [(i: Int, score: Double, hue: Double, chroma: Double)] = base.indices.map { i in
            let o = lab(mapped[i]), r = lab(base[i])
            let co = (o.a * o.a + o.b * o.b).squareRoot(), ci = max(1, (r.a * r.a + r.b * r.b).squareRoot())
            return (i, co * pow(co / ci, 1.5), atan2(o.b, o.a) * 180 / .pi, co)
        }
        // 清冷款偏向蓝灰：越接近蓝色（Lab 色相约 250°）权重越高
        func hueDist(_ x: Double, _ y: Double) -> Double { let v = abs(x - y).truncatingRemainder(dividingBy: 360); return min(v, 360 - v) }
        func bias(_ hue: Double) -> Double {
            mood == .cool ? 1 + 3 * max(0, 1 - hueDist(hue < 0 ? hue + 360 : hue, 250) / 70) : 1
        }
        let first = scored.max { $0.score * bias($0.hue) < $1.score * bias($1.hue) }!
        // 副色：色相和主色拉开（>35°）的里面，被这个滤镜加强得最多的那个
        let others = scored.filter { $0.i != first.i }
        let apart = others.filter { hueDist($0.hue, first.hue) > 35 }
        let second = (apart.isEmpty ? others : apart).max { $0.score * bias($0.hue) < $1.score * bias($1.hue) }!
        return Packaging(primary: color(mapped[first.i]), secondary: color(mapped[second.i]),
                         paper: color(paperC), ink: color(inkC), darkBody: mood == .cinematic)
    }
}

extension LookPreset {
    /// 在同一情绪组里的序号（决定片盒色块用这一组的第几种版式）
    var moodIndex: Int { LookPresets.all.filter { $0.mood == mood }.firstIndex { $0.id == id } ?? 0 }
}
