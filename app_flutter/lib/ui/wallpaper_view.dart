// 壁纸的渲染 —— 与鸿蒙 `PageBackground` / `AdjustOverlay` 用**同一个几何函数**
// (`domain/wallpaper.dart → wallpaperGeometry`)：
//   图按 cover 缩放到 `w × h`（含 zoom），再相对取景框居中、按归一化焦点平移 dx/dy。
// 这样"调整背景"里看到的位置就是退出去以后所有页面上的位置（所见即所得）。

import 'dart:io';

import 'package:flutter/widgets.dart';

import '../data/wallpaper.dart';
import '../domain/wallpaper.dart';

class WallpaperImage extends StatelessWidget {
  final String path;

  /// 'fx,fy,zoom'
  final String focus;
  const WallpaperImage({super.key, required this.path, required this.focus});

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty || !File(path).existsSync()) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<Size?>(
      future: wallpaperImageSize(path),
      builder: (context, snap) {
        final img = snap.data;
        if (img == null) return const SizedBox.shrink();
        return LayoutBuilder(builder: (context, c) {
          final boxW = c.maxWidth;
          final boxH = c.maxHeight;
          if (!boxW.isFinite || !boxH.isFinite) {
            return const SizedBox.shrink();
          }
          final f = parseWallpaperFocus(focus);
          final g = wallpaperGeometry(
              img.width, img.height, boxW, boxH, f[2], f[0], f[1]);
          if (g.w <= 0 || g.h <= 0) return const SizedBox.shrink();
          return ClipRect(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: (boxW - g.w) / 2 + g.dx,
                  top: (boxH - g.h) / 2 + g.dy,
                  width: g.w,
                  height: g.h,
                  child: Image.file(File(path), fit: BoxFit.fill),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}
