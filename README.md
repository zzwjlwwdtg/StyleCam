# 同款相机 StyleCam（iPhone 18 Pro Max / iOS 27）

上传一张参考图，App 会分析它的风格，然后**同时调整相机硬件参数和实时调色**，让你直接拍出同款。每一项被修改的参数都会列出来，包括修改前的值、修改后的值、传感器回读的实测值和修改原因。

---

## 一、工作流程

```
参考图 ──► 风格分析 ──► 选镜头 ──► 恢复全自动并记录“修改前” ──► 参数规划 ──► 应用到相机 ──► 0.9 秒后回读“实测值”
                                                                         └──► 生成 3D LUT 实时滤镜（预览 = 成片）
```

## 二、用到的 18 Pro Max / iOS 27 新能力

| 新能力 | App 里怎么用 | 对应 API |
|---|---|---|
| **物理可变光圈 f/1.48–f/4**（主摄） | 根据参考图的背景虚化程度选光圈：浅景深用 f/1.48，合影至少 f/2.8，大景深风景用 f/4，夜景有点光源时收到 f/4 拍星芒；参考图是 iPhone 拍的就直接复用 EXIF 光圈 | `setExposureModeCustom(lensAperture:duration:iso:)`、`Format.recommendedLensApertureStops`、`min/maxLensAperture` |
| **光圈/快门/ISO 优先模式** | 锁定光圈（或快门）后，ISO 交给系统自动补偿；如果某个组合不支持，会自动退化到其他组合，并在面板里标成“已调整” | `AVCaptureDevice.autoLensAperture` / `autoExposureDuration` / `autoISO`、`supportsExposureModeCustom(...)` |
| **曝光信号** | 夜景点光源：关闭“星芒抑制”。长曝光：关闭“运动防糊”。浅景深人像：关闭“合影景深”，防止系统擅自收光圈 | `enabledExposureSignals`、`automaticallyEnablesExposureSignals`、`AVCaptureDeviceExposureSignal` |
| **Camera Control 实体键** | 轻按拨动可以调三项：光圈档位（f/1.48 / 1.8 / 2.8 / 4）、风格强度、曝光补偿。按下即拍照 | `AVCaptureIndexPicker`、`AVCaptureSlider`、`AVCaptureSystemExposureBiasSlider`、`onCameraCaptureEvent` |
| **48MP 三摄 + 5 个光学焦段** | 按参考图 EXIF 的等效焦距自动选 0.5x / 1x / 2x / 4x / 8x。清晰的大景深画面自动用 48MP | `builtInUltraWide/WideAngle/TelephotoCamera`、`maxPhotoDimensions` |
| **实时直方图**（18 Pro 新增的专业控制） | 取景框左下角叠加两条曲线：黄线是参考图，白色区域是当前画面，并实时计算“风格匹配度” | 自行计算 |

## 三、风格分析与参数映射

| 从参考图测出的指标 | 改动的参数 | 类别 |
|---|---|---|
| 背景虚化程度（4×4 分块清晰度比） | 光圈 | 硬件 |
| EXIF 快门 ≥ 1/8 秒 | 锁定快门、收光圈（相当于内置 ND）、关闭“运动防糊”信号 | 硬件 |
| 整体亮度 | 曝光补偿（可开启“闭环对齐亮度”持续跟踪） | 硬件 |
| 中性色的 a\*/b\* 偏移 | 白平衡锁定为“自动值 + 偏移”，换场景时每 1.5 秒跟随一次 | 硬件 |
| 影调偏平、有褪色感 | 开启全局色调映射，减弱局部 HDR 感 | 硬件 |
| 亮度标准差 | S 曲线对比度 | 调色 |
| 最暗处 L\* / 最亮处 L\* | 黑位提升 / 高光压缩 | 调色 |
| 平均彩度 | 饱和度 | 调色 |
| 暗部与亮部各自的色偏 | 分离色调 | 调色 |
| 四角与中心的亮度比 | 暗角 | 调色 |
| 平坦区域的高频残差 | 胶片颗粒（用软件模拟，不靠提高 ISO） | 调色 |
| 焦点处锐度 | 锐化 / 柔光 | 调色 |

