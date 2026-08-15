# GuidedCapture

从零食柜（SnackCabinet）抽离的通用「引导拍摄 → 主体抠图 → 贴纸化」iOS 组件，一条链路上完成：

```
取景框引导拍摄 / 从相册选择 → 区域裁切 → Vision 主体抠图 → 透明贴纸 + 白描边
```

完全在设备本地运行，不上传图片，不产生 AI API 调用费用。

## 为什么会有这个组件

零食柜用这套交互把食物拍成"贴纸"放进虚拟零食柜：取景框提示用户把主体放进去，拍下后 Vision 自动把主体从背景抠出，再沿轮廓描一层白边做成贴纸。这套能力与业务（食品、柜子、保质期）无关，被拆成独立 Swift Package 以便任何 iOS App 复用。

## 能力范围

- 全屏 AVFoundation 相机，`resizeAspectFill` 预览与成片裁切完全一致，画面不跳
- 可视化取景框 + 拍照快门 + 相册选择（PHPicker，无需相册权限）+ 关闭
- 基于取景框的安全裁切：主体可超出取景框但仍被完整保留
- Vision 前景实例分割（`VNGenerateForegroundInstanceMaskRequest`）
  - 支持 `seedRegion`：取景框作为主体选择的种子，避免合并框外其他物体
  - 主体实例分割失败时自动降级到注意力显著区域
- 透明背景抠图 + 8-bit 灰度遮罩双输出
- 贴纸后处理：透明边距裁剪、Moore 边界轮廓提取（描边动画用）、白色描边、降采样
- 一键流程 `CutoutFlow`：`CameraCapture → 抠图 → 贴纸`，失败自动回退原图

## 系统要求

- iOS 17.0+（`VNGenerateForegroundInstanceMaskRequest` 需要 iOS 17）
- Swift 5.9+

## 安装

通过 Swift Package Manager 添加：

```
https://github.com/xiaohao7023/GuidedCapture.git
```

Xcode 菜单 `File → Add Package Dependencies…` 粘贴上面的 URL，选择版本后即可。

## 快速接入

### 最简用法（一屏搞定）

```swift
import GuidedCapture
import SwiftUI

struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow = CutoutFlow()
    @State private var sticker: CutoutFlow.StickerResult?

    var body: some View {
        ZStack {
            if let sticker {
                // 展示透明贴纸 / 白描边贴纸
                Image(uiImage: sticker.outlined)
                    .resizable()
                    .scaledToFit()
            } else {
                GuidedCaptureView(
                    onCapture: { capture in
                        Task {
                            sticker = try? await flow.process(capture)
                        }
                    },
                    onCancel: { dismiss() }
                )
                .ignoresSafeArea()
            }
        }
    }
}
```

### 分步使用（需要更多控制时）

先只拿相机与裁切：

```swift
GuidedCaptureView(
    onCapture: { capture in
        // capture.previewImage   完整直立照片（过渡动画用）
        // capture.subjectImage   以取景框为中心的搜索裁切
        // capture.subjectRegion  归一化安全裁切区域
        // capture.subjectSeedRegion  取景框在搜索图上的归一化区域
    },
    onCancel: { dismiss() }
)
```

再单独跑抠图：

```swift
let cutout = SubjectCutout()
let result = try await cutout.process(image, seedRegion: capture.subjectSeedRegion)
let transparentImage = result.image  // 透明背景 PNG
let maskData = result.mask           // 8-bit 灰度遮罩
```

最后做贴纸化：

```swift
let cropped = StickerRenderer.cropToAlphaBounds(transparentImage)
let outlined = StickerRenderer.whiteOutlined(cropped)
let contour = StickerRenderer.alphaOutline(cgImage: cropped.cgImage)  // 描边动画
let small = StickerRenderer.downsampleIfNeeded(outlined, maxDimension: 640) // 保存用
```

## 模块结构

| 文件 | 职责 |
| --- | --- |
| `Camera/GuidedCaptureView.swift` | SwiftUI 入口（相机 + 取景框 + 快门 + 相册） |
| `Camera/CameraViewController.swift` | AVFoundation 相机、拍照/相册、安全裁切计算 |
| `Camera/CameraOverlayView.swift` | 取景框 UI（Auto Layout 自适应） |
| `Camera/CameraCapture.swift` | 拍摄结果模型 |
| `ImageTools/UIImage+CaptureGeometry.swift` | 方向归一化、归一化区域裁切 |
| `ImageTools/CGRect+CaptureGeometry.swift` | 区域扩张、区域换算 |
| `Cutout/SubjectCutout.swift` | Vision 主体抠图（含显著区域降级） |
| `Sticker/StickerRenderer.swift` | 贴纸后处理（裁剪/轮廓/白边/降采样） |
| `Flow/CutoutFlow.swift` | 一键流程：拍摄结果 → 抠图 → 贴纸 |

## 可调参数

`SubjectCutout.Configuration`：

```swift
let configuration = SubjectCutout.Configuration()
configuration.foregroundTimeout = 0.9      // 主体分割最长等待
configuration.fallbackTimeout = 0.35       // 显著区域降级最长等待
configuration.visionMaxDimension = 960     // Vision 工作图最长边
configuration.edgeExpansion = 1.5          // 遮罩外扩，减少主体边缘被切
configuration.edgeSoftness = 0.8           // 遮罩羽化，避免生硬锯齿

let cutout = SubjectCutout(configuration: configuration)
```

`GuidedCaptureView.Strings`：

```swift
GuidedCaptureView(
    onCapture: onCapture,
    onCancel: onCancel,
    strings: .init(
        guideTip: "把主体放入框内",
        libraryAccessibility: "从相册选择"
    )
)
```

## 业务边界

组件负责"拍摄 → 主体抠图 → 贴纸化"这一段，不包含：

- 业务实体建模（食品、商品、人物分类）
- 图片持久化 / 存储层
- 结果页 UI 与动画（`CutoutFlow.StickerResult.outlinePoints` 正是为这类动画准备的轮廓数据）
- 网络上传
- 相机权限文案定制（可在 App 的 Info.plist 配置 `NSCameraUsageDescription`）

## 推荐失败处理

- 未识别到主体：让用户重新拍摄，提示保持单一主体和清晰背景
- 处理超时：允许重试，不阻塞主界面
- 业务必须继续时：`CutoutFlow` 已自动回退原图；单独使用 `SubjectCutout` 时由上层决定是否保留原图

## License

MIT
