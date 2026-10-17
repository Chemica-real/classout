// 「调整位置 / 区域」—— 鸿蒙端 `SettingsPage.ets → AdjustOverlay()`。
//
// 布局与鸿蒙一致：
//   · 整屏预览：默认渐变垫底 + 照片（按焦点 translate/scale）+ **可读性薄纱**（所见即所得）；
//   · 顶部一张玻璃卡：「调整背景」17 + 说明 11；
//   · 底部一张玻璃卡：缩放滑杆（1.00–3.00×，步进 0.05）+ 居中 / 取消 / 保存 三等宽按钮；
//   · 单指拖动平移、双指捏合缩放；原图一个字节都不改，只存归一化焦点。

import 'dart:io';

import 'package:flutter/material.dart';

import 'app_frame.dart';
import 'theme.dart';

Future<String?> showWallpaperAdjust(BuildContext context,
    {required String path}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black,
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => _AdjustPage(path: path),
    transitionBuilder: (ctx, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

class _AdjustPage extends StatefulWidget {
  final String path;
  const _AdjustPage({required this.path});

  @override
  State<_AdjustPage> createState() => _AdjustPageState();
}

class _AdjustPageState extends State<_AdjustPage> {
  double _dx = 0;
  double _dy = 0;
  double _zoom = 1;
  double _baseZoom = 1;
  Offset _baseOffset = Offset.zero;

  /// 焦点平移在屏幕上的最大位移（与 AppFrame 的变换同一个系数 0.4，
  /// 这样"调的时候"和"退出去"看到的完全一致）
  static const double _shiftFactor = 0.4;

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
              onScaleStart: (_) {
                _baseZoom = _zoom;
                _baseOffset = Offset(_dx, _dy);
              },
              onScaleUpdate: (d) {
                setState(() {
                  _zoom = (_baseZoom * d.scale).clamp(1.0, 3.0);
                  final spanX = size.width * _shiftFactor;
                  final spanY = size.height * _shiftFactor;
                  _dx = (_baseOffset.dx + d.focalPointDelta.dx / spanX)
                      .clamp(-1.0, 1.0);
                  _dy = (_baseOffset.dy + d.focalPointDelta.dy / spanY)
                      .clamp(-1.0, 1.0);
                });
              },
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                        decoration: BoxDecoration(gradient: pageGradient)),
                    Transform.translate(
                      offset: Offset(
                          _dx * size.width * _shiftFactor,
                          _dy * size.height * _shiftFactor),
                      child: Transform.scale(
                        scale: _zoom,
                        child: Image.file(File(widget.path),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const ColoredBox(color: Colors.black)),
                      ),
                    ),
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
                            min: 1,
                            max: 3,
                            divisions: 40,
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
                            _dx = 0;
                            _dy = 0;
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
                              .pop(formatWallpaperFocus(_dx, _dy, _zoom)),
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
