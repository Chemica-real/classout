// 备注展开状态（鸿蒙端 NOTE_EXPANDED_*）的持久化 + 两个编辑窗共用同一个开关。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/note_pref.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/ui/todo_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('kv 往返：默认收起，存 1 后读回 true', () async {
    final repo = MemoryRepo(_demo());
    expect(await loadNoteExpanded(repo), isFalse);
    noteExpanded = false;
    await saveNoteExpanded(repo, true);
    expect(noteExpanded, isTrue);
    expect(await repo.getKv(noteExpandedKv), '1');
    expect(await loadNoteExpanded(repo), isTrue);
    await saveNoteExpanded(repo, false);
    expect(await repo.getKv(noteExpandedKv), '0');
  });

  testWidgets('待办编辑窗：点「展开」把开关写回并传给外壳', (tester) async {
    noteExpanded = false;
    bool? seen;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TodoPage(
          bundle: _demo(),
          onChanged: (_) {},
          onNotePref: (v) => seen = v,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 新建待办'));
    await tester.pumpAndSettle();

    expect(find.text('展开 ▾'), findsOneWidget);
    await tester.tap(find.text('展开 ▾'));
    await tester.pumpAndSettle();

    expect(noteExpanded, isTrue);
    expect(seen, isTrue);
    expect(find.text('收起 ▴'), findsOneWidget);
  });
}
