import SwiftUI

/// 直方图：白色填充 = 当前取景（已套滤镜），黄色描边 = 参考图
struct HistogramView: View {
    var reference: [Double]?
    var live: [Double]

    var body: some View {
        Canvas { ctx, size in
            func path(_ h: [Double]) -> Path {
                var p = Path()
                guard h.count > 1 else { return p }
                let m = max(h.max() ?? 1, 1e-6)
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in h.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(h.count - 1)
                    p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v / m))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.fill(path(live), with: .color(.white.opacity(0.4)))
            if let reference {
                ctx.stroke(path(reference), with: .color(.yellow), lineWidth: 1.2)
            }
        }
        .frame(width: 120, height: 48)
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
