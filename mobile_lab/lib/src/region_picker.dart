import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'widget_capture.dart';

/// 在冻结的当前页截图上拖框，确认后返回裁切 PNG。
class RegionPickerPage extends StatefulWidget {
  const RegionPickerPage({super.key, required this.image});

  final ui.Image image;

  static Future<Uint8List?> show(BuildContext context, ui.Image image) {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RegionPickerPage(image: image),
      ),
    );
  }

  @override
  State<RegionPickerPage> createState() => _RegionPickerPageState();
}

class _RegionPickerPageState extends State<RegionPickerPage> {
  late Rect _rect;
  _DragKind? _kind;
  Offset _last = Offset.zero;
  Offset _anchor = Offset.zero;

  @override
  void initState() {
    super.initState();
    final w = widget.image.width.toDouble();
    final h = widget.image.height.toDouble();
    _rect = Rect.fromLTWH(w * 0.1, h * 0.1, w * 0.8, h * 0.8);
  }

  Future<void> _confirm() async {
    final img = widget.image;
    final r = Rect.fromLTRB(
      _rect.left.clamp(0, img.width.toDouble()),
      _rect.top.clamp(0, img.height.toDouble()),
      _rect.right.clamp(0, img.width.toDouble()),
      _rect.bottom.clamp(0, img.height.toDouble()),
    );
    if (r.width < 4 || r.height < 4) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      img,
      r,
      Rect.fromLTWH(0, 0, r.width, r.height),
      Paint()..filterQuality = FilterQuality.none,
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(r.width.round(), r.height.round());
    try {
      final png = await WidgetCapture.pngOf(cropped);
      if (mounted) Navigator.of(context).pop(png);
    } finally {
      cropped.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('拖动框选区域'),
        actions: [
          TextButton(
            onPressed: _confirm,
            child: const Text('确认', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 画面钉死在这一屏里，手指只改选框，不滚动页面。
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (d) => _onStart(d.localPosition, constraints.biggest),
            onPanUpdate: (d) => _onUpdate(d.localPosition, constraints.biggest),
            onPanEnd: (_) => _kind = null,
            onPanCancel: () => _kind = null,
            child: CustomPaint(
              size: constraints.biggest,
              painter: _RegionPainter(image: widget.image, rect: _rect),
            ),
          );
        },
      ),
    );
  }

  _Mapping _map(Size box) => _Mapping(widget.image, box);

  Rect get _bounds => Rect.fromLTWH(
        0,
        0,
        widget.image.width.toDouble(),
        widget.image.height.toDouble(),
      );

  void _onStart(Offset local, Size box) {
    final m = _map(box);
    final p = m.toImage(local);
    final sel = m.toLocal(_rect);
    _last = p;
    final hit = _hitLocal(sel, local);
    if (hit == null) {
      _kind = _DragKind.draw;
      _anchor = p;
      setState(() => _rect = Rect.fromPoints(p, p));
      return;
    }
    _kind = hit;
  }

  void _onUpdate(Offset local, Size box) {
    final kind = _kind;
    if (kind == null) return;
    final p = _map(box).toImage(local);
    setState(() {
      if (kind == _DragKind.draw) {
        _rect = _normalize(Rect.fromPoints(_anchor, p), _bounds);
        return;
      }
      final delta = p - _last;
      _last = p;
      _rect = _apply(_rect, kind, delta, _bounds);
    });
  }
}

enum _DragKind { move, draw, n, s, e, w, nw, ne, sw, se }

const double _handleRadius = 28;
const double _edgeSlop = 24;
const double _minSide = 32;

/// 用屏幕上的手指位置判断，不跟图片像素走，角和边都更好抓。
_DragKind? _hitLocal(Rect r, Offset p) {
  bool near(Offset c) => (p - c).distance <= _handleRadius;
  if (near(r.topLeft)) return _DragKind.nw;
  if (near(r.topRight)) return _DragKind.ne;
  if (near(r.bottomLeft)) return _DragKind.sw;
  if (near(r.bottomRight)) return _DragKind.se;
  final onX = p.dx >= r.left - _edgeSlop && p.dx <= r.right + _edgeSlop;
  final onY = p.dy >= r.top - _edgeSlop && p.dy <= r.bottom + _edgeSlop;
  if (onX && (p.dy - r.top).abs() <= _edgeSlop) return _DragKind.n;
  if (onX && (p.dy - r.bottom).abs() <= _edgeSlop) return _DragKind.s;
  if (onY && (p.dx - r.left).abs() <= _edgeSlop) return _DragKind.w;
  if (onY && (p.dx - r.right).abs() <= _edgeSlop) return _DragKind.e;
  if (r.contains(p)) return _DragKind.move;
  return null;
}

