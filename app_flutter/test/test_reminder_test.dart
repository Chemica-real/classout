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
  // 鸿蒙端设置页没有这个入口：长按「保存提醒设置」才出安卓专属的提醒诊断
  final save = find.byKey(const ValueKey('save-reminder'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  final scroll = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  for (var i = 0; i < 8; i++) {
    if (tester.getRect(save).top > 90) break;
    scroll.jumpTo((scroll.pixels - 60).clamp(0.0, scroll.maxScrollExtent));
    await tester.pumpAndSettle();
  }
  await tester.longPress(save);
  await tester.pumpAndSettle();
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
    final before = notifier.scheduled.length; // 启动报告已经排过一批
    await _tapTestReminder(tester);

    final added = notifier.scheduled.sublist(before);
    expect(added.length, 1);
    final n = added.single;
    expect(n.kind, 'test');
    expect(n.title, contains('测试提醒'));
    final delay = n.at.difference(DateTime.now()).inSeconds;
    expect(delay, inInclusiveRange(5, 12), reason: '约 10 秒后');
    // 诊断菜单关了，只剩 SnackBar 上那句「10 秒后弹一条测试提醒」
    expect(find.textContaining('10 秒后'), findsOneWidget);
  });

  testWidgets('没有通知权限 → 不排，并提示去开权限', (tester) async {
    final notifier = await _openSettings(tester, granted: false);
    await _tapTestReminder(tester);

    expect(notifier.scheduled, isEmpty);
    expect(find.textContaining('没有通知权限'), findsOneWidget);
  });
}
