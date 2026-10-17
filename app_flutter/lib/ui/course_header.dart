// 课表页那个三行页头 —— 鸿蒙端 `pages/Index.ets → Header()`。
//
// ⚠️ 它是**三个页面共用**的（课表 / 待办 / 计划都顶着这一条，设置页没有），
// 所以放在外壳层（HomeShell）而不是某个页面里：周次状态归外壳所有，
// 待办/计划页上翻周次改的是"课表那一周"，回到课表页看到的就是同一周。
//
//   ① 学期名 + 日期范围            ‹ 第 N 周 ›
//   ② ＋补课  本周调整 N  管理课程  今天/回到本周
//   ③ 本地生成 · 无需联网          ⟳ 立即与日历同步

import 'package:flutter/material.dart';

import '../domain/timetable.dart';
import '../model/types.dart';
import './app_frame.dart';
import './theme.dart';

class CourseHeader extends StatelessWidget {
  final Semester? sem;
  final int week;
  final int adjustCount;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final Future<void> Function()? onSync;
  final VoidCallback? onExtra;
  final VoidCallback? onManage;
  final VoidCallback? onOpenAdjust;

  const CourseHeader({
    super.key,
    required this.sem,
    required this.week,
    this.adjustCount = 0,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    this.onSync,
    this.onExtra,
    this.onManage,
    this.onOpenAdjust,
  });

  String _range() {
    final s = sem;
    if (s == null) return '';
    final a = dateOfWeekday(s, week, 1);
    final b = dateOfWeekday(s, week, 7);
    return '${a.month}/${a.day} — ${b.month}/${b.day}';
  }

  @override
  Widget build(BuildContext context) {
    final s = sem;
    final inSem = s == null ? false : (week >= 1 && week <= s.totalWeeks);
    return Padding(
      // 鸿蒙页头浮窗只在上方留 `FLOAT_TOP`，下方**不留**：页头与内容之间那条缝
      // 由各页滚动内容的 `topInset + FLOAT_GAP` 提供（两处都留就变成 20vp 了）
      padding: const EdgeInsets.fromLTRB(floatSide, floatTop, floatSide, 0),
      child: Glass(
        // 鸿蒙页头卡：`padding({ left: 16, right: 16, top: 12, bottom: 10 })`
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s?.name ?? '还没有课表',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // ArkUI 默认行高比 Flutter 紧：不写死的话整张页头卡高 10vp，
                          // 和鸿蒙一起截图时下面所有内容都跟着往下错位
                          style: const TextStyle(
                              fontSize: 22,
                              height: 1.15,
                              fontWeight: FontWeight.bold,
                              color: inkPrimary)),
                      const SizedBox(height: 2),
                      Text(_range(),
                          style: const TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: Color(0xFF94A0B5))),
                    ],
                  ),
                ),
                _Tap(
                  onTap: onPrev,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: const Text('‹',
                      style: TextStyle(fontSize: 22, color: accentBlue)),
                ),
                Text('第 $week 周',
                    style: const TextStyle(
                        fontSize: 14,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                _Tap(
                  onTap: onNext,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: const Text('›',
                      style: TextStyle(fontSize: 22, color: accentBlue)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 鸿蒙这一行用的是**每个字自己的 padding**（不是 SizedBox 间隔）：
            // ＋补课 left 8 / right 10、本周调整 right 10、管理课程 right 12、今天 0
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _Tap(
                  onTap: onExtra ?? () {},
                  padding: const EdgeInsets.only(left: 8, right: 10),
                  child: const Text('＋补课',
                      style: TextStyle(fontSize: 12, color: accentBlue)),
                ),
                if (adjustCount > 0)
                  _Tap(
                    onTap: onOpenAdjust ?? () {},
                    padding: const EdgeInsets.only(right: 10),
                    child: Text('本周调整 $adjustCount',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFE8B25C))),
                  ),
                _Tap(
                  onTap: onManage ?? () {},
                  padding: const EdgeInsets.only(right: 12),
                  child: const Text('管理课程',
                      style: TextStyle(fontSize: 12, color: accentBlue)),
                ),
                _Tap(
                  onTap: onToday,
                  padding: EdgeInsets.zero,
                  child: Text(inSem ? '今天' : '回到本周',
                      style: const TextStyle(fontSize: 12, color: accentBlue)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text('本地生成 · 无需联网',
                    style: TextStyle(fontSize: 11, color: goodGreen)),
                const Spacer(),
                if (onSync != null)
                  _Tap(
                    onTap: () => onSync!(),
                    padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
                    // 鸿蒙端是「⟳ 立即与日历同步」一行字，不是图标 + 文字
                    child: const Text('⟳ 立即与日历同步',
                        style: TextStyle(fontSize: 12, color: goodGreen)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tap extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final EdgeInsets padding;
  const _Tap({
    required this.child,
    required this.onTap,
    this.padding = const EdgeInsets.only(right: 10),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(padding: padding, child: child),
    );
  }
}
