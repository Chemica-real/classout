// 三端等价性测试：Dart 实现必须和鸿蒙端算得**逐位一致**。
//
// 数据来源：shared/fixtures/*.json —— 由 tools/fixtures/gen.js 从**已验证的**鸿蒙端
// 实现生成（那边有 524 条断言 + 真机）。所以这里断言的是"和鸿蒙一致"，
// 不是"绝对正确"；怀疑某条规则错了，先修鸿蒙端再重新生成 fixtures。

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:classout/domain/plan_math.dart';
import 'package:classout/domain/briefing.dart';
import 'package:classout/domain/categories.dart';
import 'package:classout/domain/dates.dart';
import 'package:classout/domain/sync_cadence.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/domain/week_mask.dart';
import 'package:classout/domain/validate.dart';
import 'package:classout/model/types.dart';

List<Map<String, dynamic>> _allCases() {
  final dir = Directory('../shared/fixtures');
  if (!dir.existsSync()) {
    fail('找不到 fixtures 目录：${dir.absolute.path}\n先跑 ./tools/sync-contract.sh');
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) fail('fixtures 目录是空的：${dir.absolute.path}');
  final out = <Map<String, dynamic>>[];
  for (final f in files) {
    final doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    for (final c in (doc['cases'] as List)) {
      final m = Map<String, dynamic>.from(c as Map);
      m['module'] = doc['module'];
      out.add(m);
    }
  }
  return out;
}

CourseSession _sessionFromJson(Object? raw) {
  final j = raw as Map<String, dynamic>;
  final c = Course.fromJson(j['course'] as Map<String, dynamic>);
  final r = SessionRule.fromJson(j['rule'] as Map<String, dynamic>);
  return CourseSession(
    course: c,
    rule: r,
    date: j['date'] as String? ?? '',
    originDate: j['originDate'] as String? ?? '',
    weekday: _n(j['weekday']),
    startSection: _n(j['startSection']),
    endSection: _n(j['endSection']),
    startMin: _n(j['startMin']),
    endMin: _n(j['endMin']),
    location: j['location'] as String? ?? '',
    isQuiz: j['isQuiz'] == true,
    fromOverride: j['fromOverride'] == true,
    isExtra: j['isExtra'] == true,
  );
}

List<Todo> _todos(Object? raw) =>
    (raw as List).map((e) => Todo.fromJson(e as Map<String, dynamic>)).toList();

List<SectionTime> _sectionTimes(Object? raw) =>
    (raw as List).map((e) => SectionTime.fromJson(e as Map<String, dynamic>)).toList();

List<PlanBlock> _blocks(Object? raw) =>
    (raw as List).map((e) => PlanBlock.fromJson(e as Map<String, dynamic>)).toList();

int _n(Object? v) => (v as num).toInt();
num _num(Object? v) => v as num;
bool _b(Object? v) => v as bool;