调色部分全部在 Lab 空间计算，然后烘焙成一个 33³ 的 3D LUT，在 GPU 上实时运行。预览和成片走的是同一条管线。成片保存为 HEIC，并把本次所有参数写进 EXIF 的 UserComment，以后可以查到这张照片是用什么参数拍的。


## 三点五、等效光圈与背景虚化（v2）

手机传感器小，**同样的 f 值，虚化比全画幅弱得多**。App 现在按“入瞳直径”匹配，而不是按 f 值：

| | 实际焦距 | f 值 | 全画幅等效 | 入瞳直径 |
|---|---|---|---|---|
| iPhone 主摄 1x | 6.8mm | f/1.48 – f/4 | 24mm f/5.2 – f/14 | 4.6 – 1.7mm |
| iPhone 4x 长焦 | 16.3mm | f/2.8 | 100mm f/17 | 5.8mm |
| 全画幅 85mm f/1.8 | 85mm | f/1.8 | 85mm f/1.8 | 47mm |

- **参考图分析**：Apple 端侧模型分割主体 → 多尺度离焦估计（Zhuo & Sim 2011）分别测主体/背景的模糊 → 背景弥散圆占画面比例 → 结合人脸尺寸（或 EXIF）推算构图放大率 → 反推参考图的入瞳直径与全画幅等效光圈。
- **iPhone 设置**：入瞳在主摄可调范围内 → 直接算出对应 f 值（连续值）；超过 f/1.48 的物理极限 → 开到最大，剩下的用主体蒙版只模糊背景补足（预览与成片一致），面板会显示光学还原了多少、计算补了多少。
- **景深范围**：有 EXIF 焦距时，按全画幅等效公式（弥散圆 0.03mm）对比参考图与 iPhone 在同样构图下的前后景深。
- 首张照片拍完后，会用照片 EXIF 里的实际焦距自动校准换算表。


## 三点六、同款功能（v4）

| 功能 | 说明 |
|---|---|
| 构图同款 | 顶部“构图”按钮循环：半透明叠加 / 黄色轮廓线 / 主体框。按拍摄方向自动旋转对齐；参考图有人物时实时提示“靠近约 1.2m / 镜头向右转”，对齐后变绿 |
| 水平仪 | 取景中央的水平线，水平时变绿；显示俯仰角 |
| 风格库 | 把参考图存为风格（保存原图含 EXIF + 版本 + 强度）；下次打开自动恢复上次风格 |
| 三种版本 | 忠实 / 柔和 / 浓郁，实时闭环对齐的目标会跟着版本变 |
| 胶片质感 | 高光橙红光晕（halation）；双尺度颗粒，按亮度调制（中间调最明显） |
| 肤色保护 | 人像分割 × 肤色识别，肤色只跟随影调，不跟着整体偏色 |
| 分区调色 | 植物、蓝天分别向参考图里同类颜色的色相/浓度靠拢 |
| 套用相册 | 多选已有照片，按每张照片自身的亮度/彩度/色偏重新自适应后套用，另存新照片 |
| ProRAW | 参数面板里开启后，DNG 底片与调色后的 HEIC 存为同一张照片 |
| 同款视频 | 照片/视频切换；录制已套滤镜的画面（HEVC，含声音，最长边 1920），横拍自动旋转 |

## 四、只有 Windows 电脑：云端编译 + Sideloadly 安装

1. 注册 GitHub 账号，新建一个仓库（选 Private 也可以），把本文件夹里的全部内容上传上去，包括隐藏文件夹 `.github`。
2. 打开仓库的 **Actions** 页面，等待「Build IPA」运行完成，大约 5 到 10 分钟。这一步用的是 GitHub 云端的 Mac（Xcode 27）。
3. 运行成功后，在本次运行页面底部下载 **StyleCam-ipa**，解压后得到 `StyleCam.ipa`。
4. 在 Windows 上安装 **Sideloadly**，以及 **Apple Devices**（或 iTunes），然后用数据线连接 iPhone。
5. 在 Sideloadly 里拖入 `StyleCam.ipa`，填写你的 Apple ID，点 Start。
6. 在 iPhone 上完成两项设置：
   - 设置 → 隐私与安全性 → 打开「开发者模式」，然后重启手机。
   - 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。
