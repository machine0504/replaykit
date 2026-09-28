/// 截图实验室 · 移动端（iOS / Android）。
///
/// 只包含移动端能力，不依赖任何桌面插件，方便宿主 App 一键摘除：
///  - [WidgetCapture]：截当前页（`RepaintBoundary`）
///  - [RegionPickerPage]：冻结当前页后拖框裁切
///  - [LongScreenshot] + [LongScreenshotRange]：本页长截图，用户自选范围
///  - [OtherAppLongCapture]：授权后截当前屏幕，用户自己滑，停止后按重叠拼接
///  - [ImageEditorPage]：截完之后裁剪 / 打码
///  - [AlbumSaver]：写进系统相册
library screenshot_lab_mobile;

export 'src/album_saver.dart';
export 'src/frame_stitcher.dart';
export 'src/image_editor.dart';
export 'src/long_image_view.dart';
export 'src/long_range.dart';
export 'src/long_screenshot.dart';
export 'src/other_app_capture.dart';
export 'src/region_picker.dart';
export 'src/widget_capture.dart';
