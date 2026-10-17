// 课表页（第一版）—— 目标只是让「备份 JSON → 能看的周课表」这条链路跑通。
//
// 还没做的（下一步）：点格子改课、单周调整、跨周切换动画、玻璃态细节、
// 待办/计划/设置三个标签页、真实数据库（现在数据来自内存里的 BackupBundle）。

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/dates.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'palette.dart';

class TimetablePage extends StatefulWidget {
  final BackupBundle bundle;

  /// 有「导入备份」入口时传进来（HomeShell 提供；截图测试可以不传）
  final Future<void> Function()? onImport;

  const TimetablePage({super.key, required this.bundle, this.onImport});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  static const double _rowH = 52;
  static const double _axisW = 46;

  late int _week;

  @override
  void initState() {
    super.initState();
    final sem = widget.bundle.semester;
    final w = sem == null ? 1 : weekOfDate(sem, DateTime.now());
    _week = w.clamp(1, sem?.totalWeeks ?? 1);
  }

  Semester get _sem => widget.bundle.semester!;

  int get _clampedWeek => _week.clamp(1, _sem.totalWeeks);

  void _jumpToToday() {
    setState(() => _week = weekOfDate(_sem, DateTime.now()).clamp(1, _sem.totalWeeks));
  }

  @override
  Widget build(BuildContext context) {
    final sessions = computeWeekSessions(
      _sem,
      widget.bundle.courses,
      widget.bundle.rules,
      widget.bundle.overrides,
      widget.bundle.sectionTimes,
      _clampedWeek,
    );
    final byDay = groupByWeekday(sessions);
    final times = [...widget.bundle.sectionTimes]..sort((a, b) => a.section.compareTo(b.section));
    final showWeekend = _sem.showWeekend;

    return Scaffold(
      body: Container(
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
              _Header(
                sem: _sem,
                week: _clampedWeek,
                onPrev: () => setState(() => _week = _clampedWeek - 1),
                onNext: () => setState(() => _week = _clampedWeek + 1),
                onToday: _jumpToToday,
                onImport: widget.onImport,
                dayCount: showWeekend ? 7 : 5,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Column(
                    children: [
                      _WeekdayHeader(sem: _sem, week: _clampedWeek, showWeekend: showWeekend),
                      _Grid(
                        sem: _sem,
                        week: _clampedWeek,
                        times: times,
                        byDay: byDay,
                        showWeekend: showWeekend,
                        rowH: _rowH,
                        axisW: _axisW,
                      ),
                    ],
                  ),
                ),
              ),
              _BottomBar(),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 页头 ----------------

class _Header extends StatelessWidget {
  final Semester sem;
  final int week;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final Future<void> Function()? onImport;
  final int dayCount;

  const _Header({
    required this.sem,
    required this.week,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onImport,
    required this.dayCount,
  });

  @override
  Widget build(BuildContext context) {
    return _Glass(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sem.name,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700, color: inkPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      '${formatDate(dateOfWeekday(sem, week, 1))} — '
                      '${formatDate(dateOfWeekday(sem, week, dayCount))}',
                      style: const TextStyle(fontSize: 11, color: inkTertiary),
                    ),
                  ],
                ),
              ),
              _Pill(icon: Icons.chevron_left, onTap: onPrev),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('第 $week 周',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600, color: inkPrimary)),
              ),
              _Pill(icon: Icons.chevron_right, onTap: onNext),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('本地生成 · 无需联网',
                  style: TextStyle(fontSize: 11, color: goodGreen)),
              const Spacer(),
              GestureDetector(
                onTap: onToday,
                child: const Text('今天',
                    style: TextStyle(fontSize: 12, color: goodGreen)),
              ),
              if (onImport != null) ...[
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: onImport,
                  child: Row(children: const [
                    Icon(Icons.move_to_inbox, size: 14, color: goodGreen),
                    SizedBox(width: 3),
                    Text('导入', style: TextStyle(fontSize: 12, color: goodGreen)),
                  ]),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Pill({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, size: 20, color: inkPrimary),
      ),
    );
  }
}

