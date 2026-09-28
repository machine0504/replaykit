# replaykit

移动端长截图。分两种：

1. 截本 App：截当前可见区域、框选，或自动滚动后拼成一张长图。
2. 截其它 App：用户自己滑动，系统录屏按帧采集，再按重叠拼成长图。不能替其它 App 滚动。

Android 使用 MediaProjection 和前台服务。iOS 使用 ReplayKit 的 Broadcast Upload Extension。

## 环境

- Flutter 3.10+
- Android minSdk 建议不高于宿主
- iOS 需要能添加 App Extension 的 Xcode 工程

## 接入插件

`mobile_lab` 是 Flutter 插件，只依赖 Flutter。

```yaml
dependencies:
  screenshot_lab_mobile:
    git:
      url: https://github.com/machine0504/replaykit.git
      path: mobile_lab
```

本 App 内的滚动长截图由插件的 Dart API 完成，见 `mobile_lab/lib`。

## 截其它 App

Android：授权投屏后切到目标应用，慢慢下滑。点通知「停止并拼接」。

iOS：

1. 把 `ScreenBroadcast/` 加进宿主 Xcode 工程，类型为 Broadcast Upload Extension。
2. 宿主和扩展使用同一个 App Group。仓库里的占位值是 `group.example.replaykit`，两处都要改成你自己的：
   - `mobile_lab/ios/Classes/ScreenCapturePlugin.swift` 的 `appGroupId()`
   - `ScreenBroadcast/SampleHandler.swift` 的 `appGroupId()`
   - 两边的 entitlements
3. 扩展的 Bundle ID 必须是宿主 Bundle ID 加后缀，例如 `com.example.app.ScreenBroadcast`。
4. 用户在系统录屏面板里选这个扩展，滑完后停止，再回 App 拼接。

插件无法把 iOS 扩展自动装进宿主工程，这一步必须手工做。

## Android 包名

插件 Android 包名是 `com.example.replaykit`。要改的话同时改 `android/build.gradle` 的 `namespace`、Kotlin 的 `package` 和 Manifest 里的 action。
