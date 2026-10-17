// 「上课节次时间」子页（鸿蒙端 CourseManager → SectionsView）：改时间 / 机动 / 加节 / 恢复默认。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/section_times_editor.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  testWidgets('把第一节开始改成 08:30 → 返回的行里是新值', (tester) async {
    final demo = _demo();
    final rows = demo.sectionTimes;
    List<SectionTime>? result;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await showSectionTimesEditor(ctx,
                  semesterId: demo.semester!.id, sections: rows);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('上课节次时间'), findsOneWidget);
    final first = find.byType(TextField).first;
    await tester.enterText(first, '08:30');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('sections-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sections-save')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.first.startMin, 8 * 60 + 30);
  });

  testWidgets('「恢复北大默认 12 节」+「+ 加一节」', (tester) async {
    final demo = _demo();
    List<SectionTime>? result;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await showSectionTimesEditor(ctx,
                  semesterId: demo.semester!.id, sections: demo.sectionTimes);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('恢复北大默认 12 节'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复北大默认 12 节'));
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);

    await tester.ensureVisible(find.text('+ 加一节'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 加一节'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('sections-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sections-save')));
    await tester.pumpAndSettle();

    expect(result!.length, 13);
    expect(result!.last.section, 13);
  });

  test('pkuSectionTimes：12 节，第 9/12 节是机动', () {
    final t = pkuSectionTimes(1);
    expect(t.length, 12);
    expect(t[0].startMin, 8 * 60);
    expect(t[8].flexible, isTrue);
    expect(t[11].flexible, isTrue);
    expect(t.where((x) => x.flexible).length, 2);
  });
}
