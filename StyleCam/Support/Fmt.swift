import Foundation
import AVFoundation

/// 参数显示格式
enum Fmt {
    static func ap(_ f: Float) -> String {
        let v = Double(f)
        guard v > 0 else { return "—" }
        let oneDecimal = abs(v * 10 - (v * 10).rounded()) < 0.01
        return "f/" + String(format: oneDecimal ? "%.1f" : "%.2f", v)
    }

    static func shutter(_ s: Double) -> String {
        guard s > 0, s.isFinite else { return "—" }
        if s >= 0.3 { return String(format: "%.1fs", s) }
        return "1/\(Int((1 / s).rounded()))"
    }

    static func ev(_ e: Float) -> String { String(format: "%+.1f EV", e) }

    static func signed(_ v: Double, _ digits: Int = 0) -> String {
        String(format: "%+.\(digits)f", v)
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func kelvin(_ k: Double) -> String { "\(Int((k / 50).rounded() * 50))K" }

    static func wb(_ t: TempTint) -> String { "\(kelvin(t.temperature)) / 色调 \(signed(t.tint))" }

    static func signalName(_ s: AVCaptureDeviceExposureSignal) -> String {
        switch s {
        case .document: return "文档清晰"
        case .flicker: return "防频闪"
        case .groupPhoto: return "合影景深"
        case .starburst: return "星芒抑制"
        case .subjectMotion: return "运动防糊"
        default: return s.rawValue
        }
    }

    static func signals(_ set: Set<AVCaptureDeviceExposureSignal>) -> String {
        set.isEmpty ? "无" : set.map(signalName).sorted().joined(separator: "、")
    }

    static func tint(_ t: SIMD2<Double>) -> String {
        let mag = (t.x * t.x + t.y * t.y).squareRoot()
        guard mag > 0.5 else { return "无" }
        return "\(ColorMath.hueName(a: t.x, b: t.y)) \(String(format: "%.0f", mag))"
    }
}
