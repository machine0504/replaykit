import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'widget_capture.dart';

class _Frame {
  _Frame({
    required this.offset,
    required this.viewport,
    required this.image,
    required this.pixelRatio,
  });

  final double offset;
  final double viewport;
  final ui.Image image;
  final double pixelRatio;
}

/// 滚动 [controller] 对应列表，按帧截取后纵向拼成一张长图。
///
/// 只能截本 App 里包了 [RepaintBoundary] 的 Flutter 内容，不能截其它 App。
class LongScreenshot {
  LongScreenshot._();

  static Future<Uint8List> capture({
    required GlobalKey boundaryKey,
    required ScrollController controller,
    double overlap = 32,
    double? pixelRatio,
    int maxHeightPx = 16384,
    int maxFrames = 80,
    bool fromTop = true,
    double? startOffset,
    double? endOffset,
    void Function(int current, int total)? onProgress,
  }) async {
    if (!controller.hasClients) {
      throw StateError('列表尚未可滚动');
    }
    final pos = controller.position;
    final view = pos.viewportDimension;
    if (view <= 0) {
      throw StateError('列表高度无效');
    }
    final max = pos.maxScrollExtent;
    final saved = pos.pixels;
    final dpr = WidgetCapture.pixelRatioOf(
      boundaryKey,
      override: pixelRatio,
      cap: 2,
    );
    final step = math.max(view - overlap, 1.0);
    final contentBottom = max + view;
    final captureStart =
        (startOffset ?? (fromTop ? 0.0 : saved)).clamp(0.0, max);
    final captureEnd = (endOffset ?? contentBottom)
        .clamp(captureStart + 1, contentBottom);
    final distance = math.max(captureEnd - captureStart, 0.0);
    final estimated = distance <= view + 0.5 ? 1 : (distance / step).ceil();

    final frames = <_Frame>[];
    try {
      var offset = captureStart;
      controller.jumpTo(offset);
      await _settle();
      for (var i = 0; i < maxFrames; i++) {
        onProgress?.call(i + 1, estimated);
        final image = await WidgetCapture.toImage(
          boundaryKey,
          pixelRatio: dpr,
          cap: 2,
        );
        frames.add(_Frame(
          offset: controller.offset,
          viewport: view,
          image: image,
          pixelRatio: dpr,
        ));
        if (controller.offset + view >= captureEnd - 0.5) break;
        final lastStart = math.max(0.0, captureEnd - view);
        final next = math.min(lastStart, offset + step);
        if (next <= offset + 0.5) {
          if (controller.offset + 0.5 < lastStart.clamp(0.0, max)) {
            offset = lastStart.clamp(0.0, max);
            controller.jumpTo(offset);
            await _settle();
            continue;
          }
          break;
        }
        offset = next.clamp(0.0, max);
        controller.jumpTo(offset);
        await _settle();
      }
      final stitched = await _stitch(frames, maxHeightPx, captureEnd: captureEnd);
      try {
        return await WidgetCapture.pngOf(stitched);
      } finally {
        stitched.dispose();
      }
    } finally {
      for (final f in frames) {
        f.image.dispose();
      }
      if (controller.hasClients) {
        controller.jumpTo(saved.clamp(0.0, max));
      }
    }
  }

  /// 等列表把新位置的格子画出来再截。只等一帧时，后面的格子还是空白，会拼进长图。
  static Future<void> _settle() async {
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 48));
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;
  }

  static Future<ui.Image> _stitch(
    List<_Frame> frames,
    int maxHeightPx, {
    double? captureEnd,
  }) async {
    if (frames.isEmpty) {
      throw StateError('没有截到任何一帧');
    }
    final width = frames.first.image.width;
    final skips = <int>[0];
    var total = frames.first.image.height;
    for (var i = 1; i < frames.length; i++) {
      final prev = frames[i - 1];
      final cur = frames[i];
      final overlapPx = ((prev.offset + prev.viewport - cur.offset) *
              cur.pixelRatio)
          .round()
          .clamp(0, cur.image.height);
      skips.add(overlapPx);
      total += cur.image.height - overlapPx;
    }
    final outH = total.clamp(1, maxHeightPx);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    var y = 0.0;
    for (var i = 0; i < frames.length; i++) {
      if (y >= outH) break;
      final img = frames[i].image;
      final skip = skips[i].toDouble();
      var srcH = img.height - skip;
      if (i == frames.length - 1 && captureEnd != null) {
        final keep = (captureEnd - frames[i].offset) * frames[i].pixelRatio - skip;
        srcH = math.min(srcH, keep);
      }
      if (srcH <= 0) continue;
      final destH = math.min(srcH, outH - y);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, skip, img.width.toDouble(), destH),
        Rect.fromLTWH(0, y, width.toDouble(), destH),
        Paint()..filterQuality = FilterQuality.none,
      );
      y += destH;
    }
    final picture = recorder.endRecording();
    return picture.toImage(width, math.max(1, y.round()));
  }
}
