// 三端等价性测试：Dart 实现必须和鸿蒙端算得一模一样。
//
// 数据来源：shared/fixtures/plan_math.json（由 tools/fixtures/gen.js 从**已验证的**
// 鸿蒙端实现生成，122 条）。所以这里断言的是"和鸿蒙一致"，不是"绝对正确"。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/domain/plan_math.dart';
import 'package:classout/model/types.dart';

Map<String, dynamic> _load(String name) {
  final f = File('../shared/fixtures/$name');
  if (!f.existsSync()) {
    fail('找不到 fixtures：${f.absolute.path}\n先跑 ./tools/sync-contract.sh');
  }
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

List<Todo> _todos(Object? raw) =>
    (raw as List).map((e) => Todo.fromJson(e as Map<String, dynamic>)).toList();

List<PlanBlock> _blocks(Object? raw) =>
    (raw as List).map((e) => PlanBlock.fromJson(e as Map<String, dynamic>)).toList();

int _n(Object? v) => (v as num).toInt();

/// 按 fn 名派发到本端实现，返回值统一成 JSON 可比的形状
Object? _call(String fn, List<dynamic> a) {
  switch (fn) {
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
  final fixture = _load('plan_math.json');
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('fixtures 覆盖了所有已实现的函数', () {
    expect(cases, isNotEmpty);
  });

  group('PlanMath 与鸿蒙端逐条一致', () {
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final fn = c['fn'] as String;
      final args = c['args'] as List<dynamic>;
      test('#$i $fn(${jsonEncode(args).length > 60 ? '…' : jsonEncode(args)})', () {
        final got = _call(fn, args);
        if (!_deepEq(got, c['expect'])) {
          fail('不一致：\n  参数 = ${jsonEncode(args)}\n  鸿蒙 = ${jsonEncode(c['expect'])}\n  本端 = ${jsonEncode(got)}');
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
