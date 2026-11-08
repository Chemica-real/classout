// Android 可选的“写入系统日历”通道。
//
// 默认关闭；开启时会先申请 READ_CALENDAR / WRITE_CALENDAR，把 ClassOUT
// 生成的课程与截止事件写进系统日历。所有事件的 DESCRIPTION 以 ClassOUT
// 开头，关闭时只删除这些带标记的事件，不碰用户自己日历里的内容。

import 'package:flutter/services.dart';

import '../domain/dates.dart' show parseDate;
import '../domain/timetable.dart' show computeWeekSessions, weekOfDate;
import '../model/types.dart';
import 'backup.dart';

class CalendarEvent {
  final String title;
  final String description;
  final int startMs;
  final int endMs;

  const CalendarEvent({
    required this.title,
    required this.description,
    required this.startMs,
    required this.endMs,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'startMs': startMs,
        'endMs': endMs,
      };
}

class CalendarSync {
  static const MethodChannel _channel = MethodChannel('classout/calendar');

  static Future<bool> ensurePermission() async {
    try {
      final ok = await _channel.invokeMethod<bool>('requestPermission');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<int> sync(List<CalendarEvent> events) async {
    try {
      final n = await _channel.invokeMethod<int>('sync', {
        'events': events.map((e) => e.toJson()).toList(),
      });
      return n ?? 0;
    } catch (_) {
      return -1;
    }
  }

  static Future<int> clear() async {
    try {
      final n = await _channel.invokeMethod<int>('clear');
      return n ?? 0;
    } catch (_) {
      return -1;
    }
  }
}

/// 从完整备份生成未来 4 周的课程事件 + 未完成待办的截止事件。
/// 不写计划块，避免和待办截止事件重复；虚拟课程的计划块若已排，会以块的形式在
/// 鸿蒙端同步，这里先保持“课程 + 截止”两条主线。
List<CalendarEvent> buildCalendarEvents(BackupBundle b, DateTime now) {
  final out = <CalendarEvent>[];
  final sem = b.semester;
  if (sem == null) return out;
  final start = DateTime(now.year, now.month, now.day);
  final end = start.add(const Duration(days: 28));
  final week = weekOfDate(sem, now).clamp(1, sem.totalWeeks);
  final lastWeek = (week + 3).clamp(week, sem.totalWeeks);
  final seen = <String>{};

  for (var w = week; w <= lastWeek; w++) {
    final sessions = computeWeekSessions(
        sem, b.courses, b.rules, b.overrides, b.sectionTimes, w);
    for (final s in sessions) {
      final d = parseDate(s.date);
      final at = DateTime(d.year, d.month, d.day)
          .add(Duration(minutes: s.startMin));
      if (at.isBefore(start) || at.isAfter(end)) continue;
      final key = '课|${s.date}|${s.startMin}|${s.course.id}';
      if (!seen.add(key)) continue;
      out.add(CalendarEvent(
        title: s.isQuiz ? '${s.course.name}（小测）' : s.course.name,
        description: 'ClassOUT · 上课${s.location.isEmpty ? '' : ' · ${s.location}'}',
        startMs: at.millisecondsSinceEpoch,
        endMs: DateTime(d.year, d.month, d.day)
            .add(Duration(minutes: s.endMin))
            .millisecondsSinceEpoch,
      ));
    }
  }

  for (final t in b.todos) {
    if (t.status == TodoStatus.done || t.ddl.length < 16) continue;
    final d = DateTime.tryParse(t.ddl.replaceFirst(' ', 'T'));
    if (d == null || d.isBefore(start) || d.isAfter(end)) continue;
    final key = '截止|${t.id}|${t.ddl}';
    if (!seen.add(key)) continue;
    out.add(CalendarEvent(
      title: '截止：${t.title}',
      description: 'ClassOUT · 待办截止',
      startMs: d.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch,
      endMs: d.millisecondsSinceEpoch,
    ));
  }
  return out;
}
