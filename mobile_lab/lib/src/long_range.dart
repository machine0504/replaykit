import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 长截图的内容区间，单位与 [ScrollController.offset] 相同（逻辑像素）。
///
/// [start] 是第一屏顶部对应的滚动位置；[end] 是最后一屏底部对应的内容坐标
///（等于最后一帧的 `offset + viewport`）。
class LongScreenshotRange {
  const LongScreenshotRange({required this.start, required this.end});

  final double start;
  final double end;

  double get extent => math.max(0, end - start);

  static double contentHeight(ScrollController controller) {
    if (!controller.hasClients) return 0;
    final p = controller.position;
    return p.maxScrollExtent + p.viewportDimension;
  }

  /// 从当前位置起的一屏。
  static LongScreenshotRange oneScreen(ScrollController controller) {
    if (!controller.hasClients) {
      return const LongScreenshotRange(start: 0, end: 1);
    }
    final p = controller.position;
    final view = p.viewportDimension;
    final max = p.maxScrollExtent;
    final start = p.pixels.clamp(0.0, max);
    final end = math.min(start + view, max + view);
    return LongScreenshotRange(start: start, end: math.max(start + 1, end));
  }

  static LongScreenshotRange fullPage(ScrollController controller) {
    if (!controller.hasClients) {
      return const LongScreenshotRange(start: 0, end: 1);
    }
    final p = controller.position;
    return LongScreenshotRange(
      start: 0,
      end: math.max(p.viewportDimension, p.maxScrollExtent + p.viewportDimension),
    );
  }

  /// 从当前位置往下截 [screens] 屏（可含小数）。
  static LongScreenshotRange screensFromHere(
    ScrollController controller,
    double screens,
  ) {
    if (!controller.hasClients) {
      return const LongScreenshotRange(start: 0, end: 1);
    }
    final p = controller.position;
    final view = p.viewportDimension;
    final max = p.maxScrollExtent;
    final start = p.pixels.clamp(0.0, max);
    final end = math.min(start + view * screens, max + view);
    return LongScreenshotRange(start: start, end: math.max(start + 1, end));
  }

  double screenCount(double viewport) =>
      viewport <= 0 ? 0 : extent / viewport;
}

/// 选长截图范围：拖两端，或点「一屏 / 2 屏 / 整页」。选的时候列表仍可滚动预览。
class LongScreenshotRangeBar extends StatelessWidget {
  const LongScreenshotRangeBar({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
    required this.onCancel,
    required this.onConfirm,
  });

  final ScrollController controller;
  final LongScreenshotRange value;
  final ValueChanged<LongScreenshotRange> onChanged;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  void _preview(LongScreenshotRange next, {required bool movedStart}) {
    onChanged(next);
    if (!controller.hasClients) return;
    final p = controller.position;
    final view = p.viewportDimension;
    final max = p.maxScrollExtent;
    if (movedStart) {
      controller.jumpTo(next.start.clamp(0.0, max));
    } else {
      controller.jumpTo((next.end - view).clamp(0.0, max));
    }
  }

  @override
  Widget build(BuildContext context) {
    final has = controller.hasClients;
    final view = has ? controller.position.viewportDimension : 1.0;
    final maxContent = has ? LongScreenshotRange.contentHeight(controller) : 1.0;
    final screens = value.screenCount(view);
    final theme = Theme.of(context);

    return Material(
      elevation: 2,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '拖动两端选择截多长，可滚动列表查看',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '已选约 ${screens.toStringAsFixed(1)} 屏',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            RangeSlider(
              min: 0,
              max: math.max(maxContent, value.end),
              values: RangeValues(
                value.start.clamp(0, math.max(maxContent, value.end)),
                value.end.clamp(0, math.max(maxContent, value.end)),
              ),
              onChanged: (v) {
                final movedStart = (v.start - value.start).abs() >=
                    (v.end - value.end).abs();
                var start = v.start;
                var end = v.end;
                if (end - start < view * 0.5) {
                  if (movedStart) {
                    start = end - view * 0.5;
                  } else {
                    end = start + view * 0.5;
                  }
                }
                start = start.clamp(0, maxContent);
                end = end.clamp(0, maxContent);
                if (end <= start) end = math.min(maxContent, start + 1);
                _preview(
                  LongScreenshotRange(start: start, end: end),
                  movedStart: movedStart,
                );
              },
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ActionChip(
                  label: const Text('当前一屏'),
                  onPressed: () => _preview(
                    LongScreenshotRange.oneScreen(controller),
                    movedStart: true,
                  ),
                ),
                ActionChip(
                  label: const Text('向下 2 屏'),
                  onPressed: () => _preview(
                    LongScreenshotRange.screensFromHere(controller, 2),
                    movedStart: false,
                  ),
                ),
                ActionChip(
                  label: const Text('向下 3 屏'),
                  onPressed: () => _preview(
                    LongScreenshotRange.screensFromHere(controller, 3),
                    movedStart: false,
                  ),
                ),
                ActionChip(
                  label: const Text('整页'),
                  onPressed: () => _preview(
                    LongScreenshotRange.fullPage(controller),
                    movedStart: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onConfirm,
                    child: const Text('开始截取'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
