import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'frame_stitcher.dart';
import 'platforms.dart';

/// 其它 App 长截图：授权后采当前屏幕，用户自己滑，停下来再按重叠拼接。
///
/// 本进程无法替微信 / Safari 滚动。Android = MediaProjection；iOS = 录屏扩展。
class OtherAppLongCapture {
  OtherAppLongCapture._();

  static const _methods = MethodChannel('native_screenshot_lab/system_capture');
  static const _events = EventChannel('native_screenshot_lab/system_capture_events');

  static Future<bool> isAvailable() async {
    if (!labIsMobile) return false;
    try {
      return await _methods.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _methods.invokeMethod('stopSession');
    } on MissingPluginException {
      // ignore
    }
  }

  /// 弹出系统授权 → 用户切到其它 App 自己滑 → 停止后返回拼接 PNG。取消为 `null`。
  ///
  /// [onStarted] 在录屏真正开始时回调，参数是「准备时间」毫秒数：这段时间内拍到的
  /// 画面会被丢掉，留给用户切到目标 App。调用方可以据此显示倒计时。
  static Future<Uint8List?> capture({
    void Function(int warmUpMs)? onStarted,
    void Function(int frameCount)? onFrame,
    void Function(int current, int total)? onStitchProgress,
    void Function(String reason)? onError,
    int maxHeightPx = 16384,
  }) async {
    if (!await isAvailable()) {
      onError?.call('当前平台不能截其它 App');
      return null;
    }
    final done = Completer<List<String>>();
    StreamSubscription<dynamic>? sub;
    sub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final map = Map<Object?, Object?>.from(event);
        final type = map['type']?.toString();
        if (type == 'started') {
          onStarted?.call((map['warmUpMs'] as num?)?.toInt() ?? 0);
        } else if (type == 'frame') {
          final count = (map['count'] as num?)?.toInt() ?? 0;
          onFrame?.call(count);
        } else if (type == 'stopped' && !done.isCompleted) {
          final raw = map['paths'];
          final paths = raw is List
              ? raw.map((e) => e.toString()).where((s) => s.isNotEmpty).toList()
              : <String>[];
          done.complete(paths);
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );
    try {
      final started = await _methods.invokeMethod<bool>('startSession') ?? false;
      if (!started) {
        return null;
      }
      final paths = await done.future.timeout(
        const Duration(minutes: 10),
        onTimeout: () => <String>[],
      );
      if (paths.isEmpty) {
        return null;
      }
      return await FrameStitcher.stitchFiles(
        paths,
        maxHeightPx: maxHeightPx,
        onProgress: onStitchProgress,
      );
    } on TimeoutException {
      onError?.call('采集超时');
      await stop();
      return null;
    } catch (e) {
      debugPrint('[native_screenshot_lab] other-app capture failed: $e');
      onError?.call('$e');
      return null;
    } finally {
      await sub.cancel();
    }
  }
}
