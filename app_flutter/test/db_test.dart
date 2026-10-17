// 数据层测试：真 SQLite（这台 Linux 上跑的就是 iOS/Android 用的同一个引擎）。
//
// 重点验三件事：
//  1. assets/schema.sql 与 ../shared/schema.sql **一字不差**（防止两边漂移）
//  2. 导入 → 读回来**无损**（课表算出来的结果和导入前完全一致）
//  3. 重复导入是「整份替换」，不会翻倍

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/data/sqlite_repo.dart';
import 'package:classout/data/sqlite_open.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/model/types.dart';

String _schemaText() => File('assets/schema.sql').readAsStringSync();

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

/// 课表算出来的内容（用来比较"导入前后/两种仓库"是否等价）
List<Map<String, Object?>> _weekFingerprint(BackupBundle b, int week) {
  final sem = b.semester!;
  final list = computeWeekSessions(
      sem, b.courses, b.rules, b.overrides, b.sectionTimes, week);
  return list
      .map((s) => <String, Object?>{
            'date': s.date,
            'courseId': s.course.id,
            'weekday': s.weekday,
            'sec': '${s.startSection}-${s.endSection}',
            'min': '${s.startMin}-${s.endMin}',
            'loc': s.location,
            'quiz': s.isQuiz,
            'extra': s.isExtra,
          })
      .toList();
}

