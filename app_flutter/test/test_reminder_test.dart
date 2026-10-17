// 「试一条提醒」：真机验证通知权限/锁屏用的那条 10 秒提醒（这里用 FakeNotifier 验流程）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/notify/fake_notifier.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Future<FakeNotifier> _openSettings(WidgetTester tester,
    {bool granted = true}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final notifier = FakeNotifier(permissionGranted: granted);
  await tester.pumpWidget(MaterialApp(
    home: HomeShell(
        repo: MemoryRepo(_demo()), notifier: notifier),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('设置').last);
  await tester.pumpAndSettle();
  return notifier;
}

Future<void> _tapTestReminder(WidgetTester tester) async {
  final f = find.textContaining('试一条提醒');
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  // 顶部是悬浮标题条：目标被压住时点不到，按 ScrollPosition 往下挪一点
  final pos =
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  for (var i = 0; i < 6; i++) {
    if (tester.getRect(f).top > 90) break;
    pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
    await tester.pumpAndSettle();
  }
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点「试一条提醒」→ 排一条 10 秒后的通知并提示', (tester) async {
    final notifier = await _openSettings(tester);
    await _tapTestReminder(tester);

    expect(notifier.scheduled.length, 1);
    final n = notifier.scheduled.single;
    expect(n.kind, 'test');
    expect(n.title, contains('测试提醒'));
    final delay = n.at.difference(DateTime.now()).inSeconds;
    expect(delay, inInclusiveRange(5, 12), reason: '约 10 秒后');
    // 按钮文案本身也含「10 秒后」：排上之后应该是两个（按钮 + SnackBar）
    expect(find.textContaining('10 秒后'), findsNWidgets(2));
  });

  testWidgets('没有通知权限 → 不排，并提示去开权限', (tester) async {
    final notifier = await _openSettings(tester, granted: false);
    await _tapTestReminder(tester);

    expect(notifier.scheduled, isEmpty);
    expect(find.textContaining('没有通知权限'), findsOneWidget);
  });
}