Rect _normalize(Rect r, Rect bounds) {
  var left = math.min(r.left, r.right);
  var right = math.max(r.left, r.right);
  var top = math.min(r.top, r.bottom);
  var bottom = math.max(r.top, r.bottom);
  left = left.clamp(bounds.left, bounds.right);
  right = right.clamp(bounds.left, bounds.right);
  top = top.clamp(bounds.top, bounds.bottom);
  bottom = bottom.clamp(bounds.top, bounds.bottom);
  if (right - left < _minSide) {
    right = math.min(bounds.right, left + _minSide);
    left = math.max(bounds.left, right - _minSide);
  }
  if (bottom - top < _minSide) {
    bottom = math.min(bounds.bottom, top + _minSide);
    top = math.max(bounds.top, bottom - _minSide);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _apply(Rect r, _DragKind kind, Offset d, Rect bounds) {
  if (kind == _DragKind.move) {
    var dx = d.dx;
    var dy = d.dy;
    if (r.left + dx < bounds.left) dx = bounds.left - r.left;
    if (r.right + dx > bounds.right) dx = bounds.right - r.right;
    if (r.top + dy < bounds.top) dy = bounds.top - r.top;
    if (r.bottom + dy > bounds.bottom) dy = bounds.bottom - r.bottom;
    return r.shift(Offset(dx, dy));
  }
  var left = r.left;
  var top = r.top;
  var right = r.right;
  var bottom = r.bottom;
  switch (kind) {
    case _DragKind.n:
      top += d.dy;
      break;
    case _DragKind.s:
      bottom += d.dy;
      break;
    case _DragKind.w:
      left += d.dx;
      break;
    case _DragKind.e:
      right += d.dx;
      break;
    case _DragKind.nw:
      left += d.dx;
      top += d.dy;
      break;
    case _DragKind.ne:
      right += d.dx;
      top += d.dy;
      break;
    case _DragKind.sw:
      left += d.dx;
      bottom += d.dy;
      break;
    case _DragKind.se:
      right += d.dx;
      bottom += d.dy;
      break;
    case _DragKind.move:
    case _DragKind.draw:
      break;
  }
  if (right - left < _minSide) {
    if (kind == _DragKind.w || kind == _DragKind.nw || kind == _DragKind.sw) {
      left = right - _minSide;
    } else {
      right = left + _minSide;
    }
  }
  if (bottom - top < _minSide) {
    if (kind == _DragKind.n || kind == _DragKind.nw || kind == _DragKind.ne) {
      top = bottom - _minSide;
    } else {
      bottom = top + _minSide;
    }
  }
  return _normalize(Rect.fromLTRB(left, top, right, bottom), bounds);
}

class _Mapping {
  _Mapping(ui.Image image, Size box) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    scale = math.min(box.width / iw, box.height / ih);
    fitted = Size(iw * scale, ih * scale);
    origin = Offset((box.width - fitted.width) / 2, (box.height - fitted.height) / 2);
    this.iw = iw;
    this.ih = ih;
  }

  late final double scale;
  late final Size fitted;
  late final Offset origin;
  late final double iw;
  late final double ih;

  Offset toImage(Offset local) =>
      Offset((local.dx - origin.dx) / scale, (local.dy - origin.dy) / scale);

  Rect toLocal(Rect imageRect) => Rect.fromLTWH(
        origin.dx + imageRect.left * scale,
        origin.dy + imageRect.top * scale,
        imageRect.width * scale,
        imageRect.height * scale,
      );
}

class _RegionPainter extends CustomPainter {
  _RegionPainter({required this.image, required this.rect});

  final ui.Image image;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final m = _Mapping(image, size);
    final dst = Rect.fromLTWH(m.origin.dx, m.origin.dy, m.fitted.width, m.fitted.height);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, m.iw, m.ih),
      dst,
      Paint(),
    );
    canvas.drawRect(dst, Paint()..color = Colors.black.withValues(alpha: 0.45));
    final sel = m.toLocal(rect);
    canvas.save();
    canvas.clipRect(sel);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, m.iw, m.ih),
      dst,
      Paint(),
    );
    canvas.restore();
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(sel, border);
    final handle = Paint()..color = Colors.white;
    final edge = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const edgeLen = 28.0;
    void edgeBar(Offset c, bool horizontal) {
      final d = horizontal ? const Offset(edgeLen, 0) : const Offset(0, edgeLen);
      canvas.drawLine(c - d, c + d, edge);
    }
    edgeBar(sel.topCenter, true);
    edgeBar(sel.bottomCenter, true);
    edgeBar(sel.centerLeft, false);
    edgeBar(sel.centerRight, false);
    for (final c in [sel.topLeft, sel.topRight, sel.bottomLeft, sel.bottomRight]) {
      canvas.drawCircle(c, 11, handle);
      canvas.drawCircle(
        c,
        11,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RegionPainter old) =>
      old.image != image || old.rect != rect;
}

