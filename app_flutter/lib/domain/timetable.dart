// 课表计算 —— 从 entry/src/main/ets/domain/Timetable.ets 移植。
// 判据：shared/fixtures/timetable.json（含 cancel / move / room / extra 四种覆盖）。

import '../model/types.dart';
import 'dates.dart';
import 'week_mask.dart';

/// 日期落在第几教学周（1 起；学期范围外会返回 <1 或 >总周数）
int weekOfDate(Semester sem, DateTime date) {
  final start = parseDate(sem.startDate);
  return (diffDays(date, start) ~/ 7) + 1;
}

/// 第 [week] 周、星期 [weekday]（1=周一）的日期
DateTime dateOfWeekday(Semester sem, int week, int weekday) {
  final start = parseDate(sem.startDate);
  return addDays(start, (week - 1) * 7 + (weekday - 1));
}

Map<int, Course> buildCourseMap(List<Course> courses) =>
    {for (final c in courses) c.id: c};

Map<int, SectionTime> buildSectionMap(List<SectionTime> times) =>
    {for (final t in times) t.section: t};

/// 节次区间 → [起, 止] 分钟（endSection 缺省时按 +45 分钟兜底）
List<int> sectionMinutes(Map<int, SectionTime> times, int startSection, int endSection) {
  final s = times[startSection];
  final e = times[endSection];
  final startMin = s?.startMin ?? 0;
  final endMin = e?.endMin ?? (startMin + 45);
  return <int>[startMin, endMin];
}

/// 一节课的展示文本，如 '08:00-09:50'（节次时间缺失时返回空串）
String sessionTimeText(Map<int, SectionTime> times, CourseSession s) {
  final st = times[s.startSection];
  final et = times[s.endSection];
  if (st == null || et == null) return '';
  return '${minToHHmm(st.startMin)}-${minToHHmm(et.endMin)}';
}