void main() {
  test('assets/schema.sql 与 shared/schema.sql 一字不差', () {
    final shared = File('../shared/schema.sql').readAsStringSync();
    expect(_schemaText(), shared,
        reason: '改了 shared/schema.sql 就要同步复制到 app_flutter/assets/');
  });

  test('schema 能被拆成可执行语句', () {
    final stmts = splitSchema(_schemaText());
    expect(stmts.length, greaterThanOrEqualTo(12));
    expect(stmts.every((s) => s.toUpperCase().startsWith('CREATE')), isTrue);
  });

  test('导入 demo 备份 → 读回来 → 课表完全一致', () async {
    final repo = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(repo.close);
    final demo = _demo();

    await repo.replaceAll(demo);
    final loaded = await repo.load();
    expect(loaded, isNotNull);

    expect(loaded!.semesters.length, demo.semesters.length);
    expect(loaded.courses.length, demo.courses.length);
    expect(loaded.sectionTimes.length, demo.sectionTimes.length);
    expect(loaded.rules.length, demo.rules.length);
    expect(loaded.courses.map((c) => c.label), demo.courses.map((c) => c.label));
    // 关键字段没被 snake_case 坑掉
    final r0 = loaded.rules.first;
    expect(r0.courseId, isNot(0));
    expect(r0.weeksMask, isNotEmpty);
    expect(r0.startSection, isNot(0));

    for (final week in [1, 2, 3, 10, 16]) {
      expect(_weekFingerprint(loaded, week), _weekFingerprint(demo, week),
          reason: '第 $week 周的课表和导入前不一致');
    }
  });

  test('重复导入是整份替换，不会翻倍', () async {
    final repo = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(repo.close);
    final demo = _demo();
    await repo.replaceAll(demo);
    await repo.replaceAll(demo);
    final again = (await repo.load())!;
    expect(again.courses.length, demo.courses.length);
    expect(again.rules.length, demo.rules.length);
  });

  test('待办的全部字段都能往返（导入不能悄悄丢列）', () async {
    final repo = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(repo.close);
    final demo = _demo();
    final todo = Todo(
      id: 7,
      title: '作业甲',
      courseId: 3,
      category: TodoCategory.homework,
      priority: 2,
      ddl: '2026-10-18 23:59',
      endAt: '2026-10-18 21:00',
      estimateMin: 45,
      status: TodoStatus.active,
      note: '记得写过程',
      source: 'template',
      generationKey: 'course3|2026-10-18',
      submitChannel: '学在北大',
      repeatRule: 'weekly',
      photos: 'a.jpg;b.jpg',
      createdAt: 1700000000000,
      confirmedAt: 1700000001000,
      doneAt: 0,
    );
    await repo.replaceAll(BackupBundle(
      app: demo.app,
      version: demo.version,
      exportedAt: demo.exportedAt,
      semesters: demo.semesters,
      sectionTimes: demo.sectionTimes,
      courses: demo.courses,
      rules: demo.rules,
      overrides: demo.overrides,
      todos: [todo],
      blocks: const [],
    ));
    final back = (await repo.load())!.todos.single;
    expect(back.id, todo.id);
    expect(back.title, todo.title);
    expect(back.courseId, todo.courseId);
    expect(back.category, todo.category);
    expect(back.priority, todo.priority);
    expect(back.ddl, todo.ddl);
    expect(back.endAt, todo.endAt);
    expect(back.estimateMin, todo.estimateMin);
    expect(back.status, todo.status);
    expect(back.note, todo.note);
    expect(back.source, todo.source);
    expect(back.generationKey, todo.generationKey);
    expect(back.submitChannel, todo.submitChannel);
    expect(back.repeatRule, todo.repeatRule);
    expect(back.photos, todo.photos);
    expect(back.createdAt, todo.createdAt);
    expect(back.confirmedAt, todo.confirmedAt);
    expect(back.doneAt, todo.doneAt);
  });

  test('内存仓库与 SQLite 仓库对同一份数据给出同样的课表', () async {
    final demo = _demo();
    final mem = MemoryRepo(demo);
    final sql = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(sql.close);
    await sql.replaceAll(demo);
    final a = (await mem.load())!;
    final b = (await sql.load())!;
    for (final week in [1, 2, 5, 16]) {
      expect(_weekFingerprint(a, week), _weekFingerprint(b, week));
    }
  });

  test('不可排时段（restWindows）能往返', () async {
    final repo = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(repo.close);
    final demo = _demo();
    final windows = [
      RestWindow(id: 0, weekday: 0, startMin: 12 * 60, endMin: 13 * 60, label: '午休'),
      RestWindow(id: 0, weekday: 0, startMin: 23 * 60 + 30, endMin: 24 * 60, label: '睡觉'),
    ];
    await repo.replaceAll(BackupBundle(
      app: demo.app, version: demo.version, exportedAt: demo.exportedAt,
      semesters: demo.semesters, sectionTimes: demo.sectionTimes, courses: demo.courses,
      rules: demo.rules, overrides: demo.overrides, todos: demo.todos,
      blocks: demo.blocks, restWindows: windows,
    ));
    final back = (await repo.load())!.restWindows;
    expect(back.length, 2);
    expect(back.map((w) => w.label), ['午休', '睡觉']);
    expect(back.first.startMin, 12 * 60);
  });

  test('kv 设置项能读写、能覆盖', () async {
    final repo = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(repo.close);
    expect(await repo.getKv('sync_interval_min'), isNull);
    await repo.setKv('sync_interval_min', '15');
    expect(await repo.getKv('sync_interval_min'), '15');
    await repo.setKv('sync_interval_min', '30');
    expect(await repo.getKv('sync_interval_min'), '30', reason: '要覆盖而不是插入两行');
    await repo.setKv('motto', '离线课表');
    expect(await repo.getKv('motto'), '离线课表');
  });

  test('空库返回 null', () async {
    final repo = SqliteRepo.withSchema(schemaSql: _schemaText());
    addTearDown(repo.close);
    expect(await repo.load(), isNull);
  });

  test('备份格式不对要抛错，别静默当成空数据', () {
    expect(() => BackupBundle.decode('{"app":"NotClassOut","version":1}'),
        throwsA(isA<FormatException>()));
    expect(() => BackupBundle.decode('{"app":"ClassOUT","version":9}'),
        throwsA(isA<FormatException>()));
  });
}
