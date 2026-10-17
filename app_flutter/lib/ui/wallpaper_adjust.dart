// 「调整位置 / 区域」—— 鸿蒙端设置页背景卡里那个入口。
//
// 全屏预览：手指拖动平移、双指缩放；底部「居中」一键回默认；右上「保存」写回
// `wallpaper_focus`（'dx,dy,zoom'）。

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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('调整背景位置',
                        style: TextStyle(fontSize: 16, color: Colors.white)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFA9B5C9)),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop(formatWallpaperFocus(_dx, _dy, _zoom)),
                    style: TextButton.styleFrom(foregroundColor: accentBlue),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                onScaleStart: (_) {
                  _baseZoom = _zoom;
                  _baseOffset = Offset(_dx, _dy);
                },
                onScaleUpdate: (d) {
                  setState(() {
                    _zoom = (_baseZoom * d.scale).clamp(1.0, 3.0);
                    _dx = (_baseOffset.dx + d.focalPointDelta.dx / size.width)
                        .clamp(-1.0, 1.0);
                    _dy = (_baseOffset.dy + d.focalPointDelta.dy / size.height)
                        .clamp(-1.0, 1.0);
                  });
                },
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Transform.translate(
                          offset: Offset(_dx * size.width, _dy * size.height),
                          child: Transform.scale(
                            scale: _zoom,
                            child: Image.file(File(widget.path),
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const ColoredBox(color: Colors.black)),
                          ),
                        ),
                      ),
                      // 提示条
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: IgnorePointer(
                          child: Center(
                            child: Glass(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              child: const Text('拖动平移 · 双指缩放',
                                  style: TextStyle(
                                      fontSize: 12, color: inkPrimary)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _dx = 0;
                        _dy = 0;
                        _zoom = 1;
                      }),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('居中',
                            style: TextStyle(
                                fontSize: 13, color: Color(0xFFC3CDDE))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
