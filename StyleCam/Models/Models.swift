import Foundation
import AVFoundation
import CoreGraphics

// MARK: - 镜头（iPhone 18 Pro Max：0.5x / 1x / 2x / 4x / 8x 五个光学级焦段）

enum LensChoice: String, CaseIterable, Identifiable {
    case ultraWide = "0.5x"
    case wide = "1x"
    case wide2x = "2x"
    case tele = "4x"
    case tele8x = "8x"

    var id: String { rawValue }

    /// 等效 35mm 焦距
    var focal35: Double {
        switch self {
        case .ultraWide: return 13
        case .wide: return 24
        case .wide2x: return 48
        case .tele: return 100
        case .tele8x: return 200
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .wide2x: return .builtInWideAngleCamera
        case .tele, .tele8x: return .builtInTelephotoCamera
        }
    }

    /// 2x 与 8x 是在主摄 / 长焦上做传感器中心裁切
    var zoomFactor: CGFloat {
        switch self {
        case .wide2x, .tele8x: return 2
        default: return 1
        }
    }

    /// 只有主摄（1x / 2x）有物理可变光圈
    var hasVariableAperture: Bool { self == .wide || self == .wide2x }

    static func nearest(toFocal35 f: Double) -> LensChoice {
        allCases.min { abs(log($0.focal35 / f)) < abs(log($1.focal35 / f)) } ?? .wide
    }
}

// MARK: - 参考图 EXIF

struct ReferenceEXIF: Equatable {
    var make: String?
    var model: String?
    var lensModel: String?
    var fNumber: Double?
    var focalLength: Double?           // 实际焦距 mm
    var exposureTime: Double?
    var iso: Double?
    var focalLength35mm: Double?
    var exposureBias: Double?

    var isFromIPhone: Bool { (make ?? "").lowercased().contains("apple") }
    var hasExposureInfo: Bool { fNumber != nil || exposureTime != nil || iso != nil }
}

enum DepthOfField: String {
    case shallow = "浅景深（背景虚化明显）"
    case medium = "中等景深"
    case deep = "大景深（前后都清晰）"
}

// MARK: - 风格画像：纯图像统计，与设备无关

struct StyleProfile: Equatable {
    // 影调
    var meanLuminance: Double      // 线性亮度均值 0...1
    var medianL: Double            // L* 中位数 0...100
    var blackPoint: Double         // L* 第 1 百分位
    var whitePoint: Double         // L* 第 99 百分位
    var contrast: Double           // -1...1，相对普通照片
    var shadowLift: Double         // 0...1 暗部发灰/褪色程度
    var highlightRolloff: Double   // 0...1 高光被压低程度
    // 色彩
    var saturation: Double         // 饱和度倍率（1 = 普通照片）
    var castA: Double              // 中性色 a* 偏移：+品红 / -绿
    var castB: Double              // 中性色 b* 偏移：+暖黄 / -冷蓝
    var shadowTint: SIMD2<Double>  // 暗部色调 (a*, b*)
    var highlightTint: SIMD2<Double>
    // 质感
    var vignette: Double           // 0...1
    var grain: Double              // 0...1
    var sharpness: Double          // -1...1（负数 = 柔焦感）
    // 场景
    var depthOfField: DepthOfField
    var isNight: Bool
    var pointLightCount: Int
    var faceCount: Int
    var histogram: [Double]        // 32 档 L* 直方图（归一化）
    var exif: ReferenceEXIF
    var optics: ReferenceOptics
    var refStats: SceneStats       // 用于实时匹配的参考图统计
    var refTexture: TextureStats   // 参考图质感（观看尺度，已排除 JPEG 块边界）
    var aspect: Double             // 长边 / 短边
    var isLandscape: Bool
    var faceRect: CGRect?          // 最大人脸，归一化、左上角原点
    var subjectRect: CGRect?       // 主体外接框，归一化、左上角原点
    var greenAB: SIMD2<Double>?    // 植物颜色（Lab a*/b* 中位数）
    var skyAB: SIMD2<Double>?      // 天空颜色

    /// 实时闭环用：参考图平均彩度
    var meanChroma: Double { saturation * 17 }
}

// MARK: - 软件调色参数（实时滤镜）

