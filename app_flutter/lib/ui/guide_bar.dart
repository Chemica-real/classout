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
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头一行：第 N/N 步（金色小字）+ 标题 + 退出演练（红字）
          Row(
            children: [
              Text('第 ${step + 1}/$total 步',
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFFE8B25C))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
              ),
              GestureDetector(
                onTap: onExit,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(left: 10, top: 2, bottom: 2),
                  child: Text('退出演练',
                      style: TextStyle(fontSize: 11, color: Color(0xFFFF8A8A))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(s.body,
              style: const TextStyle(
                  fontSize: 12, height: 1.45, color: Color(0xFFC3CDDE))),
          const SizedBox(height: 10),
          Row(
            children: [
              // 鸿蒙端两个按钮**等宽**，第一步时「上一步」变淡但仍占位
              Expanded(
                child: _Btn(
                  text: '上一步',
                  background: Colors.white.withValues(alpha: 0.14),
                  color: const Color(0xFFC3CDDE),
                  onTap: onPrev,
                  enabled: step > 0,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Btn(
                  text: last ? '完成演练' : '下一步',
                  background: const Color(0xFF2E6BE6),
                  color: Colors.white,
                  onTap: onNext,
                ),
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
  final bool enabled;
  const _Btn({
    required this.text,
    required this.background,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(17),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500, color: color)),
        ),
      ),
    );
  }
}
