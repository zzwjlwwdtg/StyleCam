import SwiftUI

/// 构图同款：把参考图（半透明 / 线稿 / 主体框）叠在取景画面上，并按拍摄方向旋转对齐；附带水平仪和站位提示
struct CompositionOverlay: View {
    let reference: UIImage?
    let outline: UIImage?
    let mode: OverlayMode
    let opacity: Double
    let faceRect: CGRect?
    let subjectRect: CGRect?
    /// 取景画面的宽高比（竖屏取景帧，已按画幅裁切）
    let previewAspect: CGFloat
    /// 照片相对传感器的旋转角（90 = 竖拍，0/180 = 横拍）
    let captureAngle: CGFloat
    let roll: Double
    let pitch: Double
    let isLevel: Bool
    let hint: String?
    let aligned: Bool

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fitRect(aspect: previewAspect, in: geo.size)
            // 照片 = 取景帧顺时针旋转 (angle − 90)°，所以叠加内容要反向旋转回去
            let rot = Int((((90 - Double(captureAngle)).truncatingRemainder(dividingBy: 360)) + 360)
                .truncatingRemainder(dividingBy: 360))
            let swapped = rot == 90 || rot == 270
            let cw = swapped ? fit.height : fit.width
            let ch = swapped ? fit.width : fit.height

            ZStack {
                if mode != .off {
                    overlayContent(width: cw, height: ch)
                        .frame(width: cw, height: ch)
                        .clipped()
                        .rotationEffect(.degrees(Double(rot)))
                        .position(x: fit.midX, y: fit.midY)
                        .allowsHitTesting(false)
                }

                levelLine(fit: fit, landscape: swapped)
                    .allowsHitTesting(false)

                if let hint {
                    Text(hint)
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background((aligned ? Color.green : Color.black).opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .position(x: fit.midX, y: fit.maxY - 82)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayContent(width w: CGFloat, height h: CGFloat) -> some View {
        switch mode {
        case .off:
            EmptyView()
        case .ghost:
            if let reference {
                Image(uiImage: reference).resizable().scaledToFill()
                    .frame(width: w, height: h)
                    .opacity(opacity)
            }
        case .outline:
            ZStack {
                if let outline {
                    Image(uiImage: outline).resizable().scaledToFill()
                        .frame(width: w, height: h)
                        .opacity(0.9)
                }
                boxes(width: w, height: h, faint: true)
            }
        case .box:
            boxes(width: w, height: h, faint: false)
        }
    }

    private func boxes(width w: CGFloat, height h: CGFloat, faint: Bool) -> some View {
        ZStack {
            if let r = subjectRect {
                Rectangle()
                    .stroke(Color.yellow.opacity(faint ? 0.5 : 0.95), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .frame(width: r.width * w, height: r.height * h)
                    .position(x: r.midX * w, y: r.midY * h)
            }
            if let f = faceRect {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(faint ? 0.6 : 0.95), lineWidth: 1.5)
                    .frame(width: f.width * w, height: f.height * h)
                    .position(x: f.midX * w, y: f.midY * h)
            }
        }
        .frame(width: w, height: h)
    }

    /// 水平仪：始终与真实地平线平行的一条线；水平时变绿
    private func levelLine(fit: CGRect, landscape: Bool) -> some View {
        let color: Color = isLevel ? .green : .white
        let len = min(fit.width, fit.height) * 0.35
        return ZStack {
            HStack(spacing: 6) {
                Rectangle().fill(color).frame(width: len, height: 1.5)
                Circle().stroke(color, lineWidth: 1.5).frame(width: 10, height: 10)
                Rectangle().fill(color).frame(width: len, height: 1.5)
            }
            .rotationEffect(.degrees((landscape ? 90 : 0) + roll))
            .opacity(abs(roll) < 12 ? 0.85 : 0)

            if abs(pitch) > 3 && abs(pitch) < 45 {
                Text(String(format: "俯仰 %+.0f°", pitch))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .offset(y: 18)
            }
        }
        .position(x: fit.midX, y: fit.midY)
    }

    static func fitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// 竖屏取景帧（3:4）按画幅裁切后的宽高比
    static func previewAspect(cropRatio: Double?) -> CGFloat {
        guard let r = cropRatio, r > 1 else { return 3.0 / 4.0 }
        return CGFloat(1 / r)
    }
}
