import SwiftUI
import MetalKit
import CoreImage

/// Metal 取景器：每帧把（已套滤镜的）CIImage 直接渲染到屏幕，60fps 实时预览
struct CameraPreview: UIViewRepresentable {
    let frameStore: FrameStore
    var showOriginal: Bool

    func makeCoordinator() -> Coordinator { Coordinator(frameStore: frameStore) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.backgroundColor = .black
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.showOriginal = showOriginal
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice? = MTLCreateSystemDefaultDevice()
        private lazy var queue = device?.makeCommandQueue()
        private lazy var ciContext: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        private let frameStore: FrameStore
        private let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        var showOriginal = false

        init(frameStore: FrameStore) { self.frameStore = frameStore }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let image = frameStore.latest(original: showOriginal),
                  let drawable = view.currentDrawable,
                  let cb = queue?.makeCommandBuffer(),
                  let ctx = ciContext else { return }

            let size = view.drawableSize
            let ext = image.extent
            guard ext.width > 0, ext.height > 0, size.width > 0 else { return }

            // 等比完整显示（按参考图裁切画幅时会留黑边）
            let s = min(size.width / ext.width, size.height / ext.height)
            var img = image
                .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
            img = img.transformed(by: CGAffineTransform(translationX: (size.width - img.extent.width) / 2,
                                                        y: (size.height - img.extent.height) / 2))

            img = img.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
            let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                           pixelFormat: view.colorPixelFormat, commandBuffer: cb) { drawable.texture }
            dest.colorSpace = displayColorSpace
            _ = try? ctx.startTask(toRender: img, to: dest)
            cb.present(drawable)
            cb.commit()
        }
    }
}