/// 盖在可滚动页面上的选框。框内空白留给列表滚动，只有边和角才改大小。
class RegionCropOverlay extends StatefulWidget {
  const RegionCropOverlay({super.key});

  @override
  State<RegionCropOverlay> createState() => RegionCropOverlayState();
}

class RegionCropOverlayState extends State<RegionCropOverlay> {
  Rect? _rect;
  static const double _minSide = 88;

  Rect get rect => _rect ?? Rect.zero;

  Future<Uint8List> capture(GlobalKey boundaryKey) async {
    final image = await WidgetCapture.toImage(boundaryKey);
    try {
      final dpr = WidgetCapture.pixelRatioOf(boundaryKey);
      final box = rect;
      final r = Rect.fromLTRB(
        (box.left * dpr).clamp(0, image.width.toDouble()),
        (box.top * dpr).clamp(0, image.height.toDouble()),
        (box.right * dpr).clamp(0, image.width.toDouble()),
        (box.bottom * dpr).clamp(0, image.height.toDouble()),
      );
      if (r.width < 4 || r.height < 4) {
        throw StateError('选框太小');
      }
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        r,
        Rect.fromLTWH(0, 0, r.width, r.height),
        Paint(),
      );
      final cropped =
          await recorder.endRecording().toImage(r.width.round(), r.height.round());
      try {
        return await WidgetCapture.pngOf(cropped);
      } finally {
        cropped.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _rect ??= Rect.fromLTWH(
          16,
          48,
          math.max(_minSide, size.width - 32),
          math.min(200, math.max(_minSide, size.height * 0.36)),
        );
        final rect = _clamp(_rect!, size);
        _rect = rect;
        return Stack(
          children: [
            IgnorePointer(
              child: CustomPaint(
                size: size,
                painter: _OverlayPainter(rect),
              ),
            ),
            for (final h in _HandleKind.values)
              _handle(h, rect, size),
          ],
        );
      },
    );
  }

  Widget _handle(_HandleKind kind, Rect rect, Size size) {
    const hit = 36.0;
    final box = switch (kind) {
      _HandleKind.nw => Rect.fromCenter(center: rect.topLeft, width: hit, height: hit),
      _HandleKind.ne => Rect.fromCenter(center: rect.topRight, width: hit, height: hit),
      _HandleKind.sw => Rect.fromCenter(center: rect.bottomLeft, width: hit, height: hit),
      _HandleKind.se => Rect.fromCenter(center: rect.bottomRight, width: hit, height: hit),
      _HandleKind.n => Rect.fromCenter(center: rect.topCenter, width: 56, height: hit),
      _HandleKind.s => Rect.fromCenter(center: rect.bottomCenter, width: 56, height: hit),
      _HandleKind.w => Rect.fromCenter(center: rect.centerLeft, width: hit, height: 56),
      _HandleKind.e => Rect.fromCenter(center: rect.centerRight, width: hit, height: 56),
      // 拖动钮放在选框上沿外面，不挡住框里的内容。
      _HandleKind.move => Rect.fromCenter(
          center: rect.top >= 36
              ? rect.topCenter - const Offset(0, 20)
              : rect.bottomCenter + const Offset(0, 20),
          width: 36,
          height: 36,
        ),
    };
    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) {
          setState(() {
            _rect = _resize(rect, kind, d.delta, size);
          });
        },
        child: kind == _HandleKind.move
            ? const DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xF2FFFFFF),
                  borderRadius: BorderRadius.all(Radius.circular(14)),
                ),
                child: Icon(Icons.open_with, size: 16, color: Color(0xFF1B3A4B)),
              )
            : const SizedBox.expand(),
      ),
    );
  }

  Rect _clamp(Rect r, Size size) {
    var left = r.left;
    var top = r.top;
    var right = r.right;
    var bottom = r.bottom;
    if (right - left < _minSide) right = left + _minSide;
    if (bottom - top < _minSide) bottom = top + _minSide;
    if (right > size.width) {
      right = size.width;
      left = math.max(0, right - math.max(_minSide, r.width));
    }
    if (bottom > size.height) {
      bottom = size.height;
      top = math.max(0, bottom - math.max(_minSide, r.height));
    }
    left = left.clamp(0.0, size.width);
    top = top.clamp(0.0, size.height);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect _resize(Rect r, _HandleKind kind, Offset d, Size size) {
    var left = r.left;
    var top = r.top;
    var right = r.right;
    var bottom = r.bottom;
    if (kind == _HandleKind.move) {
      var dx = d.dx;
      var dy = d.dy;
      if (r.left + dx < 0) dx = -r.left;
      if (r.right + dx > size.width) dx = size.width - r.right;
      if (r.top + dy < 0) dy = -r.top;
      if (r.bottom + dy > size.height) dy = size.height - r.bottom;
      return r.shift(Offset(dx, dy));
    }
    switch (kind) {
      case _HandleKind.move:
        break;
      case _HandleKind.n:
        top += d.dy;
        break;
      case _HandleKind.s:
        bottom += d.dy;
        break;
      case _HandleKind.w:
        left += d.dx;
        break;
      case _HandleKind.e:
        right += d.dx;
        break;
      case _HandleKind.nw:
        left += d.dx;
        top += d.dy;
        break;
      case _HandleKind.ne:
        right += d.dx;
        top += d.dy;
        break;
      case _HandleKind.sw:
        left += d.dx;
        bottom += d.dy;
        break;
      case _HandleKind.se:
        right += d.dx;
        bottom += d.dy;
        break;
    }
    if (right - left < _minSide) {
      if (kind == _HandleKind.w || kind == _HandleKind.nw || kind == _HandleKind.sw) {
        left = right - _minSide;
      } else {
        right = left + _minSide;
      }
    }
    if (bottom - top < _minSide) {
      if (kind == _HandleKind.n || kind == _HandleKind.nw || kind == _HandleKind.ne) {
        top = bottom - _minSide;
      } else {
        bottom = top + _minSide;
      }
    }
    left = left.clamp(0.0, size.width - _minSide);
    top = top.clamp(0.0, size.height - _minSide);
    right = right.clamp(left + _minSide, size.width);
    bottom = bottom.clamp(top + _minSide, size.height);
    return Rect.fromLTRB(left, top, right, bottom);
  }
}

enum _HandleKind { nw, ne, sw, se, n, s, w, e, move }

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, overlay, hole),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final mark = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const len = 18.0;
    for (final c in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      canvas.drawCircle(c, 8, Paint()..color = Colors.white);
    }
    canvas.drawLine(rect.topCenter - const Offset(len, 0), rect.topCenter + const Offset(len, 0), mark);
    canvas.drawLine(rect.bottomCenter - const Offset(len, 0), rect.bottomCenter + const Offset(len, 0), mark);
    canvas.drawLine(rect.centerLeft - const Offset(0, len), rect.centerLeft + const Offset(0, len), mark);
    canvas.drawLine(rect.centerRight - const Offset(0, len), rect.centerRight + const Offset(0, len), mark);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => old.rect != rect;
}
