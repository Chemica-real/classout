// 自定义背景的显示几何 —— 鸿蒙端 `domain/Wallpaper.ets` 的逐行移植。
//
// 模型（= CSS 的 `background-size: cover` + `background-position`）：
//   1. 先把图按「填满取景框」缩放（两条边都不留空）；
//   2. 再乘用户自己的缩放 `zoom`（≥1，永远不会露出底色，上限 4）；
//   3. 用户在**可动范围**里选位置：`fx` / `fy` ∈ [-1, 1]（0 = 居中，±1 = 顶到边）。
//
// 存的是**归一化焦点**而不是像素：换屏幕、横竖屏、换设备都不会让"调好的构图"跑偏。
// 纯函数、无副作用，`test/wallpaper_geometry_test.dart` 与鸿蒙 domain-check 的断言同值。

/// 缩放下限 1 = 至少铺满
const double wallpaperMinZoom = 1;

/// 缩放上限（鸿蒙 `WALLPAPER_MAX_ZOOM = 4`）
const double wallpaperMaxZoom = 4;

double _clampNum(double v, double lo, double hi) {
  if (v.isNaN) return lo;
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/// 把任意输入收进合法区间：fx/fy → [-1,1]，zoom → [1,4]
List<double> clampFocus(double fx, double fy, double zoom) => [
      _clampNum(fx, -1, 1),
      _clampNum(fy, -1, 1),
      _clampNum(zoom, wallpaperMinZoom, wallpaperMaxZoom),
    ];

/// 'fx,fy,zoom' → [fx, fy, zoom]。空串 / 坏数据 / 老版本没有这个键 → 居中、不缩放。
List<double> parseWallpaperFocus(String s) {
  final parts = s.split(',');
  if (parts.length != 3) return [0, 0, 1];
  final fx = double.tryParse(parts[0]);
  final fy = double.tryParse(parts[1]);
  final z = double.tryParse(parts[2]);
  if (fx == null || fy == null || z == null) return [0, 0, 1];
  return clampFocus(fx, fy, z);
}

/// [fx, fy, zoom] → 'fx,fy,zoom'（存储格式，与 parseWallpaperFocus 互逆）
String _numStr(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : '$v';

String formatWallpaperFocus(double fx, double fy, double zoom) {
  final v = clampFocus(fx, fy, zoom);
  // 输出与鸿蒙 `formatWallpaperFocus` 逐字符一致：JS 的 number 不带 ".0"
  return '${_numStr(v[0])},${_numStr(v[1])},${_numStr(v[2])}';
}

/// 背景图该怎么画（vp）。
class WallpaperGeometry {
  /// 图要画多大（已含 zoom）
  final double w;
  final double h;

  /// 相对"居中"的偏移量（已按可动范围夹紧）
  final double dx;
  final double dy;

  /// 横/纵各自还能移动多少；0 = 这个方向没有余量（比如 1:1 照片填竖屏）
  final double maxDx;
  final double maxDy;

  const WallpaperGeometry({
    required this.w,
    required this.h,
    required this.dx,
    required this.dy,
    required this.maxDx,
    required this.maxDy,
  });
}

/// `imgW/imgH` 是图片像素尺寸（只用比值），`boxW/boxH` 是取景框（屏幕）vp 尺寸。
/// 任何一边 <= 0（还没量到 / 图坏了）返回全 0 —— 调用方据此不画图，别抛异常。
WallpaperGeometry wallpaperGeometry(
    double imgW, double imgH, double boxW, double boxH, double zoom,
    double fx, double fy) {
  final v = clampFocus(fx, fy, zoom);
  final z = v[2];
  var w = 0.0;
  var h = 0.0;
  if (imgW > 0 && imgH > 0 && boxW > 0 && boxH > 0) {
    // cover：取两个方向里更大的那个比例，保证两条边都不留空
    final s = boxW / imgW > boxH / imgH ? boxW / imgW : boxH / imgH;
    w = imgW * s * z;
    h = imgH * s * z;
  }
  final maxDx = w > boxW ? (w - boxW) / 2 : 0.0;
  final maxDy = h > boxH ? (h - boxH) / 2 : 0.0;
  return WallpaperGeometry(
    w: w,
    h: h,
    dx: v[0] * maxDx,
    dy: v[1] * maxDy,
    maxDx: maxDx,
    maxDy: maxDy,
  );
}
