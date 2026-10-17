// 自动生成待办的**黑名单**（鸿蒙 `todo_blacklist`）：删掉的那条不再被补生成。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/blacklist.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/domain/todo_generator.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('kv 解析：空 / 坏数据 / 正常数组', () {
    expect(blacklistFromRaw(''), isEmpty);
    expect(blacklistFromRaw('不是 JSON'), isEmpty);
    expect(blacklistFromRaw('["a|b|c","d|e|f"]'),
        {'a|b|c', 'd|e|f'});
    expect(blacklistFromRaw('["a|b|c","",""]'), {'a|b|c'});
  });

  test('addToBlacklist 幂等且只写一次', () async {
    final repo = MemoryRepo(_demo());
    final a = await addToBlacklist(repo, ['k1']);
    expect(a, {'k1'});
    final b = await addToBlacklist(repo, ['k1', 'k2']);
    expect(b, {'k1', 'k2'});
    expect(blacklistFromRaw(await repo.getKv(todoBlacklistKv) ?? ''), {'k1', 'k2'});
  });

  testWidgets('删掉一条自动生成的待办 → 去重键进黑名单（不再补生成）',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 库里有一条"模板生成"的待确认待办
    final gen = Todo(
      id: 99,
      title: '自动生成的作业',
      courseId: 4,
      ddl: '2026-10-16 23:59',
      status: TodoStatus.pending,
      source: 'template',
      generationKey: '4|2026-10-16|1',
    );
    final repo = MemoryRepo(_demo().copyWith(todos: [gen]));
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();

    // 待办页 → 删除 → 确认删除
    await tester.tap(find.text('待办').last);
    await tester.pumpAndSettle();
    expect(find.text('自动生成的作业'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    final keys = blacklistFromRaw(await repo.getKv(todoBlacklistKv) ?? '');
    expect(keys, contains('4|2026-10-16|1'));

    // 再跑一次补生成：这条不该回来（同一去重键）
    final b = (await repo.load())!;
    final out = generateMissedTodos(
      sem: b.semester!,
      courses: b.courses,
      rules: b.rules,
      overrides: b.overrides,
      times: b.sectionTimes,
      templates: b.templates,
      todos: b.todos,
      lastGenDate: '2026-10-16',
      now: DateTime(2026, 10, 16, 22, 0),
      blacklist: keys,
    );
    expect(out.created.any((t) => t.generationKey == '4|2026-10-16|1'), isFalse);
  });
}
