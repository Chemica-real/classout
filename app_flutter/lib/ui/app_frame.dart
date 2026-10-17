// 应用外壳的视觉部分：渐变背景 + 底部四标签。
// 课表页/待办页都把自己的内容塞进来，底部导航只有这一份。

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'palette.dart';

const List<String> tabLabels = ['课表', '待办', '计划', '设置'];

class AppFrame extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  final Widget child;
  const AppFrame({super.key, required this.tab, required this.onTab, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101826), Color(0xFF1B2436), Color(0xFF241F33)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(child: child),
            _BottomTabs(tab: tab, onTab: onTab),
          ],
        ),
      ),
    );
  }
}

class _BottomTabs extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _BottomTabs({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(tabLabels.length, (i) {
                final active = i == tab;
                return InkWell(
                  onTap: () => onTab(i),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                    child: Text(
                      tabLabels[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                        color: active ? inkPrimary : inkTertiary,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一的玻璃底板
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;
  final EdgeInsets padding;
  const Glass({
    super.key,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
