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
      padding:
          const EdgeInsets.fromLTRB(floatSide, floatTop, floatSide, floatGap),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                          style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: inkPrimary)),
                      const SizedBox(height: 2),
                      Text(_range(),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF94A0B5))),
                    ],
                  ),
                ),
                _Tap(
                  onTap: onPrev,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: const Icon(Icons.chevron_left,
                      size: 26, color: accentBlue),
                ),
                Text('第 $week 周',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                _Tap(
                  onTap: onNext,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: const Icon(Icons.chevron_right,
                      size: 26, color: accentBlue),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _TextAction(text: '＋补课', onTap: onExtra),
                if (adjustCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _TextAction(
                      text: '本周调整 $adjustCount',
                      color: const Color(0xFFE8B25C),
                      onTap: onOpenAdjust,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _TextAction(text: '管理课程', onTap: onManage),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child:
                      _TextAction(text: inSem ? '今天' : '回到本周', onTap: onToday),
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
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sync, size: 13, color: goodGreen),
                        SizedBox(width: 3),
                        Text('立即与日历同步',
                            style: TextStyle(fontSize: 12, color: goodGreen)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  final String text;
  final Color color;
  final VoidCallback? onTap;
  const _TextAction({required this.text, this.color = accentBlue, this.onTap});

  @override
  Widget build(BuildContext context) {
    return _Tap(
      onTap: onTap ?? () {},
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
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
