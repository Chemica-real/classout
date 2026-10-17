// 行内提示条 —— 鸿蒙各页/子页的 `toast`：滚动内容顶部（或列表顶部）一行蓝字/蓝底小字，
// 2.2 秒自动消失。不是 SnackBar（SnackBar 会盖住悬浮导航栏，位置也和鸿蒙不一致）。

import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// 给 `State` 用的混入：`showToast('已保存')` + `toastLine()` 插到内容最上方。
mixin InlineToastMixin<T extends StatefulWidget> on State<T> {
  String _toastText = '';
  Timer? _toastTimer;

  String get toastText => _toastText;

  void showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toastText = text);
    _toastTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _toastText = '');
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  /// 设置页那种"蓝底圆角小字条"
  Widget toastLine({bool filled = true}) {
    if (_toastText.isEmpty) return const SizedBox.shrink();
    final text = Text(_toastText,
        style: TextStyle(
            fontSize: 12,
            color: filled ? const Color(0xFFEAF0FA) : accentBlue));
    if (!filled) {
      return Padding(
          padding: const EdgeInsets.only(bottom: 4), child: text);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x382E6BE6), // rgba(46,107,230,0.22)
          borderRadius: BorderRadius.circular(8),
        ),
        child: text,
      ),
    );
  }
}
