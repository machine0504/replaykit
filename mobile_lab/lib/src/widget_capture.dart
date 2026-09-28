import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 把 [RepaintBoundary] 画成位图 / PNG。
class WidgetCapture {
  WidgetCapture._();

  static RenderRepaintBoundary _boundary(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) {
      throw StateError('截图目标未挂载');
    }
    final obj = ctx.findRenderObject();
    if (obj is! RenderRepaintBoundary) {
      throw StateError('请用 RepaintBoundary 包住要截的内容');
    }
    return obj;
  }

  static double pixelRatioOf(GlobalKey key, {double? override, double cap = 3}) {
    if (override != null) return override;
    final ctx = key.currentContext;
    final dpr = ctx == null ? 2.0 : MediaQuery.of(ctx).devicePixelRatio;
    return dpr.clamp(1.0, cap);
  }

  static Future<ui.Image> toImage(
    GlobalKey key, {
    double? pixelRatio,
    double cap = 3,
  }) {
    final boundary = _boundary(key);
    final dpr = pixelRatioOf(key, override: pixelRatio, cap: cap);
    return boundary.toImage(pixelRatio: dpr);
  }

  static Future<Uint8List> pngOf(ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('PNG 编码失败');
    }
    return bytes.buffer.asUint8List();
  }

  static Future<Uint8List> capturePng(
    GlobalKey key, {
    double? pixelRatio,
    double cap = 3,
  }) async {
    final image = await toImage(key, pixelRatio: pixelRatio, cap: cap);
    try {
      return await pngOf(image);
    } finally {
      image.dispose();
    }
  }
}
