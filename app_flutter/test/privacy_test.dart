// 隐私说明：文案完整性 + 设置页入口能打开。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/domain/privacy.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('隐私章节齐全、每节都有标题和正文', () {
    final sections = privacySections();
    expect(sections.length, 9);
    for (final s in sections) {
      expect(s.heading.trim(), isNotEmpty);
      expect(s.body.trim(), isNotEmpty);
    }
    // 上架材料里必须有的两句
    expect(sections.first.body, contains('不收集'));
    expect(privacyUpdatedAt(), '2026-10-16');
  });

  testWidgets('设置 → 关于 → 隐私政策 能打开并显示全文', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: HomeShell(repo: MemoryRepo(_demo()), fallback: _demo())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    final link = find.byKey(const ValueKey('settings-privacy'));
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    // 悬浮标题条可能压住目标：按 ScrollPosition 往下挪一点
    final pos =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    for (var i = 0; i < 6; i++) {
      if (tester.getRect(link).top > 90) break;
      pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    await tester.tap(link);
    await tester.pumpAndSettle();

    // 入口文案和页面标题都叫「隐私政策」（鸿蒙端同字），所以这里是 2 个
    expect(find.text('隐私政策'), findsNWidgets(2));
    expect(find.text('一句话结论'), findsOneWidget);
    expect(find.textContaining('不收集'), findsWidgets);
    expect(find.textContaining('更新日期：'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget, reason: '鸿蒙底部有整宽「关闭」');
  });
}
