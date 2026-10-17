// 课表页 —— 逐像素照搬鸿蒙端 pages/Index.ets 的课表页：
//
//   页头（三行）              ：学期名 + 日期范围 / ‹第 N 周› / ＋补课·管理课程·今天 / 同步
//   周条（跟着滚，不做浮窗）  ：周X + 日期，今天高亮
//   网格（不给玻璃：要读准时间）：左时间轴（顶对齐）+ 7 列，行底 1px 白 0.12，今天列白 0.10
//   课程块                    ：简称 / 教室 / 教师（块够高才显示老师），考试用白色虚线框
//
// 数值全部来自 theme.dart（= 鸿蒙端 Glass.ets / Index.ets 的原始常量）。

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/dates.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'theme.dart';

/// 鸿蒙端 Index.ets：SECTION_H = 52、FLEX_SECTION_H = 36、TT_AXIS_W = 38、TT_GRID_PAD = 4
const double sectionH = 52;
const double flexSectionH = 36;
const double axisW = 38;
const double gridPad = 4;

const Color _axisSection = Color(0xFFCBD6E8);
const Color _axisTime = Color(0xFFA9B5C9);
const Color _weekdayText = Color(0xFFA9B5C9);
const Color _blockTitle = Color(0xFFEAF0FA);
const Color _blockSub = Color(0xFFCBD6E8);

class TimetablePage extends StatefulWidget {
  final BackupBundle bundle;

  /// 当前周次（外壳 HomeShell 拥有；页头也在外壳上）
  final int week;

  /// 点课程块（鸿蒙端会打开「这节课」属性窗：停课/换教室/调课/补课/撤销）
  final void Function(CourseSession s)? onOpenSession;

  /// 页头浮窗的高度：内容要从它下面滑过，所以顶部留出同样的空
  final double topInset;

  /// 时钟（测试与截图注入固定时间，避免「今天」随真实日期漂移）
  final DateTime? now;

  const TimetablePage({
    super.key,
    required this.bundle,
    required this.week,
    this.onOpenSession,
    this.now,
    this.topInset = 0,
  });

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  DateTime get _now => widget.now ?? DateTime.now();

  Semester get _sem => widget.bundle.semester!;

  int get _week => widget.week.clamp(1, _sem.totalWeeks);

  @override
  Widget build(BuildContext context) {
    final week = _week;
    final sessions = computeWeekSessions(
      _sem,
      widget.bundle.courses,
      widget.bundle.rules,
      widget.bundle.overrides,
      widget.bundle.sectionTimes,
      week,
    );
    final byDay = groupByWeekday(sessions);
    final times = [...widget.bundle.sectionTimes]
      ..sort((a, b) => a.section.compareTo(b.section));
    final showWeekend = _sem.showWeekend;

    return SingleChildScrollView(
      // 顶部让出悬浮页头、底部让出悬浮导航栏（内容会从它们下面滑过）。
      // ⚠️ 顶部还要 `+ FLOAT_GAP`：鸿蒙 Index 的课表滚动内容是
      // `.padding({ top: topInset() + FLOAT_GAP, bottom: bottomInset() })` ——
      // 页头浮窗和下面那条周条之间要留一条空行（01-timetable.jpg 里看得见）。
      // 底部是 `bottomInset`（导航栏高 + 一条缝），不是 `tabBarInset`（那还多一条缝，
      // 是给**浮在导航栏上方**的元素用的）
      padding: EdgeInsets.only(
          top: widget.topInset + floatGap, bottom: floatGap + hTabbar),
      child: Column(
        children: [
          _WeekdayHeader(
              sem: _sem, week: week, now: _now, showWeekend: showWeekend),
          _Grid(
            times: times,
            byDay: byDay,
            now: _now,
            week: week,
            sem: _sem,
            showWeekend: showWeekend,
            onOpenSession: widget.onOpenSession,
          ),
        ],
      ),
    );
  }
}

// ---------------- 周条 ----------------

/// 鸿蒙端 WEEKDAY_CN
const List<String> weekdayCnList = ['一', '二', '三', '四', '五', '六', '日'];

class _WeekdayHeader extends StatelessWidget {
  final Semester sem;
  final int week;
  final DateTime now;
  final bool showWeekend;

  const _WeekdayHeader({
    required this.sem,
    required this.week,
    required this.now,
    required this.showWeekend,
  });

