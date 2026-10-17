// 引导条 —— 鸿蒙端 `view/GuideBar.ets`（演练期间浮在界面下方的一张玻璃卡）。
//
// 显示：第 N/7 步、标题、正文、上一步 / 下一步（最后一步是「完成演练」）/ 退出演练。
// 它**不改任何数据**，按钮回调都交给 HomeShell。

import 'package:flutter/material.dart';

import '../domain/guide.dart';
import 'app_frame.dart';
import 'theme.dart';

class GuideBar extends StatelessWidget {
  final int step;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onExit;

  const GuideBar({
    super.key,
    required this.step,
    required this.onPrev,
    required this.onNext,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final s = guideStepAt(step);
    final total = guideStepCount();
    final last = isLastGuideStep(step);
    return Glass(
      sheet: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头一行：第 N/7 步 + 标题 + 退出演练（鸿蒙端也是这样一行）
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('第 ${step + 1}/$total 步',
                  style: const TextStyle(fontSize: 11, color: accentBlue)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
              ),
              GestureDetector(
                onTap: onExit,
                behavior: HitTestBehavior.opaque,
                child: const Text('退出演练',
                    style: TextStyle(fontSize: 11, color: Color(0xFFA9B5C9))),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(s.body,
              style: const TextStyle(
                  fontSize: 12, height: 1.45, color: Color(0xFFC3CDDE))),
          const SizedBox(height: 10),
          Row(
            children: [
              if (step > 0)
                _Btn(
                  text: '上一步',
                  background: Colors.white.withValues(alpha: 0.14),
                  color: const Color(0xFFC3CDDE),
                  onTap: onPrev,
                ),
              const Spacer(),
              _Btn(
                text: last ? '完成演练' : '下一步',
                background: const Color(0xFF2E6BE6),
                color: Colors.white,
                onTap: onNext,
                wide: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final String text;
  final Color background;
  final Color color;
  final VoidCallback onTap;

  /// 主按钮（下一步/完成演练）比次要按钮宽一档
  final bool wide;
  const _Btn({
    required this.text,
    required this.background,
    required this.color,
    required this.onTap,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: EdgeInsets.symmetric(
            horizontal: wide ? 28 : 16, vertical: wide ? 9 : 7),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500, color: color)),
      ),
    );
  }
}
