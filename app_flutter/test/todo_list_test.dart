// 待办页规则的测试。分组/排序/文案都不进 fixtures（鸿蒙端那几处写在视图与 SQL 里），
// 所以这里用**手写断言 + 与 SQLite 的 ORDER BY 对拍**来钉住。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/sqlite_repo.dart';
import 'package:classout/domain/todo_list.dart';
import 'package:classout/model/types.dart';

Todo _t(int id, {String ddl = '', int priority = 1, String status = 'active',
    String cat = 'homework', int doneAt = 0, String title = ''}) =>
    Todo(id: id, title: title.isEmpty ? 'T$id' : title, ddl: ddl, priority: priority,
        status: status, category: cat, doneAt: doneAt);

void main() {
  group('分组', () {
    test('四段各归各位', () {
      final todos = [
        _t(1, status: 'pending'),
        _t(2, cat: 'exam', ddl: '2026-10-22 09:00', status: 'active'),
        _t(3, status: 'active'),
        _t(4, status: 'done', doneAt: 100),
        _t(5, status: 'archived', doneAt: 50),
      ];
      final s = splitTodos(todos);
      expect(s.pending.map((t) => t.id), [1]);
      expect(s.exams.map((t) => t.id), [2]);
      expect(s.tasks.map((t) => t.id), [3]);
      expect(s.done.map((t) => t.id), [4, 5], reason: '已完成按 doneAt 降序');
    });

    test('考试不会混进「待办」那一段', () {
      final s = splitTodos([
        _t(1, cat: 'exam'),
        _t(2, ddl: '2026-10-19 23:59', cat: 'homework'),
        _t(3, ddl: '2026-10-20 23:59', cat: 'self'),
      ]);
      expect(s.exams.map((t) => t.id), [1]);
      expect(s.tasks.map((t) => t.id), [2, 3], reason: '按 ddl 升序');
    });
  });

  group('排序', () {
    test('无截止的排最后，其余按 ddl → priority → id', () {
      final list = [
        _t(1, ddl: ''),
        _t(2, ddl: '2026-10-20 23:59', priority: 1),
        _t(3, ddl: '2026-10-19 23:59', priority: 1),
        _t(4, ddl: '2026-10-20 23:59', priority: 3),
        _t(5, ddl: '2026-10-20 23:59', priority: 1),
      ];
      expect(sortForList(list).map((t) => t.id), [3, 4, 5, 2, 1]);
    });
  });

  group('文案', () {
    test('ddlText 的三种形态', () {
      expect(ddlText(''), '无截止');
      expect(ddlText('2026-10-20'), contains('10/20'));
      expect(ddlText('2026-10-20 23:59'), contains('10/20 23:59'));
    });

    test('examTimeText：缺时刻说"时间待定"', () {
      expect(examTimeText(_t(1)), '时间待定');
      final t = Todo(id: 2, ddl: '2026-10-22 09:00', endAt: '2026-10-22 11:00');
      expect(examTimeText(t), '10 月 22 日 09:00–11:00');
    });

    test('doneAtText：没有时间戳就说"已完成"', () {
      expect(doneAtText(_t(1)), '已完成');
      final d = DateTime(2026, 10, 14, 12, 3).millisecondsSinceEpoch;
      expect(doneAtText(_t(2, doneAt: d)), '10/14 12:03 完成');
    });
  });

  test('sortForList 与 SQLite 的 ORDER BY 逐条等价', () async {
    final repo = SqliteRepo.withSchema(
        schemaSql: File('assets/schema.sql').readAsStringSync());
    addTearDown(repo.close);
    final demo = BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

    // 造一批覆盖各种组合的待办：空 ddl / 同 ddl 不同 priority / 同 priority 不同 id
    final todos = <Todo>[
      _t(11, ddl: '', priority: 5),
      _t(12, ddl: '2026-10-20 23:59', priority: 1),
      _t(13, ddl: '2026-10-19 23:59', priority: 2),
      _t(14, ddl: '2026-10-20 23:59', priority: 3),
      _t(15, ddl: '2026-10-20 23:59', priority: 3),
      _t(16, ddl: '2026-10-19 23:59', priority: 2),
      _t(17, ddl: '', priority: 1),
    ];
    await repo.replaceAll(BackupBundle(
      app: demo.app, version: demo.version, exportedAt: demo.exportedAt,
      semesters: demo.semesters, sectionTimes: demo.sectionTimes,
      courses: demo.courses, rules: demo.rules, overrides: demo.overrides,
      todos: todos, blocks: const [],
    ));

    // 真正的对拍：SQLite 自己按 ORDER BY 排出来的顺序
    final rs = repo.db.select(
        "SELECT id FROM todo ORDER BY CASE WHEN ddl = '' THEN 1 ELSE 0 END, ddl, priority DESC, id DESC");
    final sqlOrder = rs.map((r) => r['id'] as int).toList();
    expect(sortForList(todos).map((t) => t.id).toList(), sqlOrder,
        reason: 'Dart 比较器必须和 SQL 的 ORDER BY 给出同一个顺序');
  });
}
