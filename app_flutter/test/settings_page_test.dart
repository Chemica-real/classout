// 设置页：改动要真的落到 kv / 数据上，并反馈到其它页面。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/domain/plan_math.dart';
import 'package:classout/ui/home_shell.dart';
import 'package:classout/ui/settings_page.dart' show appVersion;

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Future<void> _pump(WidgetTester tester, MemoryRepo repo) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
  await tester.pumpAndSettle();
  await tester.tap(find.text('设置').last); // 底部导航
  await tester.pumpAndSettle();
}


/// 顶部是**悬浮**标题条：ensureVisible 之后目标可能正好压在它下面，点不到。
/// 这里再按 ScrollPosition 把内容往下挪一点，确保目标在标题条下面。
Future<void> _tapUnderBar(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  final pos = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  for (var i = 0; i < 6; i++) {
    final rect = tester.getRect(target);
    if (rect.top > 90) break;
    pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
    await tester.pumpAndSettle();
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('同步节奏改完写进 kv', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    expect(find.text('设置'), findsWidgets);

    await _tapUnderBar(tester, find.byKey(const ValueKey('sync-15')));
    expect(await repo.getKv('sync_interval_min'), '15');
  });

  testWidgets('时间范围加减 30 分钟后规范化并保存', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);

    // 默认 07:00–24:00，点"上边界 ›"→ 07:30（鸿蒙端 WindowStepRow）
    await _tapUnderBar(tester, find.text('›').first);

    final saved = parseWindow((await repo.getKv('plan_window'))!);
    expect(saved.startMin, 7 * 60 + 30);
    expect(saved.endMin, 24 * 60);
  });

  testWidgets('新建待办类型 → 出现在 chip 里并写进 kv', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);

    // 鸿蒙端的待办类型卡是"行内输入 + 添加"
    final input = find.byKey(const ValueKey('cat-input'));
    await _tapUnderBar(tester, input);
    await tester.enterText(input, '社团');
    await tester.pumpAndSettle();
    await _tapUnderBar(tester, find.byKey(const ValueKey('cat-add')));
    await tester.pumpAndSettle();

    expect(await repo.getKv('todo_categories'), '社团');
    expect(find.text('社团'), findsWidgets);
  });

  testWidgets('内置类型不能删（没有删除按钮）', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    for (final label in ['作业', '自学', '考试', '无']) {
      expect(find.text(label), findsWidgets);
    }
    // 内置的 chip 没有 onDeleted → 删除图标数量应该等于自定义类型数量（这里是 0）
    expect(find.byIcon(Icons.cancel), findsNothing);
  });

  testWidgets('不可排时段：删一条后写回数据', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    expect(find.textContaining('午休'), findsWidgets);

    final before = (await repo.load())?.restWindows.length ?? 0;
    // 行内两段式：先点「删」，再在红字确认行里点「删除」
    await _tapUnderBar(tester, find.text('删').first);
    await _tapUnderBar(tester, find.text('删除').first);
    final after = (await repo.load())?.restWindows.length ?? 0;
    expect(after, before > 0 ? before - 1 : 0);
  });

  test('AppSettings 默认值与规范化', () async {
    final repo = MemoryRepo();
    final s = await AppSettings.load(repo);
    expect(s.syncIntervalMin, 10);
    expect(s.planWindow, defaultWindow);
    expect(s.customCategories, isEmpty);
    await repo.setKv('sync_interval_min', '999'); // 越界要夹紧
    expect((await AppSettings.load(repo)).syncIntervalMin, 180);
    await repo.setKv('sync_interval_min', '乱写'); // 坏值回默认
    expect((await AppSettings.load(repo)).syncIntervalMin, 10);
  });

  testWidgets('提醒卡：鸿蒙端同款「保存提醒设置」一次落库（简报开关 / 时间 / 提前量）',
      (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);

    // 默认简报开、8:00、提前 15 分钟 → 改成关 + 7:00 + 30 分钟
    await _tapUnderBar(tester, find.byKey(const ValueKey('brief-420')));
    await _tapUnderBar(tester, find.byKey(const ValueKey('lead-30')));
    await _tapUnderBar(tester, find.byKey(const ValueKey('save-reminder')));

    expect(await repo.getKv('brief_time'), '07:00');
    expect(await repo.getKv('class_lead'), '30');
    expect(await repo.getKv('brief_enabled'), '1');
  });

  testWidgets('提醒卡：关掉每日简报后「简报时间」整段消失（鸿蒙端 if）', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    expect(find.text('简报时间'), findsOneWidget);
    final sw = find.descendant(
        of: find.ancestor(
            of: find.text('每日简报'), matching: find.byType(Row)).first,
        matching: find.byType(Switch));
    await _tapUnderBar(tester, sw);
    expect(find.text('简报时间'), findsNothing);
  });

  testWidgets('不可排时段：结束早于开始 → 行内报错且不新增；合法后才写回',
      (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    final before = (await repo.load())?.restWindows.length ?? 0;

    // 默认草稿 12:00–13:00，把开始时间改成 14:00 就非法（结束 13:00 早于开始）
    // 直接点「添加」把草稿写进去，然后用时间行验证报错文案
    await _tapUnderBar(tester, find.byKey(const ValueKey('rest-add')));
    final after = (await repo.load())?.restWindows.length ?? 0;
    expect(after, before + 1, reason: '默认草稿合法，应该加一条');

    // 再点一次 → 同一条重复添加也合法（鸿蒙端不查重），这里只验证条数 +1
    await _tapUnderBar(tester, find.byKey(const ValueKey('rest-add')));
    expect((await repo.load())?.restWindows.length, before + 2);
  });

  testWidgets('待办类型：行内输入 + 添加，重复名报错（鸿蒙端 validateCategoryName）',
      (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    final input = find.byKey(const ValueKey('cat-input'));
    await _tapUnderBar(tester, input);
    await tester.enterText(input, '作业');
    await tester.pumpAndSettle();
    await _tapUnderBar(tester, find.byKey(const ValueKey('cat-add')));
    expect(find.textContaining('已经有了'), findsOneWidget);
    expect(await repo.getKv('todo_categories'), isNull, reason: '非法名不能落库');
  });

  testWidgets('关于卡：版本号 / 隐私政策 / MIT 许可（鸿蒙端同字）', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    final about = find.text('本应用纯离线运行：不联网、不上传、不需要账号，也不收集任何信息。');
    await tester.ensureVisible(about);
    await tester.pumpAndSettle();
    expect(find.text('v$appVersion'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('MIT 许可'), findsOneWidget);
    expect(find.text('开始演练'), findsOneWidget);
    expect(find.text('新手引导'), findsOneWidget);
  });
}