/// 按 fn 名派发到本端实现，返回值统一成 JSON 可比的形状
Object? _call(String fn, List<dynamic> a) {
  switch (fn) {
    // ---- PlanMath ----
    case 'snap':
      return snap(_n(a[0]));
    case 'normalizeWindow':
      return normalizeWindow(TimeWindow.fromJson(a[0] as Map<String, dynamic>)).toJson();
    case 'alignWindow':
      return alignWindow(TimeWindow.fromJson(a[0] as Map<String, dynamic>)).toJson();
    case 'formatWindow':
      return formatWindow(TimeWindow.fromJson(a[0] as Map<String, dynamic>));
    case 'parseWindow':
      return parseWindow(a[0] as String).toJson();
    case 'normalizeDuration':
      return normalizeDuration(_n(a[0]));
    case 'halveMinutes':
      return halveMinutes(_n(a[0]));
    case 'overlaps':
      return overlaps(_n(a[0]), _n(a[1]), _n(a[2]), _n(a[3]));
    case 'ddlMinuteOf':
      return ddlMinuteOf(a[0] as String);
    case 'ddlGroupsOn':
      return ddlGroupsOn(_todos(a[0]), a[1] as String, _n(a[2]), _n(a[3]))
          .map((g) => {'minute': g.minute, 'todoIds': g.todos.map((t) => t.id).toList()})
          .toList();
    case 'scheduledDays':
      return scheduledDays(_blocks(a[0]), _n(a[1]));
    case 'hasBlockOnDate':
      return hasBlockOnDate(_blocks(a[0]), _n(a[1]), a[2] as String);
    case 'sortPoolTodos':
      return sortPoolTodos(_todos(a[0])).map((t) => t.id).toList();
    case 'selectPoolTodos':
      return selectPoolTodos(_todos(a[0]), _blocks(a[1])).map((t) => t.id).toList();

    // ---- SyncCadence ----
    case 'normalizeSyncInterval':
      return normalizeSyncInterval(_num(a[0]));
    case 'isSyncBoundary':
      return isSyncBoundary(_n(a[0]), _num(a[1]));
    case 'shouldRestartAfterIdle':
      return shouldRestartAfterIdle(_n(a[0]), _num(a[1]));

    // ---- Validate ----
    case 'isStepMultiple':
      return isStepMultiple(_num(a[0]), _num(a[1]));
    case 'normalizeEstimate':
      return normalizeEstimate(_num(a[0]), _b(a[1]));
    case 'migrateEstimate':
      return migrateEstimate(_num(a[0]), _b(a[1]));
    case 'validateEstimate':
      return validateEstimate(_num(a[0]), _b(a[1])).toJson();
    case 'isExamCategory':
      return isExamCategory(a[0] as String);
    case 'resizeEndTo':
      return resizeEndTo(_num(a[0]), _num(a[1]), _num(a[2]));
    case 'pinchEnd':
      return pinchEnd(_num(a[0]), _num(a[1]), _num(a[2]), _num(a[3]));
    case 'pinchDeltaLabel':
      return pinchDeltaLabel(_n(a[0]));
    case 'totalBlockMinutes':
      return totalBlockMinutes(_blocks(a[0]), _n(a[1]));

    // ---- Timetable ----
    case 'weekOfDate':
      return weekOfDate(Semester.fromJson(a[0] as Map<String, dynamic>), parseDate(a[1] as String));
    case 'dateOfWeekday':
      return formatDate(dateOfWeekday(
          Semester.fromJson(a[0] as Map<String, dynamic>), _n(a[1]), _n(a[2])));
    case 'maskHas':
      return maskHas(a[0] as String, _n(a[1]));
    case 'sectionMinutes':
      return sectionMinutes(buildSectionMap(_sectionTimes(a[0])), _n(a[1]), _n(a[2]));
    case 'computeWeekSessions':
      return computeWeekSessions(
        Semester.fromJson(a[0] as Map<String, dynamic>),
        (a[1] as List).map((e) => Course.fromJson(e as Map<String, dynamic>)).toList(),
        (a[2] as List).map((e) => SessionRule.fromJson(e as Map<String, dynamic>)).toList(),
        (a[3] as List).map((e) => SessionOverride.fromJson(e as Map<String, dynamic>)).toList(),
        _sectionTimes(a[4]),
        _n(a[5]),
      ).map((s) => {
            'date': s.date,
            'courseId': s.course.id,
            'weekday': s.weekday,
            'startSection': s.startSection,
            'endSection': s.endSection,
            'startMin': s.startMin,
            'endMin': s.endMin,
            'location': s.location,
            'isQuiz': s.isQuiz ? 1 : 0,
            'isExtra': s.isExtra ? 1 : 0,
            'fromOverride': s.fromOverride ? 1 : 0,
          }).toList();
    case 'mergeRoomOverrides':
      final plan = mergeRoomOverrides(
          (a[0] as List).map((e) => SessionOverride.fromJson(e as Map<String, dynamic>)).toList());
      return {
        'list': plan.list.map((o) => {'id': o.id, 'kind': o.kind, 'newLocation': o.newLocation}).toList(),
        'deleteIds': plan.deleteIds,
      };

    // ---- DateUtil ----
    case 'countdownText':
      return countdownText(parseDate(a[0] as String), parseDate(a[1] as String));
    case 'monthDayText':
      return monthDayText(parseDate(a[0] as String));
    case 'nearestMonday':
      return formatDate(nearestMonday(parseDate(a[0] as String)));
    case 'weekdayOf':
      return weekdayOf(parseDate(a[0] as String));

    // ---- Categories ----
    case 'categoryLabel':
      return categoryLabel(a[0] as String, (a[1] as List).cast<String>());
    case 'builtinLabel':
      return builtinLabel(a[0] as String);
    case 'allCategoryOptions':
      return allCategoryOptions((a[0] as List).cast<String>()).map((o) => o.toJson()).toList();
    case 'validateCategoryName':
      return validateCategoryName(a[0] as String, (a[1] as List).cast<String>()).toJson();
    case 'addCustomCategory':
      return addCustomCategory((a[0] as List).cast<String>(), a[1] as String);
    case 'removeCustomCategory':
      return removeCustomCategory((a[0] as List).cast<String>(), a[1] as String);
    case 'parseCustomCategories':
      return parseCustomCategories(a[0] as String);
    case 'serializeCustomCategories':
      return serializeCustomCategories((a[0] as List).cast<String>());

    case 'findFreeSlot':
      return findFreeSlot(
        TimeAxis(TimeWindow.fromJson(a[0] as Map<String, dynamic>)),
        (a[1] as List).map((e) => (e as List).map(_n).toList()).toList(),
        (a[2] as List).map((e) => (e as List).map(_n).toList()).toList(),
        _n(a[3]),
        _n(a[4]),
      );
    case 'sortBlocksByTime':
      return sortBlocksByTime(_blocks(a[0])).map((b) => b.id).toList();

    case 'buildBriefing':
      return buildBriefing(
        a[0] as String,
        (a[1] as List).map(_sessionFromJson).toList(),
        _todos(a[2]),
      );

    case 'edgeScrollDirection':
      return edgeScrollDirection(_n(a[0]), _n(a[1]), _n(a[2]), _n(a[3]));
    case 'edgeScrollDepth':
      return edgeScrollDepth(_n(a[0]), _n(a[1]), _n(a[2]), _n(a[3]));
    case 'edgeScrollStep':
      return edgeScrollStep(_n(a[0]), _n(a[1]), _n(a[2]));
    case 'dragOffsetWithScroll':
      return dragOffsetWithScroll(_n(a[0]), _n(a[1]));

    default:
      throw StateError('fixture 里有本端还没实现的函数：$fn');
  }
}

