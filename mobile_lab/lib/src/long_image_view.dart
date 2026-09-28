import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 长截图查看器。
///
/// 不能用「整张图 contain 进屏幕」那种看法：长图高宽比动辄 1:10，
/// 塞满屏幕后只剩指甲盖大。这里按**宽度铺满**再上下滚动，和相册看长图一致。
class LongImageViewer extends StatelessWidget {
  const LongImageViewer({super.key, required this.png});

  final Uint8List png;

  static Future<void> show(BuildContext context, Uint8List png) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => LongImageViewer(png: png),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('上下滑动看 · 双指放大'),
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          return InteractiveViewer(
            minScale: 1,
            maxScale: 10,
            child: SingleChildScrollView(
              child: Image.memory(
                png,
                width: c.maxWidth,
                fit: BoxFit.fitWidth,
                filterQuality: FilterQuality.medium,
              ),
            ),
          );
        },
      ),
    );
  }
}
