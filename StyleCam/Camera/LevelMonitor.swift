import Foundation
import CoreMotion
import Combine

/// 水平仪：用重力方向算出手机相对水平的倾斜（自动识别竖拍/横拍）与俯仰角
/// 更新在主队列上发布（CMMotionManager 的回调队列设为 .main）
final class LevelMonitor: ObservableObject, @unchecked Sendable {
    @Published var roll: Double = 0       // 偏离水平的角度（度），已按最近的 90° 方向归零
    @Published var pitch: Double = 0      // 俯仰（度），正数 = 镜头朝上
    @Published var isLevel = false

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            let angle = atan2(g.x, g.y) * 180 / .pi
            var dev = angle.truncatingRemainder(dividingBy: 90)
            if dev > 45 { dev -= 90 }
            if dev < -45 { dev += 90 }
            self.roll = dev
            self.pitch = asin(max(-1, min(1, g.z))) * 180 / .pi
            self.isLevel = abs(dev) < 1
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}