/// 深比较（Map/List/num/String/bool 递归；不引第三方包）
bool _deepEq(Object? x, Object? y) {
  if (x is Map && y is Map) {
    if (x.length != y.length) return false;
    for (final k in x.keys) {
      if (!y.containsKey(k) || !_deepEq(x[k], y[k])) return false;
    }
    return true;
  }
  if (x is List && y is List) {
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (!_deepEq(x[i], y[i])) return false;
    }
    return true;
  }
  if (x is num && y is num) return x == y;
  return x == y;
}

void main() {
  final cases = _allCases();

  test('fixtures 非空', () {
    expect(cases, isNotEmpty);
  });

  group('与鸿蒙端逐条一致', () {
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final fn = c['fn'] as String;
      final mod = c['module'];
      final args = c['args'] as List<dynamic>;
      final brief = jsonEncode(args);
      test('#$i [$mod] $fn(${brief.length > 50 ? '${brief.substring(0, 50)}…' : brief})', () {
        final got = _call(fn, args);
        if (!_deepEq(got, c['expect'])) {
          fail('不一致：\n  参数 = $brief\n  鸿蒙 = ${jsonEncode(c['expect'])}\n  本端 = ${jsonEncode(got)}');
        }
      });
    }
  });

  group('TimeAxis 不变式（鸿蒙端 test.ts 也在守这条）', () {
    for (final w in [
      const TimeWindow(7 * 60, 24 * 60),
      const TimeWindow(8 * 60 + 30, 22 * 60 + 30),
      const TimeWindow(0, 24 * 60),
      const TimeWindow(9 * 60, 10 * 60),
    ]) {
      test('${w.startMin}-${w.endMin}', () {
        final axis = TimeAxis(w);
        // 最后一格可以是"不足 1 小时"的尾段，但刻度行必须铺满
        expect((axis.marks.length - 1) * hourMin < axis.height(), isTrue);
        expect(axis.height() <= axis.marks.length * hourMin, isTrue);
        expect(axis.marks.first, axis.startMin);
        expect(axis.endMin - axis.startMin >= windowMinSpan, isTrue);
      });
    }
  });
}
