import Flutter
import Photos
import ReplayKit
import UIKit

@objc(ScreenCapturePlugin)
public class ScreenCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var poll: Timer?
    private var stopped = false
    private var startedReported = false
    private var sessionRunning = false
    /// 系统录屏选择器。必须留在视图层级里才能被点，故用成员变量持有。
    private var pickerView: RPSystemBroadcastPickerView?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "native_screenshot_lab/system_capture",
            binaryMessenger: registrar.messenger()
        )
        let events = FlutterEventChannel(
            name: "native_screenshot_lab/system_capture_events",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScreenCapturePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        events.setStreamHandler(instance)
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(appActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(appBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)
        case "startSession":
            startBroadcast(result: result)
        case "stopSession":
            requestStop()
            result(true)
        case "saveToAlbum":
            guard let args = call.arguments as? [String: Any],
                  let data = (args["bytes"] as? FlutterStandardTypedData)?.data else {
                result(FlutterError(code: "bad_args", message: "图片数据无效", details: nil))
                return
            }
            Self.saveToAlbum(data, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func saveToAlbum(_ data: Data, result: @escaping FlutterResult) {
        // iOS 14 起才有「仅添加」这种更轻的授权，13 只能要完整相册权限。
        let granted: (PHAuthorizationStatus) -> Bool = { status in
            if #available(iOS 14, *) {
                return status == .authorized || status == .limited
            }
            return status == .authorized
        }
        let handle: (PHAuthorizationStatus) -> Void = { status in
            guard granted(status) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "denied", message: "没有相册写入权限", details: nil))
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, error in
                DispatchQueue.main.async {
                    if ok {
                        result(true)
                    } else {
                        result(FlutterError(
                            code: "save_failed",
                            message: error?.localizedDescription ?? "写入相册失败",
                            details: nil
                        ))
                    }
                }
            }
        }
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: handle)
        } else {
            PHPhotoLibrary.requestAuthorization(handle)
        }
    }

    /// 回到本应用：暂停采集（扩展看到 left.txt 消失就停手），顺便看看录屏是不是已经结束。
    @objc func appActive() {
        if sessionRunning {
            try? FileManager.default.removeItem(at: Self.leftFile())
        }
        checkDone()
    }

    /// 离开本应用：告诉扩展可以开始采了。
    @objc func appBackground() {
        guard sessionRunning else { return }
        try? "left".write(to: Self.leftFile(), atomically: true, encoding: .utf8)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    /// 弹系统录屏面板。
    ///
    /// 不能用 `RPBroadcastActivityViewController`：它只列「直播服务」，要求应用另带一个
    /// Broadcast Setup UI 扩展，否则面板是空的，系统会把用户引去 App Store 找直播 App。
    /// `RPSystemBroadcastPickerView` 可以用 `preferredExtension` 直接锁定本应用的上传扩展。
    private func startBroadcast(result: @escaping FlutterResult) {
        stopped = false
        startedReported = false
        sessionRunning = true
        Self.clearFrames()
        Self.writeTopCropRatio()
        guard let host = Self.topController()?.view else {
            result(FlutterError(code: "no_vc", message: "没有可弹出的页面", details: nil))
            return
        }
        // 摆到屏幕外：既不挡用户点击，按钮又还在视图层级里，能收到 sendActions。
        let picker = pickerView ?? RPSystemBroadcastPickerView(
            frame: CGRect(x: -200, y: -200, width: 44, height: 44)
        )
        picker.preferredExtension = Self.broadcastExtensionId()
        picker.showsMicrophoneButton = false
        if picker.superview == nil {
            host.addSubview(picker)
        }
        pickerView = picker

        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            result(FlutterError(code: "no_picker", message: "系统录屏面板不可用", details: nil))
            return
        }
        button.sendActions(for: .touchUpInside)
        result(true)
        startPolling()
    }

    /// 上传扩展的 bundle id 约定为「宿主 id + .ScreenBroadcast」。
    static func broadcastExtensionId() -> String {
        let host = Bundle.main.bundleIdentifier ?? ""
        return "\(host).ScreenBroadcast"
    }

    /// 系统面板起的录屏，宿主进程停不掉，只能在 App Group 里放个停止标记，
    /// 由扩展自己 `finishBroadcastWithError` 收尾并写 done.txt。
    private func requestStop() {
        if FileManager.default.fileExists(atPath: Self.doneFile().path) {
            emitStopped()
            return
        }
        try? "stop".write(to: Self.stopFile(), atomically: true, encoding: .utf8)
        startPolling()
        // 扩展可能已经被系统回收，等不到 done.txt 就拿现有的帧兜底。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.emitStopped()
        }
    }

    private func startPolling() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.checkDone()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func checkDone() {
        // 系统那 3 秒倒计时走完、扩展真正跑起来时才会有 started.txt。
        if !startedReported,
           FileManager.default.fileExists(atPath: Self.startedFile().path) {
            startedReported = true
            // 采集时机由「是否离开本应用」决定，没有固定等待时间。
            sink?(["type": "started", "warmUpMs": 0])
        }
        let count = Self.framePaths().count
        if count > 0 {
            sink?(["type": "frame", "count": count])
        }
        if FileManager.default.fileExists(atPath: Self.doneFile().path) {
            poll?.invalidate()
            poll = nil
            emitStopped()
        }
    }

    private func emitStopped() {
        if stopped { return }
        stopped = true
        sessionRunning = false
        poll?.invalidate()
        poll = nil
        sink?(["type": "stopped", "paths": Self.framePaths()])
    }

    static func appGroupId() -> String { "group.example.replaykit" }

    static func groupDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId())
    }

    static func framesDir() -> URL? {
        groupDir()?.appendingPathComponent("sys_frames", isDirectory: true)
    }

    static func doneFile() -> URL {
        (framesDir() ?? FileManager.default.temporaryDirectory).appendingPathComponent("done.txt")
    }

    static func stopFile() -> URL {
        (framesDir() ?? FileManager.default.temporaryDirectory).appendingPathComponent("stop.txt")
    }

    static func startedFile() -> URL {
        (framesDir() ?? FileManager.default.temporaryDirectory).appendingPathComponent("started.txt")
    }

    static func leftFile() -> URL {
        (framesDir() ?? FileManager.default.temporaryDirectory).appendingPathComponent("left.txt")
    }

    static func framePaths() -> [String] {
        guard let dir = framesDir() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.path)
    }

    /// 告诉扩展每帧顶部要裁掉多少（状态栏 / 灵动岛占屏幕高度的比例）。
    ///
    /// 扩展拿不到界面信息，只能由宿主算好写进 App Group。写在根目录，
    /// 因为 sys_frames 每次开始录都会被清空。
    static func writeTopCropRatio() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        let top = window?.safeAreaInsets.top ?? 0
        let height = window?.bounds.height ?? UIScreen.main.bounds.height
        guard height > 0, top > 0 else { return }
        let ratio = min(top / height, 0.2)
        guard let base = groupDir() else { return }
        try? "\(ratio)".write(
            to: base.appendingPathComponent("top_crop.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func clearFrames() {
        guard let dir = framesDir() else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func topController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
