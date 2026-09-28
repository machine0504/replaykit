import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'widget_capture.dart';

enum _Tool { zoom, mosaic }

/// 截图后的简单编辑：缩放浏览 + 打码。确认后返回新的 PNG。
///
/// 画布按**宽度铺满**摆放（长图专用），再用 [InteractiveViewer] 缩放平移。
/// 手势只在「浏览」模式下交给 InteractiveViewer，打码时锁住画布，
/// 单指拖动才不会一边涂一边把图拖跑。
class ImageEditorPage extends StatefulWidget {
  const ImageEditorPage({super.key, required this.png});

  final Uint8List png;

  static Future<Uint8List?> show(BuildContext context, Uint8List png) {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImageEditorPage(png: png),
      ),
    );
  }

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> {
  /// 马赛克块边长（图片像素）。
  static const double _block = 14;

  final TransformationController _tc = TransformationController();

  ui.Image? _image;

  /// 整图按 [_block] 缩小再无插值放大就是马赛克，这里缓存缩小后的那张。
  ui.Image? _pixelated;

  _Tool _tool = _Tool.zoom;
  final List<List<Offset>> _strokes = <List<Offset>>[];

  /// 笔刷半径，单位是图片像素。
  double _brush = 24;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load(widget.png);
  }

  @override
  void dispose() {
    _tc.dispose();
    _image?.dispose();
    _pixelated?.dispose();
    super.dispose();
  }

  Future<void> _load(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final small = await _makePixelated(img);
    if (!mounted) {
      img.dispose();
      small.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _pixelated?.dispose();
      _image = img;
      _pixelated = small;
      _strokes.clear();
      _tc.value = Matrix4.identity();
    });
  }

  static Future<ui.Image> _makePixelated(ui.Image src) async {
    final w = math.max(1, (src.width / _block).round());
    final h = math.max(1, (src.height / _block).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    return recorder.endRecording().toImage(w, h);
  }

  Path _mosaicPath() {
    final path = Path();
    for (final stroke in _strokes) {
      for (final p in stroke) {
        path.addOval(Rect.fromCircle(center: p, radius: _brush));
      }
    }
    return path;
  }

  /// 把当前马赛克烧进像素，得到一张新图。
  Future<ui.Image> _flatten() async {
    final img = _image!;
    final small = _pixelated!;
    final full = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(img, full, full, Paint());
    if (_strokes.isNotEmpty) {
      canvas.save();
      canvas.clipPath(_mosaicPath());
      canvas.drawImageRect(
        small,
        Rect.fromLTWH(0, 0, small.width.toDouble(), small.height.toDouble()),
        full,
        // 放大时不插值，才是块状马赛克而不是一团模糊。
        Paint()..filterQuality = FilterQuality.none,
      );
      canvas.restore();
    }
    return recorder.endRecording().toImage(img.width, img.height);
  }

  Future<void> _done() async {
    if (_image == null || _busy) return;
    setState(() => _busy = true);
    final flat = await _flatten();
    final png = await WidgetCapture.pngOf(flat);
    flat.dispose();
    if (!mounted) return;
    Navigator.of(context).pop(png);
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('打码'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _done,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
      body: img == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(child: _buildCanvas(img)),
                _buildToolbar(),
              ],
            ),
    );
  }

  Widget _buildCanvas(ui.Image img) {
    return LayoutBuilder(
      builder: (context, c) {
        // 按宽度铺满：长图这样才看得清，纵向靠拖动浏览。
        final baseW = c.maxWidth;
        final baseH = baseW * img.height / img.width;
        final editing = _tool != _Tool.zoom;
        return ClipRect(
          child: InteractiveViewer(
            transformationController: _tc,
            constrained: false,
            panEnabled: !editing,
            scaleEnabled: !editing,
            minScale: 1,
            maxScale: 12,
            // 不留边界余量：图片必须始终盖住可视区，否则一滑就滑到空白里去了。
            boundaryMargin: EdgeInsets.zero,
            child: SizedBox(
              width: baseW,
              height: baseH,
              child: GestureDetector(
                onPanStart: editing
                    ? (d) => _onStart(d.localPosition, baseW, img)
                    : null,
                onPanUpdate: editing
                    ? (d) => _onUpdate(d.localPosition, baseW, img)
                    : null,
                child: CustomPaint(
                  size: Size(baseW, baseH),
                  painter: _EditorPainter(
                    image: img,
                    pixelated: _pixelated!,
                    strokes: _strokes,
                    brush: _brush,
                    imageToCanvas: baseW / img.width,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildToolbar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        border: Border(top: BorderSide(color: Color(0xFF2E2E31))),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<_Tool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                foregroundColor: Colors.white70,
                selectedForegroundColor: Colors.white,
                selectedBackgroundColor: const Color(0xFF3A3A3D),
                side: const BorderSide(color: Color(0xFF3A3A3D)),
              ),
              segments: const [
                ButtonSegment(
                  value: _Tool.zoom,
                  label: Text('浏览'),
                  icon: Icon(Icons.pan_tool_alt_outlined, size: 18),
                ),
                ButtonSegment(
                  value: _Tool.mosaic,
                  label: Text('涂抹打码'),
                  icon: Icon(Icons.blur_on, size: 18),
                ),
              ],
              selected: {_tool},
              onSelectionChanged: (s) => setState(() => _tool = s.first),
            ),
            const SizedBox(height: 10),
            SizedBox(height: 44, child: Center(child: _buildToolOptions())),
          ],
        ),
      ),
    );
  }

  Widget _buildToolOptions() {
    switch (_tool) {
      case _Tool.zoom:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Flexible(
              child: Text(
                '双指缩放、单指拖动，找到要打码的位置',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() => _tc.value = Matrix4.identity()),
              child: const Text('回到顶部'),
            ),
          ],
        );
      case _Tool.mosaic:
        return Row(
          children: [
            const Icon(Icons.brush_outlined, color: Colors.white54, size: 18),
            Expanded(
              child: Slider(
                value: _brush,
                min: 8,
                max: 80,
                onChanged: (v) => setState(() => _brush = v),
              ),
            ),
            IconButton(
              onPressed:
                  _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
              icon: const Icon(Icons.undo),
              color: Colors.white,
              disabledColor: Colors.white24,
              tooltip: '撤销一笔',
            ),
          ],
        );
    }
  }

  /// 画布坐标 → 图片像素坐标。画布宽度 [baseW] 对应图片整宽。
  Offset _toImage(Offset local, double baseW, ui.Image img) {
    final k = img.width / baseW;
    return Offset(local.dx * k, local.dy * k);
  }

  void _onStart(Offset local, double baseW, ui.Image img) {
    setState(() => _strokes.add(<Offset>[_toImage(local, baseW, img)]));
  }

  void _onUpdate(Offset local, double baseW, ui.Image img) {
    if (_strokes.isEmpty) return;
    final p = _toImage(local, baseW, img);
    setState(() {
      final stroke = _strokes.last;
      final from = stroke.last;
      // 手指移动快时点会很稀，中间插值，不然涂出来是一串断点。
      final steps = ((p - from).distance / (_brush * 0.4)).ceil().clamp(1, 64);
      for (var i = 1; i <= steps; i++) {
        stroke.add(Offset.lerp(from, p, i / steps)!);
      }
    });
  }
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.image,
    required this.pixelated,
    required this.strokes,
    required this.brush,
    required this.imageToCanvas,
  });

  final ui.Image image;
  final ui.Image pixelated;
  final List<List<Offset>> strokes;
  final double brush;

  /// 图片像素 → 画布坐标的比例。
  final double imageToCanvas;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint());

    if (strokes.isNotEmpty) {
      final path = Path();
      for (final stroke in strokes) {
        for (final p in stroke) {
          path.addOval(
            Rect.fromCircle(center: p * imageToCanvas, radius: brush * imageToCanvas),
          );
        }
      }
      canvas.save();
      canvas.clipPath(path);
      canvas.drawImageRect(
        pixelated,
        Rect.fromLTWH(
            0, 0, pixelated.width.toDouble(), pixelated.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.none,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EditorPainter old) =>
      old.image != image ||
      old.brush != brush ||
      old.imageToCanvas != imageToCanvas ||
      old.strokes.length != strokes.length ||
      (strokes.isNotEmpty && old.strokes.last.length != strokes.last.length);
}