struct GradingParams: Equatable {
    var exposureEV: Double = 0
    var toneCurve: [Double]?            // 影调匹配曲线：输入 L*=0,5,…,100 时的输出（由 StyleMatcher 实时计算）
    var contrast: Double = 0            // -1...1
    var shadowLift: Double = 0          // 0...1
    var highlightRolloff: Double = 0    // 0...1
    var saturation: Double = 1          // 倍率
    var castA: Double = 0               // 硬件白平衡无法覆盖时的残余色偏
    var castB: Double = 0
    var shadowTint = SIMD2<Double>(0, 0)
    var highlightTint = SIMD2<Double>(0, 0)
    var vignette: Double = 0
    var grain: Double = 0
    var sharpen: Double = 0
    var softGlow: Double = 0
    var backgroundBlur: Double = 0      // 计算补足的背景虚化：弥散圆直径 / 画面长边
    var grainAddSigma: Double = 0       // 需要补的颗粒（观看尺度 σ）=√(参考² − 当前画面²)；grain 作为倍率
    var blurSigmaView: Double = 0       // 需要补的柔化（观看尺度像素）
    var cropRatio: Double?              // 按参考图画幅裁切（长边 / 短边），沿画面长边方向
    var halation: Double = 0            // 胶片高光光晕 0...1
    var skinProtect: Double = 0.7       // 肤色保护强度 0...1（人像区域内的肤色不跟着偏色）
    var greenTarget: SIMD2<Double>?     // 参考图植物的 a*/b*（分区调色）
    var skyTarget: SIMD2<Double>?       // 参考图天空的 a*/b*
    var regionStrength: Double = 0.6
    var hsl: [HSLBand] = []             // 按色相分别调整（内置滤镜用）
    var monochrome = false              // 黑白
    var grainTarget: Double?            // 内置滤镜：目标总颗粒 σ（观看尺度），按当前画面噪点反推要补多少
    var strength: Double = 1            // 整体风格强度（可用 Camera Control 拨动）
}

/// 按色相调整：Lab 色相角 hue（度）附近 ±width 范围内的颜色，色相偏移 dHue、彩度倍率 sat、亮度偏移 dL
struct HSLBand: Equatable {
    var hue: Double
    var width: Double = 35
    var dHue: Double = 0
    var sat: Double = 1
    var dL: Double = 0
}

struct TempTint: Equatable {
    var temperature: Double
    var tint: Double
}

// MARK: - 拍摄计划：要对相机做的全部修改

struct CapturePlan: Equatable {
    var lens: LensChoice = .wide
    var aperture: Float?                // nil = 自动（iOS 27 光圈也能交给 AE）
    var shutter: Double?                // 秒，nil = 自动
    var iso: Float?                     // nil = 自动
    var bias: Float = 0                 // 曝光补偿 EV
    var wbOffset: TempTint?             // 相对自动白平衡的偏移，nil = 自动
    var disabledSignals: Set<AVCaptureDeviceExposureSignal> = []   // iOS 27 曝光信号
    var globalToneMapping = false
    var use48MP = false
    var grading = GradingParams()

    var hasManualExposure: Bool { aperture != nil || shutter != nil || iso != nil }
}

// MARK: - 当前相机状态快照（用于显示“修改前”）

struct DeviceSnapshot {
    var lens: LensChoice
    var aperture: Float
    var shutter: Double
    var iso: Float
    var bias: Float
    var wb: TempTint
    var enabledSignals: Set<AVCaptureDeviceExposureSignal>
    var globalToneMapping: Bool
}

// MARK: - 设备能力

struct HardwareCapabilities {
    var deviceName: String
    var apertureStops: [Float]
    var apertureRange: ClosedRange<Float>
    var isoRange: ClosedRange<Float>
    var shutterRange: ClosedRange<Double>
    var biasRange: ClosedRange<Float>
    var supportedSignals: Set<AVCaptureDeviceExposureSignal>
    var supportsCustomWB: Bool
    var supportsGlobalToneMapping: Bool
    var photoDimensions: [CMVideoDimensions]

    var hasVariableAperture: Bool { apertureRange.upperBound - apertureRange.lowerBound > 0.05 }

    static let empty = HardwareCapabilities(
        deviceName: "—", apertureStops: [], apertureRange: 1.78...1.78,
        isoRange: 50...3200, shutterRange: 0.0001...1, biasRange: -8...8,
        supportedSignals: [], supportsCustomWB: false, supportsGlobalToneMapping: false,
        photoDimensions: [])
}

// MARK: - 参数变更记录（界面上“改了哪些参数”）

struct ParameterChange: Identifiable, Equatable {
    enum Category: String, CaseIterable {
        case optics = "光学等效分析（按全画幅换算）"
        case newFeature = "18 Pro Max / iOS 27 新能力"
        case hardware = "相机硬件参数"
        case grading = "实时调色（软件滤镜）"
    }