7. 免费 Apple ID 签名的 App 7 天后会失效，到时用 Sideloadly 再装一次即可。如果开通了付费开发者账号（每年 99 美元），有效期是 1 年。

如果编译失败，Actions 页面会显示红叉，可以下载 `xcodebuild-log` 查看原因。

## 五、编译安装（有 Mac 的情况）

**方式 A：XcodeGen（推荐）**
```bash
brew install xcodegen
cd StyleCam
xcodegen generate
open StyleCam.xcodeproj
```
在 Xcode 的 Signing 里选你的 Apple ID（免费账号也可以，安装后 7 天内有效）。然后连接 iPhone 18 Pro Max，按 ⌘R 运行。

**方式 B：手动建工程**
1. Xcode → New Project → iOS App，Interface 选 SwiftUI，名字填 StyleCam。
2. 删除自动生成的 `ContentView.swift` 和 `StyleCamApp.swift`，把本项目的 `StyleCam/` 文件夹整个拖进去。
3. 在 Build Settings 里设置：iOS Deployment Target = 27.0，Swift Language Version = Swift 5，Default Actor Isolation = nonisolated。
4. 在 Info 里添加三个权限说明：`NSCameraUsageDescription`、`NSPhotoLibraryAddUsageDescription`、`NSPhotoLibraryUsageDescription`。

需要 Xcode 27（iOS 27 SDK）。光圈和曝光信号这两类 API 只有 iOS 27 才有。

## 六、目录

```
StyleCam/
├── App/          StyleCamApp（入口）、AppModel（流程编排）
├── Models/       StyleProfile、CapturePlan、ParameterChange 等数据结构
├── Style/        StyleAnalyzer（分析）、ParameterPlanner（参数映射）、ColorMath
├── Camera/       CameraManager（会话、iOS 27 曝光、白平衡、Camera Control、拍照）
├── Render/       LUTBuilder（3D LUT）、StyleRenderer（滤镜链）、PhotoProcessor（成片保存）
├── UI/           ContentView、ParameterPanel、CameraPreview（Metal）、HistogramView
└── Support/      Fmt（参数显示格式）
```

## 七、已知限制与调试提示

- **风格识别基于统计规则，不是 AI 模型。** 对常见风格的识别效果较好，比如日系褪色、胶片颗粒、冷暖色调、低调夜景和浅景深人像。复杂的局部调色（只调天空或只调肤色）目前做不到。
- **苹果自带的“摄影风格”第三方无法调用。** 所以所有色调都由 App 自己的 LUT 实现，系统的摄影风格不会叠加进来。
- **白平衡色调的正负方向**（品红 / 绿）是按 Lightroom 的习惯设置的。如果实拍发现色调方向反了，把 `ParameterPlanner` 里 `dTint` 的符号取反即可。
- **iOS 27 早期测试版的问题**：开发者论坛有报告说，`setExposureModeCustom` 在某些情况下被系统静默忽略（目前看到的是前置摄像头）。App 每次修改后都会回读实际值，如果和请求的值不一致，面板里会标成橙色“已调整”。
- **预览画面上下颠倒时**：在 `CameraPreview.swift` 里给 `CIRenderDestination` 加一行 `dest.isFlipped = true` 即可。
- **长快门在预览时会被限制**（为了保持流畅的帧率），只有在拍照时才按设定的完整时长曝光。这是系统行为。
- 我目前的环境没有 Xcode，代码只做过语法检查和色彩算法验证，还没有在真机上编译运行。第一次编译如果报错，把错误信息发给我，我来修。
