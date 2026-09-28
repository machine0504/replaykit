import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 每帧压出来的「行指纹」：一行只保留 [buckets] 个列桶的平均亮度。
///
/// 找重叠只需要判断两帧哪一段行是同一批内容，不需要逐像素比。压成指纹后
/// 搜索量从「候选数 × 行 × 列」降到「候选数 × 行 × 12」，快两个数量级。
class _RowSig {
  _RowSig(this.height, this.data);

  final int height;
  final Float32List data;

  static const buckets = 12;

  factory _RowSig.from(Uint8List rgba, int w, int h) {
    final data = Float32List(h * buckets);
    final bw = math.max(1, w ~/ buckets);
    for (var y = 0; y < h; y++) {
      final row = y * w * 4;
      final out = y * buckets;
      for (var k = 0; k < buckets; k++) {
        final x0 = k * bw;
        final x1 = math.min(w, x0 + bw);
        var sum = 0;
        var n = 0;
        for (var x = x0; x < x1; x += 3) {
          final i = row + x * 4;
          sum += rgba[i] + rgba[i + 1] + rgba[i + 2];
          n += 3;
        }
        data[out + k] = n == 0 ? 0 : sum / n;
      }
    }
    return _RowSig(h, data);
  }

  /// 取 [start, end) 行，供去掉固定顶栏 / 底栏后再找滚动重叠。
  _RowSig slice(int start, int end) {
    final from = start.clamp(0, height);
    final to = end.clamp(from, height);
    final h = to - from;
    final out = Float32List(h * buckets);
    if (h > 0) {
      out.setRange(0, out.length, data, from * buckets);
    }
    return _RowSig(h, out);
  }
}

class _StitchPlan {
  const _StitchPlan(this.header, this.footer, this.skips);

  final int header;
  final int footer;
  final List<int> skips;
}

class _Slice {
  const _Slice(this.top, this.height);

  final double top;
  final double height;
}

/// 把多张全屏帧按重叠区域纵向拼成一张长图。
///
/// 微信底栏、导航这种不跟着滚的条，会先认出来，只在长图里留一次。
class FrameStitcher {
  FrameStitcher._();