    enum Status: Equatable {
        case info
        case planned
        case applied
        case adjusted(String)
        case unsupported(String)
    }

    let id: String
    var category: Category
    var name: String
    var before: String
    var after: String
    var actual: String?
    var reason: String
    var status: Status = .planned
}

// MARK: - 应用结果（回读真实生效值）

struct ApplyReport {
    var actual: [String: String] = [:]
    var exposureStatus: ParameterChange.Status?
    var actualAperture: Float = 0
    var actualShutter: Double = 0
}


// MARK: - 风格版本

enum StyleVariant: String, CaseIterable, Identifiable {
    case faithful = "忠实"
    case soft = "柔和"
    case rich = "浓郁"

    var id: String { rawValue }

    /// 闭环对齐的目标倍率（彩度、色偏）
    var chromaFactor: Double { self == .soft ? 0.92 : (self == .rich ? 1.12 : 1) }
    var castFactor: Double { self == .soft ? 0.6 : (self == .rich ? 1.25 : 1) }

    func apply(_ g: GradingParams) -> GradingParams {
        var o = g
        switch self {
        case .faithful:
            break
        case .soft:
            o.contrast *= 0.6
            o.saturation = 1 + (g.saturation - 1) * 0.6
            o.castA *= 0.6; o.castB *= 0.6
            o.shadowTint *= 0.6; o.highlightTint *= 0.6
            o.vignette *= 0.6; o.grain *= 0.6; o.halation *= 0.6
            o.shadowLift *= 0.8
            o.regionStrength *= 0.6
        case .rich:
            o.contrast = min(1, g.contrast * 1.3 + 0.08)
            o.saturation = g.saturation * 1.15
            o.castA *= 1.25; o.castB *= 1.25
            o.shadowTint *= 1.3; o.highlightTint *= 1.3
            o.vignette = min(1, g.vignette * 1.3 + 0.05)
            o.grain = min(1, g.grain * 1.2)
            o.halation = min(1, g.halation * 1.3)
            o.regionStrength = min(1, g.regionStrength * 1.3)
        }
        return o
    }
}

// MARK: - 构图叠加

enum OverlayMode: String, CaseIterable, Identifiable {
    case off = "关"
    case ghost = "半透明"
    case outline = "轮廓"
    case box = "主体框"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .off: return "square.dashed"
        case .ghost: return "square.on.square"
        case .outline: return "scribble"
        case .box: return "person.crop.rectangle"
        }
    }
}

/// 归一化矩形（左上角原点）按顺时针角度旋转
enum NormRect {
    static func rotate(_ r: CGRect, clockwise deg: Int) -> CGRect {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            switch ((deg % 360) + 360) % 360 {
            case 90: return CGPoint(x: 1 - y, y: x)
            case 180: return CGPoint(x: 1 - x, y: 1 - y)
            case 270: return CGPoint(x: y, y: 1 - x)
            default: return CGPoint(x: x, y: y)
            }
        }
        let a = p(r.minX, r.minY), b = p(r.maxX, r.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Vision（左下角原点）→ 左上角原点
    static func fromVision(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}


// MARK: - 效果开关（排查问题 / 按喜好关闭）

struct EffectToggles: Equatable {
    var bokeh = true        // 计算补足的背景虚化
    var skin = true         // 肤色保护
    var region = true       // 分区调色（植物 / 天空）
    var halation = true     // 高光光晕
    var grain = true        // 颗粒
    var vignette = true     // 暗角
    var grainAmount = 1.0   // 颗粒强度倍率 0…2
    var toneColor = true    // 影调与色彩（曲线、饱和度、色偏、分离色调）

    func apply(_ g: GradingParams) -> GradingParams {
        var o = g
        if !bokeh { o.backgroundBlur = 0 }
        if !skin { o.skinProtect = 0 }
        if !region { o.greenTarget = nil; o.skyTarget = nil }
        if !halation { o.halation = 0 }
        if !grain { o.grain = 0 } else { o.grain = o.grain * grainAmount }
        if !vignette { o.vignette = 0 }
        if !toneColor {
            o.contrast = 0; o.shadowLift = 0; o.highlightRolloff = 0; o.saturation = 1; o.toneCurve = nil
            o.castA = 0; o.castB = 0; o.shadowTint = .zero; o.highlightTint = .zero; o.hsl = []; o.monochrome = false
        }
        return o
    }
}