/// 算出第 [week] 周的全部课时。
/// 规则层（SessionRule）自动排课，覆盖层（SessionOverride）做单周调整：
///   cancel → 该周这节不上；move → 挪到 newDate（可换节次）；
///   room → 只换教室；extra → 额外加一节（补课）。
List<CourseSession> computeWeekSessions(
  Semester sem,
  List<Course> courses,
  List<SessionRule> rules,
  List<SessionOverride> overrides,
  List<SectionTime> times,
  int week,
) {
  final courseMap = buildCourseMap(courses);
  final timeMap = buildSectionMap(times);
  final result = <CourseSession>[];

  final cancelSet = <String>{};
  final moveMap = <String, SessionOverride>{};
  final roomMap = <String, SessionOverride>{};
  for (final o in overrides) {
    final key = '${o.courseId}|${o.date}';
    if (o.kind == OverrideKind.cancel) {
      cancelSet.add(key);
    } else if (o.kind == OverrideKind.move) {
      moveMap[key] = o;
    } else if (o.kind == OverrideKind.room) {
      roomMap[key] = o;
    }
  }

  for (final rule in rules) {
    if (!maskHas(rule.weeksMask, week)) continue;
    final course = courseMap[rule.courseId];
    if (course == null) continue;
    var date = dateOfWeekday(sem, week, rule.weekday);
    final originDate = formatDate(date);
    var startSection = rule.startSection;
    var endSection = rule.endSection;
    var location = rule.location.isNotEmpty ? rule.location : course.location;
    final key = '${rule.courseId}|${formatDate(date)}';

    if (cancelSet.contains(key)) continue;
    final moved = moveMap[key];
    if (moved != null) {
      if (moved.newDate.isNotEmpty) {
        date = parseDate(moved.newDate);
        // 挪出本周就不在这里显示
        if (weekOfDate(sem, date) != week) continue;
      }
      if (moved.newStartSection > 0) {
        startSection = moved.newStartSection;
        endSection =
            moved.newEndSection >= moved.newStartSection ? moved.newEndSection : moved.newStartSection;
      }
      if (moved.newLocation.isNotEmpty) location = moved.newLocation;
    }
    final roomChanged = roomMap[key];
    if (roomChanged != null && roomChanged.newLocation.isNotEmpty) {
      location = roomChanged.newLocation;
    }

    final minutes = sectionMinutes(timeMap, startSection, endSection);
    result.add(CourseSession(
      course: course,
      rule: rule,
      date: formatDate(date),
      originDate: originDate,
      weekday: weekdayOf(date),
      startSection: startSection,
      endSection: endSection,
      startMin: minutes[0],
      endMin: minutes[1],
      location: location,
      isQuiz: rule.isQuiz,
      fromOverride: moved != null,
      isExtra: false,
    ));
  }

  // 补课 / 临时加课
  for (final o in overrides) {
    if (o.kind != OverrideKind.extra || o.newDate.isEmpty) continue;
    final date = parseDate(o.newDate);
    if (weekOfDate(sem, date) != week) continue;
    final course = courseMap[o.courseId];
    if (course == null) continue;
    final startSection = o.newStartSection > 0 ? o.newStartSection : 1;
    final endSection = o.newEndSection >= startSection ? o.newEndSection : startSection;
    final minutes = sectionMinutes(timeMap, startSection, endSection);
    // 老数据里「补课 + 单独一条 room」是两条记录，补课也要认 room 覆盖
    final roomForExtra = roomMap['${o.courseId}|${o.newDate}'];
    var extraLocation = o.newLocation;
    if (roomForExtra != null && roomForExtra.newLocation.isNotEmpty) {
      extraLocation = roomForExtra.newLocation;
    }
    final synthetic = SessionRule(
      id: 0,
      courseId: o.courseId,
      weekday: weekdayOf(date),
      startSection: startSection,
      endSection: endSection,
      weeksMask: '',
      location: extraLocation,
      isQuiz: false,
    );
    result.add(CourseSession(
      course: course,
      rule: synthetic,
      date: formatDate(date),
      originDate: formatDate(date),
      weekday: weekdayOf(date),
      startSection: startSection,
      endSection: endSection,
      startMin: minutes[0],
      endMin: minutes[1],
      location: extraLocation.isNotEmpty ? extraLocation : course.location,
      isQuiz: false,
      fromOverride: true,
      isExtra: true,
    ));
  }

  result.sort((a, b) {
    if (a.weekday != b.weekday) return a.weekday - b.weekday;
    return a.startMin - b.startMin;
  });
  return result;
}

/// 按星期分组（下标 0 = 周一 … 6 = 周日）
List<List<CourseSession>> groupByWeekday(List<CourseSession> sessions) {
  final groups = List<List<CourseSession>>.generate(7, (_) => <CourseSession>[]);
  for (final s in sessions) {
    final idx = s.weekday - 1;
    if (idx >= 0 && idx < 7) groups[idx].add(s);
  }
  return groups;
}

/// 「补课 / 调课」与「另外单独存的一条换教室」合并成一条（鸿蒙端 §27.1 的修法）
class RoomMergePlan {
  final List<SessionOverride> list;
  final List<int> deleteIds;
  const RoomMergePlan(this.list, this.deleteIds);
}

RoomMergePlan mergeRoomOverrides(List<SessionOverride> overrides) {
  final byKey = <String, SessionOverride>{};
  for (final o in overrides) {
    if (o.kind == OverrideKind.move || o.kind == OverrideKind.extra) {
      byKey['${o.courseId}|${o.date}'] = o;
    }
  }
  final list = <SessionOverride>[];
  final deleteIds = <int>[];
  for (final o in overrides) {
    if (o.kind != OverrideKind.room) {
      list.add(o);
      continue;
    }
    final target = byKey['${o.courseId}|${o.date}'];
    if (target == null) {
      list.add(o);
      continue;
    }
    if (o.newLocation.isNotEmpty) target.newLocation = o.newLocation;
    if (o.id > 0) deleteIds.add(o.id);
  }
  return RoomMergePlan(list, deleteIds);
}
