import CoreImage
import CoreMedia
import ReplayKit
import UIKit

@objc(SampleHandler)
class SampleHandler: RPBroadcastSampleHandler {
    /// 用户离开本应用之后再等这么久才开始采，用来跳过「划回桌面」那一两帧。
    private let graceAfterLeave: TimeInterval = 1.0
    private let interval: TimeInterval = 0.48
    /// 采集宽度。屏幕物理宽度常见 1170~1290，采 720 等于让用户放大 1.8 倍看，字会糊。
    /// 提到 1080 基本贴近原生；再高的话拼接内存吃不消。
    private let captureWidth: CGFloat = 1080
    private let maxFrames = 30

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastTick = Date.distantPast
    private var leftAppAt: Date?
    private var index = 0
    /// 顶部要裁掉的比例（状态栏 / 灵动岛），由宿主在开始前写进 App Group。
    private var topCropRatio: CGFloat = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        topCropRatio = Self.readTopCropRatio()
        Self.prepareDir()
        index = 0
        lastTick = Date.distantPast
        leftAppAt = nil
        // 宿主不知道系统那 3 秒倒计时什么时候走完，这里落个标记让 App 知道已经在录了。
        try? "started".write(to: Self.startedFile(), atomically: true, encoding: .utf8)
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        try? "ok".write(to: Self.doneFile(), atomically: true, encoding: .utf8)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        // 一个节拍同时用于「查停止标记」和「抓帧」，避免每秒 60 帧都去碰文件系统。
        guard now.timeIntervalSince(lastTick) >= interval else { return }
        lastTick = now

        // App 侧按了「停止并拼接」：系统面板起的录屏没法从宿主进程停，
        // 只能由扩展自己收尾。
        let stopFile = Self.stopFile()
        if FileManager.default.fileExists(atPath: stopFile.path) {
            try? FileManager.default.removeItem(at: stopFile)
            // iOS 只提供 finishBroadcastWithError 让扩展自停，而它一定会弹一个系统提示，
            // 没有静默结束的接口。这里只能把文案写得像正常完成。
            finishBroadcastWithError(NSError(
                domain: "ScreenshotLab",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "截图已完成"]
            ))
            return
        }

        // 只在用户离开本应用期间采集：宿主进入后台时会写 left.txt，回到前台时删掉。
        // 这样不用猜「几秒后开始」，规则就是「切走就开始、切回就暂停」，
        // 也顺便避免把本应用自己的界面拼进长图。
        if FileManager.default.fileExists(atPath: Self.leftFile().path) {
            if leftAppAt == nil { leftAppAt = now }
        } else {
            leftAppAt = nil
            return
        }
        guard let since = leftAppAt, now.timeIntervalSince(since) >= graceAfterLeave else {
            return
        }
        guard index < maxFrames else { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvPixelBuffer: pixel)
        guard let full = ciContext.createCGImage(ci, from: ci.extent) else { return }
        // 状态栏 / 灵动岛那条不随内容滚动：留着不仅会把录屏红点拼进长图，
        // 还会在每帧顶部重复出现、干扰重叠匹配。直接从每帧裁掉。
        guard let cg = Self.cropTop(full, ratio: topCropRatio) else { return }
        let scaled = Self.scale(UIImage(cgImage: cg), maxWidth: captureWidth)
        guard let data = scaled.jpegData(compressionQuality: 0.9) else { return }
        let name = String(format: "%03d.jpg", index)
        index += 1
        try? data.write(to: Self.dir().appendingPathComponent(name), options: .atomic)
    }

    private static func appGroupId() -> String { "group.example.replaykit" }

    private static func dir() -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId())
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sys_frames", isDirectory: true)
    }

    private static func doneFile() -> URL { dir().appendingPathComponent("done.txt") }

    private static func stopFile() -> URL { dir().appendingPathComponent("stop.txt") }

    private static func startedFile() -> URL { dir().appendingPathComponent("started.txt") }

    private static func leftFile() -> URL { dir().appendingPathComponent("left.txt") }

    /// 宿主写在 App Group 根目录（不在 sys_frames 里，那个每次开始会被清空）。
    private static func insetsFile() -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId())
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("top_crop.txt")
    }

    private static func readTopCropRatio() -> CGFloat {
        guard let text = try? String(contentsOf: insetsFile(), encoding: .utf8),
              let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return CGFloat(min(max(v, 0), 0.2))
    }

    private static func cropTop(_ image: CGImage, ratio: CGFloat) -> CGImage? {
        guard ratio > 0 else { return image }
        let cut = (CGFloat(image.height) * ratio).rounded()
        guard cut >= 1, cut < CGFloat(image.height) else { return image }
        return image.cropping(to: CGRect(
            x: 0,
            y: cut,
            width: CGFloat(image.width),
            height: CGFloat(image.height) - cut
        )) ?? image
    }

    private static func prepareDir() {
        let d = dir()
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }

    private static func scale(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let w = image.size.width
        if w <= maxWidth { return image }
        let ratio = maxWidth / w
        let size = CGSize(width: maxWidth, height: (image.size.height * ratio).rounded())
        // 必须显式把 scale 定成 1。默认是屏幕倍率（Plus 机型是 3），
        // 那样「缩到 720 宽」实际会产出 2160 宽的图，像素多 9 倍，拼接也跟着慢 9 倍。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
