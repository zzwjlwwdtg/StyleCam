import Foundation

/// PTP（ISO 15740）容器的打包 / 解析，以及索尼扩展指令常量。
/// 索尼的指令和流程参考 libgphoto2（camlibs/ptp2）对 Sony Alpha “PC 遥控”模式的实现。
enum PTP {
    // 标准操作码
    static let getDeviceInfo: UInt16 = 0x1001
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    // 标准响应码
    static let ok: UInt16 = 0x2001
    static let generalError: UInt16 = 0x2002
    static let invalidObjectHandle: UInt16 = 0x2009
    static let accessDenied: UInt16 = 0x200F
    static let deviceBusy: UInt16 = 0x2019
    // 标准事件
    static let evObjectAdded: UInt16 = 0x4002

    // 索尼扩展（SDIO）
    enum Sony {
        static let connect: UInt16 = 0x9201              // SDIO_Connect，分 1 / 2 / 3 三个阶段
        static let getExtDeviceInfo: UInt16 = 0x9202     // 取得扩展属性列表（协议版本 0x12C = 3.00）
        static let setExtDevicePropValue: UInt16 = 0x9205
        static let controlDevice: UInt16 = 0x9207         // 按钮类控制（快门半按 / 全按）
        static let protocol300: UInt32 = 0x12C

        static let propPriorityMode: UInt16 = 0xD25A      // 1 = 由电脑 / 手机端控制
        static let propShutterHalf: UInt16 = 0xD2C1       // 半按（2 = 按下，1 = 松开）
        static let propShutterFull: UInt16 = 0xD2C2       // 全按

        static let evObjectAdded: UInt16 = 0xC201         // 拍完一张：参数 1 是对象句柄
        static let evPropChanged: UInt16 = 0xC203

        static let liveViewHandle: UInt32 = 0xFFFF_C002   // 实时取景画面
        static let shotHandle: UInt32 = 0xFFFF_C001       // 刚拍的照片（在相机内存里）
    }

    // MARK: - 打包

    /// 操作请求容器：长度 u32 | 类型 u16 = 1 | 操作码 u16 | 事务号 u32 | 参数 u32…（小端）
    static func command(_ code: UInt16, _ params: [UInt32] = []) -> Data {
        var d = Data()
        d.appendLE(UInt32(12 + 4 * params.count))
        d.appendLE(UInt16(1))
        d.appendLE(code)
        d.appendLE(UInt32(0))          // 事务号由系统重新分配
        for p in params { d.appendLE(p) }
        return d
    }

    static func u16(_ v: UInt16) -> Data { var d = Data(); d.appendLE(v); return d }
    static func u8(_ v: UInt8) -> Data { Data([v]) }

    // MARK: - 解析

    struct Container {
        let type: UInt16
        let code: UInt16
        let params: [UInt32]
    }

    /// 解析响应 / 事件容器
    static func container(_ d: Data) -> Container? {
        guard d.count >= 8 else { return nil }
        let len = Int(d.le32(0))
        let type = d.le16(4)
        let code = d.le16(6)
        var params: [UInt32] = []
        var o = 12
        while o + 4 <= min(d.count, max(len, 12)) {
            params.append(d.le32(o)); o += 4
        }
        return Container(type: type, code: code, params: params)
    }

    /// ObjectInfo 里我们关心的几个字段
    struct ObjectInfo {
        let format: UInt16
        let size: UInt32
        let filename: String
    }

    static func objectInfo(_ d: Data) -> ObjectInfo? {
        guard d.count >= 53 else { return nil }
        let format = d.le16(4)
        let size = d.le32(8)
        var name = ""
        let n = Int(d.byte(52))
        if n > 0, d.count >= 53 + n * 2 {
            var units: [UInt16] = []
            for i in 0..<n { units.append(d.le16(53 + i * 2)) }
            name = String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
        }
        return ObjectInfo(format: format, size: size, filename: name)
    }

    /// 索尼实时取景数据：开头 4 字节是 JPEG 的偏移；找不到时退回搜索 FFD8
    static func liveViewJPEG(_ d: Data) -> Data? {
        guard d.count > 8 else { return nil }
        let off = Int(d.le32(0))
        if off + 1 < d.count, d.byte(off) == 0xFF, d.byte(off + 1) == 0xD8 {
            return d.subdata(in: d.startIndex + off ..< d.endIndex)
        }
        for i in 0..<min(d.count - 1, 4096) where d.byte(i) == 0xFF && d.byte(i + 1) == 0xD8 {
            return d.subdata(in: d.startIndex + i ..< d.endIndex)
        }
        return nil
    }

    static func hex(_ code: UInt16) -> String { String(format: "0x%04X", code) }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    func byte(_ o: Int) -> UInt8 { self[startIndex + o] }
    func le16(_ o: Int) -> UInt16 { UInt16(byte(o)) | UInt16(byte(o + 1)) << 8 }
    func le32(_ o: Int) -> UInt32 {
        UInt32(byte(o)) | UInt32(byte(o + 1)) << 8 | UInt32(byte(o + 2)) << 16 | UInt32(byte(o + 3)) << 24
    }
}