// ---------------- 星期表头 ----------------

const List<String> _weekdayCn = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class _WeekdayHeader extends StatelessWidget {
  final Semester sem;
  final int week;
  final bool showWeekend;
  const _WeekdayHeader({required this.sem, required this.week, required this.showWeekend});

  @override
  Widget build(BuildContext context) {
    final n = showWeekend ? 7 : 5;
    final today = formatDate(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(left: 46, bottom: 6),
      child: Row(
        children: List.generate(n, (i) {
          final d = dateOfWeekday(sem, week, i + 1);
          final isToday = formatDate(d) == today;
          return Expanded(
            child: Column(
              children: [
                Text(_weekdayCn[i],
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isToday ? accentBlue : inkSecondary)),
                Text('${d.month}/${d.day}',
                    style: TextStyle(fontSize: 10, color: isToday ? accentBlue : inkTertiary)),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ---------------- 网格 ----------------

class _Grid extends StatelessWidget {
  final Semester sem;
  final int week;
  final List<SectionTime> times;
  final List<List<CourseSession>> byDay;
  final bool showWeekend;
  final double rowH;
  final double axisW;

  const _Grid({
    required this.sem,
    required this.week,
    required this.times,
    required this.byDay,
    required this.showWeekend,
    required this.rowH,
    required this.axisW,
  });

  @override
  Widget build(BuildContext context) {
    final days = showWeekend ? 7 : 5;
    final rows = times.length;
    return _Glass(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        height: rows * rowH + 12,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧节次时间轴
            SizedBox(
              width: axisW,
              child: Column(
                children: [
                  for (var i = 0; i < rows; i++)
                    SizedBox(
                      height: rowH,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('${times[i].section}',
                              style: const TextStyle(
                                  fontSize: 11, color: inkSecondary)),
                          Text(minToHHmm(times[i].startMin),
                              style: const TextStyle(fontSize: 9, color: inkTertiary)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            // 7 天
            Expanded(
              child: Row(
                children: List.generate(days, (d) {
                  return Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
                        ),
                      ),
                      child: Stack(
                        children: [
                          // 行分隔线
                          for (var i = 1; i < rows; i++)
                            Positioned(
                              top: i * rowH,
                              left: 0,
                              right: 0,
                              child: Container(
                                  height: 1, color: Colors.white.withValues(alpha: 0.05)),
                            ),
                          // 课程块
                          for (final s in byDay[d])
                            Positioned(
                              top: (s.startSection - 1) * rowH + 2,
                              left: 2,
                              right: 2,
                              height: (s.endSection - s.startSection + 1) * rowH - 4,
                              child: _SessionBlock(s: s),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionBlock extends StatelessWidget {
  final CourseSession s;
  const _SessionBlock({required this.s});

  @override
  Widget build(BuildContext context) {
    final bg = courseColor(s.course.colorIndex);
    return Container(
      padding: const EdgeInsets.fromLTRB(3, 3, 2, 3),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: s.isQuiz
            ? Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1)
            : (s.isExtra ? Border.all(color: goodGreen, width: 1) : null),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.course.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: inkPrimary, height: 1.15)),
          if (s.location.isNotEmpty)
            Text(s.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 8.5, height: 1.15, color: Color(0xFFDCE4F0))),
        ],
      ),
    );
  }
}

// ---------------- 底部导航（暂时只是样子） ----------------

class _BottomBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _Glass(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: const [
          _TabLabel('课表', true),
          _TabLabel('待办', false),
          _TabLabel('计划', false),
          _TabLabel('设置', false),
        ],
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String text;
  final bool active;
  const _TabLabel(this.text, this.active);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            color: active ? inkPrimary : inkTertiary));
  }
}

// ---------------- 玻璃底板 ----------------

class _Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;
  final EdgeInsets padding;
  const _Glass({
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
