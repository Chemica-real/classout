// 「调整位置 / 区域」—— 鸿蒙端 `SettingsPage.ets → AdjustOverlay()`。
//
// 布局与鸿蒙一致：
//   · 整屏预览：默认渐变垫底 + 照片（按焦点 translate/scale）+ **可读性薄纱**（所见即所得）；
//   · 顶部一张玻璃卡：「调整背景」17 + 说明 11；
//   · 底部一张玻璃卡：缩放滑杆（1.00–4.00×，步进 0.05）+ 居中 / 取消 / 保存 三等宽按钮；
//   · 单指拖动平移（位移 ÷ 该方向的可动余量 = 归一化焦点）、双指捏合缩放；
//   · 几何走 `domain/wallpaper.dart` 的同一个 `wallpaperGeometry`（和所有页面的背景一致）；
//   · 原图一个字节都不改，只存归一化焦点。

import 'package:flutter/material.dart';

import '../data/wallpaper.dart';
import '../domain/wallpaper.dart';
import 'app_frame.dart';
import 'theme.dart';
import 'wallpaper_view.dart';

Future<String?> showWallpaperAdjust(BuildContext context,
    {required String path, String focus = '0,0,1'}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black,
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => _AdjustPage(path: path, focus: focus),
    transitionBuilder: (ctx, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

class _AdjustPage extends StatefulWidget {
  final String path;

  /// 当前的 'fx,fy,zoom'：**再进调整页要停在保存时的构图**（鸿蒙 `openAdjust` 也是从存的值起）
  final String focus;
  const _AdjustPage({required this.path, required this.focus});

  @override
  State<_AdjustPage> createState() => _AdjustPageState();
}

class _AdjustPageState extends State<_AdjustPage> {
  double _fx = 0;
  double _fy = 0;
  double _zoom = 1;
  double _baseZoom = 1;
  double _baseFx = 0;
  double _baseFy = 0;

  /// 原图像素尺寸（算 cover 与可动余量要用）
  Size? _img;

  @override
  void initState() {
    super.initState();
    final f = parseWallpaperFocus(widget.focus);
    _fx = f[0];
    _fy = f[1];
    _zoom = f[2];
    wallpaperImageSize(widget.path).then((v) {
      if (mounted) setState(() => _img = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ---------- 整屏预览 ----------
          Positioned.fill(
            child: GestureDetector(
              // ⚠️ 必须 opaque：预览层里除了薄纱（IgnorePointer）没有可命中子节点，
              // 默认的 deferToChild 会让单指拖动/双指捏合根本收不到事件
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) {
                _baseZoom = _zoom;
                _baseFx = _fx;
                _baseFy = _fy;
              },
              onScaleUpdate: (d) {
                // 鸿蒙 `dragAdjust`：手指位移 ÷ 该方向的可动余量（maxDx/maxDy）
                final g = wallpaperGeometry(
                    _img?.width ?? 0,
                    _img?.height ?? 0,
                    size.width,
                    size.height,
                    _zoom,
                    _baseFx,
                    _baseFy);
                setState(() {
                  _zoom = (_baseZoom * d.scale)
                      .clamp(wallpaperMinZoom, wallpaperMaxZoom);
                  _fx = g.maxDx > 0
                      ? (_baseFx + d.focalPointDelta.dx / g.maxDx)
                          .clamp(-1.0, 1.0)
                      : _baseFx;
                  _fy = g.maxDy > 0
                      ? (_baseFy + d.focalPointDelta.dy / g.maxDy)
                          .clamp(-1.0, 1.0)
                      : _baseFy;
                });
              },
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                        decoration: BoxDecoration(gradient: pageGradient)),
                    // 与所有页面的背景同一个几何函数 → 所见即所得
                    WallpaperImage(
                        path: widget.path,
                        focus: formatWallpaperFocus(_fx, _fy, _zoom)),
                    // WALLPAPER_VEIL = rgba(6,8,16,0.62)：预览就要连同薄纱一起看
                    const ColoredBox(
                        color: Color(0x9E060810),
                        child: IgnorePointer()),
                  ],
                ),
              ),
            ),
          ),
          // ---------- 顶部说明（浮窗）----------
          Positioned(
            left: floatSide,
            right: floatSide,
            top: MediaQuery.of(context).padding.top + floatSide,
            child: const IgnorePointer(
              child: Glass(
                sheet: true,
                padding: EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('调整背景',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFF2F5FA))),
                    Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('拖动选择区域；双指或下面的滑杆缩放。原图不会被改动。',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFFC3CDDE))),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ---------- 底部：滑杆 + 三个按钮 ----------
          Positioned(
            left: floatSide,
            right: floatSide,
            bottom: MediaQuery.of(context).padding.bottom + floatSide,
            child: Glass(
              sheet: true,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 40,
                        child: Text('缩放',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFC3CDDE))),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 9),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 16),
                          ),
                          child: Slider(
                            key: const ValueKey('wp-zoom-slider'),
                            value: _zoom,
                            min: wallpaperMinZoom,
                            max: wallpaperMaxZoom,
                            divisions: 60, // 步进 0.05（鸿蒙 Slider step: 0.05）
                            activeColor: const Color(0xFF2E6BE6),
                            inactiveColor:
                                Colors.white.withValues(alpha: 0.16),
                            onChanged: (v) => setState(() => _zoom = v),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text('${_zoom.toStringAsFixed(2)}×',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF7FA8FF))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _Btn(
                          text: '居中',
                          onTap: () => setState(() {
                            _fx = 0;
                            _fy = 0;
                            _zoom = 1;
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _Btn(
                          text: '取消',
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _Btn(
                          key: const ValueKey('wp-adjust-save'),
                          text: '保存',
                          primary: true,
                          onTap: () => Navigator.of(context)
                              .pop(formatWallpaperFocus(_fx, _fy, _zoom)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部三按钮（鸿蒙默认 Button：高 40、胶囊）
class _Btn extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final bool primary;
  const _Btn(
      {super.key, required this.text, required this.onTap, this.primary = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary
              ? const Color(0xFF2E6BE6)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: primary ? Colors.white : const Color(0xFFC3CDDE))),
      ),
    );
  }
}
