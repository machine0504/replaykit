import 'package:flutter/foundation.dart';

/// 桌面三端没有本包的原生实现，采集其它 App 的能力只在 iOS / Android 可用。
bool get labIsMobile {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.android:
      return true;
    default:
      return false;
  }
}
