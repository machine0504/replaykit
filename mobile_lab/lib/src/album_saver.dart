import 'package:flutter/services.dart';

import 'platforms.dart';

/// 把 PNG 写进系统相册。
///
/// 走本插件自己的原生实现（iOS PHPhotoLibrary / Android MediaStore），
/// 不引第三方包，宿主 App 摘除时不会留下多余依赖。
class AlbumSaver {
  AlbumSaver._();

  static const _methods = MethodChannel('native_screenshot_lab/system_capture');

  /// 成功返回 `null`，失败返回可直接提示给用户的原因。
  static Future<String?> savePng(Uint8List png) async {
    if (!labIsMobile) return '当前平台不支持保存到相册';
    if (png.isEmpty) return '没有可保存的图片';
    try {
      await _methods.invokeMethod('saveToAlbum', {'bytes': png});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '保存失败';
    } on MissingPluginException {
      return '当前平台不支持保存到相册';
    } catch (e) {
      return '$e';
    }
  }
}