  /// 指纹 MSE 超过这个值就认为两帧接不上（中间跳了内容），整帧直接接上，
  /// 宁可重复一屏也不要裁掉没截到的部分。
  static const double _noMatchScore = 600;

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// 逐帧读文件 → 拼成一张长图 PNG。
  ///
  /// 刻意不一次性把所有帧解码出来：30 帧 1080 宽的全屏图解成位图要三百多 MB，
  /// 手机上直接被系统杀掉。这里分两趟，任何时刻只驻留一两张图：
  ///  1. 逐帧解码 → 压成行指纹 → 立刻释放，用指纹算出每帧该裁掉多少；
  ///  2. 再逐帧解码 → 画到累积图上 → 释放。
  static Future<Uint8List> stitchFiles(
    List<String> paths, {
    int maxHeightPx = 16384,
    void Function(int current, int total)? onProgress,
  }) async {
    if (paths.isEmpty) {
      throw StateError('没有采集到任何一帧');
    }
    final total = paths.length * 2;

    final sigs = <_RowSig>[];
    final sizes = <List<int>>[];
    for (var i = 0; i < paths.length; i++) {
      onProgress?.call(i + 1, total);
      final img = await _decode(await File(paths[i]).readAsBytes());
      try {
        final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (bd == null) throw StateError('读取第 ${i + 1} 帧像素失败');
        sigs.add(_RowSig.from(bd.buffer.asUint8List(), img.width, img.height));
        sizes.add([img.width, img.height]);
      } finally {
        img.dispose();
      }
    }

    final plan = _plan(sigs);
    final width = sizes.map((s) => s[0]).reduce(math.max);

    ui.Image? acc;
    var y = 0.0;
    try {
      for (var i = 0; i < paths.length; i++) {
        onProgress?.call(paths.length + i + 1, total);
        if (y >= maxHeightPx) break;
        final src = _sliceOf(sizes[i][1], plan, i);
        if (src.height <= 0) continue; // 与上一帧完全重复，整帧丢掉
        final destH = math.min(src.height, maxHeightPx - y);
        final img = await _decode(await File(paths[i]).readAsBytes());
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        if (acc != null) {
          canvas.drawImage(acc, ui.Offset.zero, ui.Paint());
        }
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, src.top, img.width.toDouble(), destH),
          ui.Rect.fromLTWH(0, y, width.toDouble(), destH),
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
        final next = await recorder
            .endRecording()
            .toImage(width, (y + destH).round());
        img.dispose();
        acc?.dispose();
        acc = next;
        y += destH;
      }
      if (plan.footer > 0 && y < maxHeightPx && paths.isNotEmpty) {
        final lastH = sizes.last[1];
        final footerTop = lastH - plan.footer;
        if (footerTop >= 0) {
          final destH = math.min(plan.footer.toDouble(), maxHeightPx - y);
          final img = await _decode(await File(paths.last).readAsBytes());
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          if (acc != null) {
            canvas.drawImage(acc, ui.Offset.zero, ui.Paint());
          }
          canvas.drawImageRect(
            img,
            ui.Rect.fromLTWH(0, footerTop.toDouble(), img.width.toDouble(), destH),
            ui.Rect.fromLTWH(0, y, width.toDouble(), destH),
            ui.Paint()..filterQuality = ui.FilterQuality.high,
          );
          final next = await recorder
              .endRecording()
              .toImage(width, (y + destH).round());
          img.dispose();
          acc?.dispose();
          acc = next;
          y += destH;
        }
      }
      if (acc == null) {
        throw StateError('没有可拼接的内容');
      }
      final bytes = await acc.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG 编码失败');
      return bytes.buffer.asUint8List();
    } finally {
      acc?.dispose();
    }
  }

  static Future<ui.Image> stitchImages(
    List<ui.Image> frames, {
    int maxHeightPx = 16384,
    void Function(int current, int total)? onProgress,
  }) async {
    if (frames.isEmpty) {
      throw StateError('没有帧可拼接');
    }
    final steps = frames.length + 1;

    // 逐帧取像素 → 立刻压成指纹 → 丢掉像素。同时只驻留一帧的原始数据，
    // 36 帧全解成 RGBA 会到一百多 MB，手机上扛不住。
    final sigs = <_RowSig>[];
    for (var i = 0; i < frames.length; i++) {
      onProgress?.call(i + 1, steps);
      final img = frames[i];
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) {
        throw StateError('读取第 ${i + 1} 帧像素失败');
      }
      sigs.add(_RowSig.from(bd.buffer.asUint8List(), img.width, img.height));
    }
    onProgress?.call(steps, steps);

    final plan = _plan(sigs);
    var total = 0.0;
    for (var i = 0; i < frames.length; i++) {
      total += _sliceOf(frames[i].height, plan, i).height;
    }
    if (plan.footer > 0) total += plan.footer;

    final width = frames.map((f) => f.width).reduce(math.max);
    final outH = total.clamp(1, maxHeightPx);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.low;
    var y = 0.0;
    for (var i = 0; i < frames.length; i++) {
      if (y >= outH) break;
      final img = frames[i];
      final src = _sliceOf(img.height, plan, i);
      if (src.height <= 0) continue; // 与上一帧完全重复，整帧丢掉
      final destH = math.min(src.height.toDouble(), outH - y);
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, src.top, img.width.toDouble(), destH),
        ui.Rect.fromLTWH(0, y, width.toDouble(), destH),
        paint,
      );
      y += destH;
    }
    if (plan.footer > 0 && y < outH) {
      final img = frames.last;
      final footerTop = img.height - plan.footer;
      if (footerTop >= 0) {
        final destH = math.min(plan.footer.toDouble(), outH - y);
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, footerTop.toDouble(), img.width.toDouble(), destH),
          ui.Rect.fromLTWH(0, y, width.toDouble(), destH),
          paint,
        );
        y += destH;
      }
    }
    final picture = recorder.endRecording();
    return picture.toImage(width, math.max(1, y.round()));
  }

  /// 同一行亮度差小于这个值，就当成「没滚动」：底栏、顶栏这种固定条。
  static const double _fixedRowScore = 140;

  static _StitchPlan _plan(List<_RowSig> sigs) {
    final chrome = _stableChrome(sigs);
    final mids = <_RowSig>[
      for (final s in sigs)
        s.slice(chrome.header, s.height - chrome.footer),
    ];
    final skips = <int>[0];
    for (var i = 1; i < mids.length; i++) {
      final mid = mids[i];
      if (mid.height <= 0) {
        skips.add(0);
        continue;
      }
      skips.add(_overlap(mids[i - 1], mid));
    }
    return _StitchPlan(chrome.header, chrome.footer, skips);
  }

  /// 第 [i] 帧里真正要画进长图的那段（不含底栏；底栏最后贴一次）。
  static _Slice _sliceOf(int height, _StitchPlan plan, int i) {
    final footer = math.min(plan.footer, height);
    final header = math.min(plan.header, math.max(0, height - footer));
    final bodyBottom = height - footer;
    if (i == 0) {
      return _Slice(0, bodyBottom.toDouble());
    }
    final skip = i < plan.skips.length ? plan.skips[i] : 0;
    final top = header + skip;
    if (top >= bodyBottom) return const _Slice(0, 0);
    return _Slice(top.toDouble(), (bodyBottom - top).toDouble());
  }

  /// 多帧里位置不变的顶栏 / 底栏。列表在滚，标签栏不滚，所以同一行一直很像。
  static ({int header, int footer}) _stableChrome(List<_RowSig> sigs) {
    if (sigs.length < 2) return (header: 0, footer: 0);
    final h = sigs.map((s) => s.height).reduce(math.min);
    if (h < 64) return (header: 0, footer: 0);

    final votes = List<int>.filled(h, 0);
    var pairs = 0;
    for (var i = 1; i < sigs.length; i++) {
      final a = sigs[i - 1];
      final b = sigs[i];
      var same = 0;
      var checked = 0;
      for (var y = 0; y < h; y += 4) {
        checked++;
        if (_rowScore(a, b, y) < _fixedRowScore) same++;
      }
      // 整帧几乎一样：人还没滑，不参与投票，后面重叠会整帧丢掉。
      if (checked > 0 && same / checked > 0.92) continue;
      pairs++;
      for (var y = 0; y < h; y++) {
        if (_rowScore(a, b, y) < _fixedRowScore) votes[y]++;
      }
    }
    if (pairs == 0) return (header: 0, footer: 0);

    final need = math.max(1, (pairs * 0.6).ceil());
    var header = _edgeBand(votes, need, fromBottom: false);
    var footer = _edgeBand(votes, need, fromBottom: true);
    if (header < 20) header = 0;
    if (footer < 20) footer = 0;
    if (header + footer >= h - 32) return (header: 0, footer: 0);
    return (header: header, footer: footer);
  }

  static int _edgeBand(List<int> votes, int need, {required bool fromBottom}) {
    final h = votes.length;
    var gap = 0;
    var lastSolid = 0;
    for (var i = 0; i < h; i++) {
      final y = fromBottom ? h - 1 - i : i;
      if (votes[y] >= need) {
        gap = 0;
        lastSolid = i + 1;
      } else {
        gap++;
        if (gap > 8) break;
      }
    }
    return lastSolid;
  }

  static double _rowScore(_RowSig a, _RowSig b, int y) {
    if (y < 0 || y >= a.height || y >= b.height) return double.infinity;
    const bk = _RowSig.buckets;
    var sum = 0.0;
    var ai = y * bk;
    var bi = y * bk;
    for (var k = 0; k < bk; k++) {
      final d = a.data[ai] - b.data[bi];
      sum += d * d;
      ai++;
      bi++;
    }
    return sum / bk;
  }

  /// 返回 b 顶部与 a 底部重复的行数。先粗扫定位，再在附近逐行细扫。
  static int _overlap(_RowSig a, _RowSig b) {
    final minH = math.min(a.height, b.height);
    final minO = math.max(8, (minH * 0.04).round());
    // 上限取满高：两帧完全一样时重叠 = 整帧，这一帧就会被整个丢掉。
    final maxO = minH;
    const coarseStep = 12;

    var best = minO;
    var bestScore = double.infinity;
    for (var o = minO; o <= maxO; o += coarseStep) {
      final s = _score(a, b, o, 4);
      if (s < bestScore) {
        bestScore = s;
        best = o;
      }
    }

    final lo = math.max(minO, best - coarseStep);
    final hi = math.min(maxO, best + coarseStep);
    var fineBest = best;
    var fineScore = double.infinity;
    for (var o = lo; o <= hi; o++) {
      final s = _score(a, b, o, 1);
      if (s < fineScore) {
        fineScore = s;
        fineBest = o;
      }
    }
    return fineScore > _noMatchScore ? 0 : fineBest;
  }

  /// a 的末 [o] 行与 b 的前 [o] 行的指纹均方差，[rowStep] 控制抽样密度。
  static double _score(_RowSig a, _RowSig b, int o, int rowStep) {
    final aStart = a.height - o;
    if (aStart < 0 || o > b.height) return double.infinity;
    const bk = _RowSig.buckets;
    final da = a.data;
    final db = b.data;
    var sum = 0.0;
    var n = 0;
    for (var y = 0; y < o; y += rowStep) {
      var ai = (aStart + y) * bk;
      var bi = y * bk;
      for (var k = 0; k < bk; k++) {
        final d = da[ai] - db[bi];
        sum += d * d;
        ai++;
        bi++;
      }
      n += bk;
    }
    return n == 0 ? double.infinity : sum / n;
  }
}