  @override
  Widget build(BuildContext context) {
    final days = showWeekend ? 7 : 5;
    final todayWeek = weekOfDate(sem, now);
    final todayWd = weekdayOf(now);
    // ⚠️ 周条**不是悬浮浮窗**（用户 2026-10-14 明确："周一到周日不要做成悬浮窗了，会出去"）：
    // 它必须和网格 7 列严格对齐，悬浮面板要留边、再被外层 padding 缩一次，列宽就越偏越远。
    // 鸿蒙 `WeekHeaderRow`：全宽 `.glassPanel()`（模糊 + 面板底 + 1px 描边、**没有圆角**）+
    // `TT_GRID_PAD`(4) 左右、6 上下，和网格用同一套几何。
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
        child: Container(
          padding: const EdgeInsets.fromLTRB(gridPad, 6, gridPad, 6),
          decoration: BoxDecoration(
            color: glassTintPanel,
            border: Border.all(color: glassEdgeStrong),
          ),
          child: Row(
          children: [
            const SizedBox(width: axisW),
            for (var d = 1; d <= days; d++)
              Expanded(
                child: Builder(builder: (_) {
                  final isToday = todayWeek == week && todayWd == d;
                  final dt = dateOfWeekday(sem, week, d);
                  return Column(
                    children: [
                      Text('周${weekdayCnList[d - 1]}',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            color: isToday ? accentBlue : _weekdayText,
                            fontWeight:
                                isToday ? FontWeight.bold : FontWeight.normal,
                          )),
                      const SizedBox(height: 1),
                      Text('${dt.month}/${dt.day}',
                          style: TextStyle(
                              fontSize: 10,
                              height: 1.2,
                              color: isToday ? accentBlue : inkTertiary)),
                    ],
                  );
                }),
              ),
          ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 网格 ----------------

double _sectionH(SectionTime st) => st.flexible ? flexSectionH : sectionH;

double _offsetOf(List<SectionTime> times, int section) {
  var y = 0.0;
  for (final st in times) {
    if (st.section >= section) break;
    y += _sectionH(st);
  }
  return y;
}

double _blockHeight(List<SectionTime> times, int start, int end) {
  var h = 0.0;
  for (final st in times) {
    if (st.section >= start && st.section <= end) h += _sectionH(st);
  }
  return h == 0 ? sectionH : h;
}

class _Grid extends StatelessWidget {
  final List<SectionTime> times;
  final List<List<CourseSession>> byDay;
  final DateTime now;
  final int week;
  final Semester sem;
  final bool showWeekend;
  final void Function(CourseSession s)? onOpenSession;

  const _Grid({
    required this.times,
    required this.byDay,
    required this.now,
    required this.week,
    required this.sem,
    required this.showWeekend,
    required this.onOpenSession,
  });

  @override
  Widget build(BuildContext context) {
    final days = showWeekend ? 7 : 5;
    final totalH = times.fold<double>(0, (a, st) => a + _sectionH(st));
    final todayWeek = weekOfDate(sem, now);
    final todayWd = weekdayOf(now);

    return Padding(
      padding: const EdgeInsets.fromLTRB(gridPad, 0, gridPad, floatGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间轴：节次 + 开始时间，**顶对齐**（鸿蒙端 padding top 2）
          SizedBox(
            width: axisW,
            height: totalH,
            child: Column(
              children: [
                for (final st in times)
                  SizedBox(
                    height: _sectionH(st),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Column(
                        children: [
                          // 窄屏 + 大字号时时间和节次都会被折行，把 36 高的机动节撑破；
                          // 一律等比缩小、绝不折行（鸿蒙端 Text 默认单行）
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('${st.section}',
                                maxLines: 1,
                                softWrap: false,
                                style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.0,
                                    color: _axisSection)),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(minToHHmm(st.startMin),
                                maxLines: 1,
                                softWrap: false,
                                style: const TextStyle(
                                    fontSize: 9,
                                    height: 1.0,
                                    color: _axisTime)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (var d = 1; d <= days; d++)
            Expanded(
              child: Container(
                height: totalH,
                color: (todayWeek == week && todayWd == d)
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.transparent,
                child: Stack(
                  children: [
                    // 每一节一行，底边一条 1px 白 0.12（鸿蒙端：只有横线，没有竖线）
                    Column(
                      children: [
                        for (final st in times)
                          Container(
                            height: _sectionH(st),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                    color:
                                        Colors.white.withValues(alpha: 0.12)),
                              ),
                            ),
                          ),
                      ],
                    ),
                    for (final s in (d - 1 < byDay.length
                        ? byDay[d - 1]
                        : const <CourseSession>[]))
                      Positioned(
                        top: _offsetOf(times, s.startSection),
                        // 鸿蒙 SessionBlock 外层 `.padding({ left: 1.5, right: 1.5 })`
                        left: 1.5,
                        right: 1.5,
                        height:
                            _blockHeight(times, s.startSection, s.endSection),
                        child: _SessionBlock(
                          s: s,
                          height:
                              _blockHeight(times, s.startSection, s.endSection),
                          onTap: onOpenSession == null
                              ? null
                              : () => onOpenSession!(s),
                        ),
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

class _SessionBlock extends StatelessWidget {
  final CourseSession s;
  final double height;
  final VoidCallback? onTap;

  const _SessionBlock({required this.s, required this.height, this.onTap});

  @override
  Widget build(BuildContext context) {
    final short =
        s.course.shortName.isNotEmpty ? s.course.shortName : s.course.name;
    final showTeacher = s.course.teacher.isNotEmpty && height > sectionH + 10;
    final body = Container(
      padding: const EdgeInsets.fromLTRB(4, 2, 3, 2),
      decoration: BoxDecoration(
        color: courseColor(s.course.colorIndex),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(short,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: _blockTitle)),
          if (s.location.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(s.location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 8.5 号：真机对比发现 9 号时「二教407」会被截成「二教4…」
                  style: const TextStyle(fontSize: 8.5, color: _blockSub)),
            ),
          if (showTeacher)
            Text(s.course.teacher,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: _blockSub)),
        ],
      ),
    );
    final child = s.isQuiz
        ? CustomPaint(
            foregroundPainter: const _DashedRRectPainter(
                color: Colors.white, radius: 6, strokeWidth: 1.5),
            child: body,
          )
        : body;
    if (onTap == null) return child;
    return GestureDetector(
        onTap: onTap, behavior: HitTestBehavior.opaque, child: child);
  }
}

/// 白虚线圆角框（鸿蒙端：考试 = 白色 1.5 虚线边框）
class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2, size.width - strokeWidth,
          size.height - strokeWidth),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 5.0;
    const gap = 3.5;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
            metric.extractPath(
                d, d + gap < metric.length ? d + dash : metric.length),
            paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth;
}
