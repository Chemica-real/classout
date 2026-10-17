// 单周调整的三个弹窗 —— 鸿蒙端 `pages/Index.ets` 的 SessionSheet / AdjustSheet / ExtraSheet。
//
//   点课表格子里的课  → SessionSheet：换教室（只改这一周）/ 调到哪一天 / 起止节次 /
//                        本周停课（补课则是「取消这次补课」）/ 撤销这节课的调整
//   页头「本周调整 N」 → AdjustSheet：列出本周所有覆盖，逐条撤销
//   页头「＋补课」     → ExtraSheet：选课程 / 星期 / 节次，给这一周临时加一节
//
// 数据都是 `SessionOverride`（kind = cancel / move / room / extra），
// 规则层与覆盖层的合并逻辑在 `domain/timetable.dart`（已与鸿蒙端逐条对齐）。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/dates.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'theme.dart';

/// 复制一份 bundle，只换 overrides
BackupBundle withOverrides(BackupBundle b, List<SessionOverride> list) =>
    BackupBundle(
      app: b.app,
      version: b.version,
      exportedAt: b.exportedAt,
      semesters: b.semesters,
      sectionTimes: b.sectionTimes,
      courses: b.courses,
      rules: b.rules,
      overrides: list,
      todos: b.todos,
      blocks: b.blocks,
      restWindows: b.restWindows,
      templates: b.templates,
      lessons: b.lessons,
    );

int _nextOverrideId(List<SessionOverride> list) =>
    list.fold<int>(0, (m, o) => o.id > m ? o.id : m) + 1;

String _courseShort(List<Course> courses, int id) {
  for (final c in courses) {
    if (c.id == id) return c.shortName.isNotEmpty ? c.shortName : c.name;
  }
  return '课程';
}

/// 鸿蒙端 `overrideText`
String overrideText(BackupBundle b, SessionOverride o) {
  final name = _courseShort(b.courses, o.courseId);
  switch (o.kind) {
    case OverrideKind.cancel:
      return '$name · ${o.date} 停课';
    case OverrideKind.room:
      return '$name · ${o.date} 换到 ${o.newLocation}';
    case OverrideKind.move:
      final loc = o.newLocation.isNotEmpty ? ' · 换到 ${o.newLocation}' : '';
      return '$name · ${o.date} 挪到 ${o.newDate} 第 ${o.newStartSection}-${o.newEndSection} 节$loc';
    default:
      final loc = o.newLocation.isNotEmpty ? ' · 地点 ${o.newLocation}' : '';
      return '$name · ${o.newDate} 补课 第 ${o.newStartSection}-${o.newEndSection} 节$loc';
  }
}

/// 一节课的调整弹窗（点课表格子里的课）
Future<void> showSessionSheet(
  BuildContext context, {
  required BackupBundle bundle,
  required CourseSession session,
  required void Function(BackupBundle next) onChanged,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x730C121C), // rgba(12,18,28,0.45)
    builder: (_) => _SessionSheet(
      bundle: bundle,
      session: session,
      onChanged: onChanged,
    ),
  );
}

class _SessionSheet extends StatefulWidget {
  final BackupBundle bundle;
  final CourseSession session;
  final void Function(BackupBundle next) onChanged;
  const _SessionSheet({
    required this.bundle,
    required this.session,
    required this.onChanged,
  });

