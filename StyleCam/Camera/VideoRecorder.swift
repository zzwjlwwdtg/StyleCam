import AVFoundation
import CoreImage

/// 同款风格视频：把“已套滤镜”的取景帧逐帧写入 HEVC 视频，并录制声音。只在 videoQueue 上使用。
final class VideoRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var started = false
    private(set) var startTime: CMTime = .zero

    /// rotationDegrees：视频相对取景帧需要顺时针旋转的角度（横拍时 ±90）
    init?(width w: Int, height h: Int, rotationDegrees: Int, context: CIContext) {
        let w = max(2, w - w % 2), h = max(2, h - h % 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StyleCam-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h
        ])
        v.expectsMediaDataInRealTime = true
        v.transform = CGAffineTransform(rotationAngle: CGFloat(rotationDegrees) * .pi / 180)
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ])
        a.expectsMediaDataInRealTime = true
        guard writer.canAdd(v), writer.canAdd(a) else { return nil }
        writer.add(v)
        writer.add(a)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        self.url = url
        self.writer = writer
        self.videoInput = v
        self.audioInput = a
        self.adaptor = ad
        self.width = w
        self.height = h
        self.context = context
    }

    func appendVideo(_ image: CIImage, time: CMTime) {
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        // 缩放到输出尺寸并移到原点
        let e = image.extent
        let s = min(CGFloat(width) / e.width, CGFloat(height) / e.height)
        let frame = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        context.render(frame, to: pb, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        adaptor.append(pb, withPresentationTime: time)
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard started, writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    func finish(_ completion: @escaping (URL?) -> Void) {
        guard started else { completion(nil); return }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let w = writer, u = url
        w.finishWriting { completion(w.status == .completed ? u : nil) }
    }
}