  @override
  State<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<_SessionSheet> {
  late final TextEditingController _room =
      TextEditingController(text: widget.session.location);
  late int _moveWeekday = widget.session.weekday;
  late int _moveStart = widget.session.startSection;
  late int _moveEnd = widget.session.endSection;

  CourseSession get s => widget.session;

  List<SessionOverride> get _list => widget.bundle.overrides;

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  /// 这节课自己那条覆盖（补课认 extra，其余认 move/room/cancel）
  SessionOverride? _ownOverride(String kind) {
    for (final o in _list) {
      if (o.courseId != s.course.id) continue;
      if (kind == OverrideKind.extra) {
        if (o.kind == OverrideKind.extra && o.newDate == s.date) return o;
      } else if (o.kind == kind && o.date == s.originDate) {
        return o;
      }
    }
    return null;
  }

  bool get _adjusted => _list.any((o) =>
      o.courseId == s.course.id &&
      (o.date == s.originDate || o.date == s.date || o.newDate == s.date));

  void _commit(List<SessionOverride> next) {
    widget.onChanged(withOverrides(widget.bundle, next));
    Navigator.of(context).pop();
  }

  void _applyRoom() {
    final room = _room.text.trim();
    if (room.isEmpty) return;
    if (s.isExtra) {
      // 补课：直接改它自己那条 extra
      final next = _list.map((o) {
        if (o.kind == OverrideKind.extra &&
            o.courseId == s.course.id &&
            o.newDate == s.date) {
          return _copy(o, newLocation: room);
        }
        return o;
      }).toList();
      _commit(next);
      return;
    }
    final own = _ownOverride(OverrideKind.room);
    if (own != null) {
      _commit(_list
          .map((o) => o.id == own.id ? _copy(o, newLocation: room) : o)
          .toList());
    } else {
      _commit([
        ..._list,
        SessionOverride(
          id: _nextOverrideId(_list),
          courseId: s.course.id,
          date: s.originDate,
          kind: OverrideKind.room,
          newLocation: room,
        ),
      ]);
    }
  }

  void _applyMove() {
    final sem = widget.bundle.semester!;
    final newDate = formatDate(dateOfWeekday(sem, _weekOf(sem), _moveWeekday));
    if (s.isExtra) {
      final next = _list.map((o) {
        if (o.kind == OverrideKind.extra &&
            o.courseId == s.course.id &&
            o.newDate == s.date) {
          return _copy(o,
              newDate: newDate, newStart: _moveStart, newEnd: _moveEnd);
        }
        return o;
      }).toList();
      _commit(next);
      return;
    }
    final own = _ownOverride(OverrideKind.move);
    if (own != null) {
      _commit(_list
          .map((o) => o.id == own.id
              ? _copy(o,
                  newDate: newDate, newStart: _moveStart, newEnd: _moveEnd)
              : o)
          .toList());
      return;
    }
    _commit([
      ..._list,
      SessionOverride(
        id: _nextOverrideId(_list),
        courseId: s.course.id,
        date: s.originDate,
        kind: OverrideKind.move,
        newDate: newDate,
        newStartSection: _moveStart,
        newEndSection: _moveEnd,
      ),
    ]);
  }

  int _weekOf(Semester sem) => weekOfDate(sem, parseDate(s.date));

  void _applyCancel() {
    if (s.isExtra) {
      // 取消这次补课：把那条 extra 删掉
      _commit(_list
          .where((o) => !(o.kind == OverrideKind.extra &&
              o.courseId == s.course.id &&
              o.newDate == s.date))
          .toList());
      return;
    }
    final own = _ownOverride(OverrideKind.cancel);
    if (own != null) {
      _commit(_list);
      return;
    }
    _commit([
      ..._list,
      SessionOverride(
        id: _nextOverrideId(_list),
        courseId: s.course.id,
        date: s.originDate,
        kind: OverrideKind.cancel,
      ),
    ]);
  }

  /// 撤销这节课的全部覆盖（含补课那条）
  void _clearForSel() {
    _commit(_list
        .where((o) => !(o.courseId == s.course.id &&
            (o.date == s.originDate || o.newDate == s.date)))
        .toList());
  }

  @override
  Widget build(BuildContext context) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = names[s.weekday - 1];
    final title =
        s.course.shortName.isNotEmpty ? s.course.shortName : s.course.name;
    return Dialog(
      backgroundColor: Colors.transparent,
      // 鸿蒙：整屏 `.padding(16)` 居中（不是 16/24）
      insetPadding: const EdgeInsets.all(16),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const SizedBox(height: 4),
              Text(
                  '${s.date} 周$wd · 第 ${s.startSection}-${s.endSection} 节'
                  '${s.isQuiz ? ' · 习题课' : ''}${s.isExtra ? ' · 补课' : ''}',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9BA7BD))),
              const SizedBox(height: 2),
              Text(s.location.isNotEmpty ? s.location : '地点待定',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9BA7BD))),
              if (s.date != s.originDate)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('（原定 ${s.originDate}，被调过）',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFE8B25C))),
                ),
              _Label(s.isExtra ? '改这次补课的地点' : '换教室（只改这一周）'),
              Row(
                children: [
                  // 鸿蒙裸 TextInput（胶囊底、高 40）
                  Expanded(
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: TextField(
                        controller: _room,
                        style: const TextStyle(fontSize: 14, color: inkPrimary),
                        cursorColor: accentBlue,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '教学楼 101',
                          hintStyle:
                              TextStyle(fontSize: 14, color: Color(0xFF8B97AC)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SmallAction(text: '换到这儿', onTap: _applyRoom),
                ],
              ),
              _Label(s.isExtra ? '改到哪一天' : '调到哪一天'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    _Chip(
                      text: '周${names[d - 1]}',
                      selected: _moveWeekday == d,
                      onTap: () => setState(() => _moveWeekday = d),
                    ),
                ],
              ),
              const _Label('起 / 止节次'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 1; i <= 12; i++)
                    _Chip(
                      text: '$i',
                      selected: _moveStart == i,
                      onTap: () => setState(() {
                        _moveStart = i;
                        if (_moveEnd < i) _moveEnd = i;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 1; i <= 12; i++)
                    _Chip(
                      text: '$i',
                      selected: _moveEnd == i,
                      onTap: () => setState(
                          () => _moveEnd = i < _moveStart ? _moveStart : i),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _BigAction(
                      text: s.isExtra ? '改到这一天' : '只挪这一天',
                      background: const Color(0x382E6BE6),
                      color: accentBlue,
                      onTap: _applyMove,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _BigAction(
                      text: s.isExtra ? '取消这次补课' : '本周停课',
                      background: const Color(0x2ED64545),
                      color: const Color(0xFFFF8A8A),
                      onTap: _applyCancel,
                    ),
                  ),
                ],
              ),
              if (_adjusted) ...[
                const SizedBox(height: 10),
                _BigAction(
                  text: '撤销这节课的调整',
                  background: const Color(0x33B26B00),
                  color: const Color(0xFFE8B25C),
                  onTap: _clearForSel,
                ),
              ],
              const SizedBox(height: 10),
              _BigAction(
                text: '关闭',
                background: Colors.white.withValues(alpha: 0.14),
                color: const Color(0xFFC3CDDE),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 本周调整列表（页头「本周调整 N」）
Future<void> showAdjustSheet(
  BuildContext context, {
  required BackupBundle bundle,
  required void Function(BackupBundle next) onChanged,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x730C121C), // rgba(12,18,28,0.45)
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final list = bundle.overrides;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Glass(
            sheet: true,
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('本周调整',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                const SizedBox(height: 4),
                Text(
                    '${bundle.semester?.name ?? ''} · 第 ${_currentWeek(bundle)} 周',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF9BA7BD))),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  const Text('本周没有调整。点课表格子里的课就能停课 / 换教室 / 调课。',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8B97AC))),
                for (final o in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(overrideText(bundle, o),
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFFC3CDDE))),
                          ),
                          GestureDetector(
                            onTap: () {
                              onChanged(withOverrides(bundle,
                                  list.where((x) => x.id != o.id).toList()));
                              Navigator.of(ctx).pop();
                            },
                            behavior: HitTestBehavior.opaque,
                            // 鸿蒙：`.padding({ left: 10, right: 4 })`
                            child: const Padding(
                              padding: EdgeInsets.only(left: 10, right: 4),
                              child: Text('撤销',
                                  style: TextStyle(
                                      fontSize: 12, color: dangerRed)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // 鸿蒙 `Button('关闭')` 是 `margin({ top: 12 })`
                const SizedBox(height: 12),
                _BigAction(
                  text: '关闭',
                  background: Colors.white.withValues(alpha: 0.14),
                  color: const Color(0xFFC3CDDE),
                  onTap: () => Navigator.of(ctx).pop(),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

int _currentWeek(BackupBundle b) {
  final sem = b.semester;
  if (sem == null) return 1;
  return weekOfDate(sem, DateTime.now()).clamp(1, sem.totalWeeks);
}

/// 补一节课（页头「＋补课」）
Future<void> showExtraSheet(
  BuildContext context, {
  required BackupBundle bundle,
  required int week,
  required void Function(BackupBundle next) onChanged,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x730C121C), // rgba(12,18,28,0.45)
    builder: (_) =>
        _ExtraSheet(bundle: bundle, week: week, onChanged: onChanged),
  );
}

class _ExtraSheet extends StatefulWidget {
  final BackupBundle bundle;
  final int week;
  final void Function(BackupBundle next) onChanged;
  const _ExtraSheet({
    required this.bundle,
    required this.week,
    required this.onChanged,
  });

  @override
  State<_ExtraSheet> createState() => _ExtraSheetState();
}

class _ExtraSheetState extends State<_ExtraSheet> {
  late int _courseId =
      widget.bundle.courses.isEmpty ? 0 : widget.bundle.courses.first.id;
  int _weekday = 1;
  int _start = 1;
  int _end = 2;

  void _apply() {
    if (_courseId == 0) return;
    final sem = widget.bundle.semester!;
    final date = formatDate(dateOfWeekday(sem, widget.week, _weekday));
    final list = [
      ...widget.bundle.overrides,
      SessionOverride(
        id: _nextOverrideId(widget.bundle.overrides),
        courseId: _courseId,
        date: date,
        kind: OverrideKind.extra,
        newDate: date,
        newStartSection: _start,
        newEndSection: _end < _start ? _start : _end,
      ),
    ];
    widget.onChanged(withOverrides(widget.bundle, list));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return Dialog(
      backgroundColor: Colors.transparent,
      // 鸿蒙：整屏 `.padding(16)` 居中（不是 16/24）
      insetPadding: const EdgeInsets.all(16),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('补一节课',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const SizedBox(height: 4),
              const Text('给某一周临时加一节（调休补课就用这个）',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9BA7BD))),
              const _Label('哪门课'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in widget.bundle.courses)
                    _Chip(
                      text: c.label,
                      selected: _courseId == c.id,
                      onTap: () => setState(() => _courseId = c.id),
                    ),
                ],
              ),
              const _Label('哪一天'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    _Chip(
                      text: '周${names[d - 1]}',
                      selected: _weekday == d,
                      onTap: () => setState(() => _weekday = d),
                    ),
                ],
              ),
              const _Label('起 / 止节次'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 1; i <= 12; i++)
                    _Chip(
                      text: '$i',
                      selected: _start == i,
                      onTap: () => setState(() {
                        _start = i;
                        if (_end < i) _end = i;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 1; i <= 12; i++)
                    _Chip(
                      text: '$i',
                      selected: _end == i,
                      onTap: () =>
                          setState(() => _end = i < _start ? _start : i),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              // 鸿蒙 ExtraSheet：左边「取消」（灰）、右边「加上这节课」（实心蓝白字）
              Row(
                children: [
                  Expanded(
                    child: _BigAction(
                      text: '取消',
                      background: Colors.white.withValues(alpha: 0.14),
                      color: const Color(0xFFC3CDDE),
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _BigAction(
                      text: '加上这节课',
                      background: const Color(0xFF2E6BE6),
                      color: Colors.white,
                      onTap: _apply,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

SessionOverride _copy(
  SessionOverride o, {
  String? newDate,
  int? newStart,
  int? newEnd,
  String? newLocation,
}) =>
    SessionOverride(
      id: o.id,
      courseId: o.courseId,
      date: o.date,
      kind: o.kind,
      newDate: newDate ?? o.newDate,
      newStartSection: newStart ?? o.newStartSection,
      newEndSection: newEnd ?? o.newEndSection,
      newLocation: newLocation ?? o.newLocation,
    );

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.text, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2E6BE6)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : const Color(0xFFC3CDDE))),
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _SmallAction({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child:
            Text(text, style: const TextStyle(fontSize: 13, color: accentBlue)),
      ),
    );
  }
}

class _BigAction extends StatelessWidget {
  final String text;
  final Color background;
  final Color color;
  final VoidCallback onTap;
  const _BigAction({
    required this.text,
    required this.background,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500, color: color)),
      ),
    );
  }
}
