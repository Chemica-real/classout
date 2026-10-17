// 新手演练（沙箱 + 引导条）的测试：
//   ① 步骤脚本本身（文案、标签页合法性、上一步/下一步夹取）
//   ② 整条流程：首次启动弹窗 → 开始演练 → 数据换成演练学期 → 引导条切标签页
//      → 完成演练 → 真实数据一字不差地回来

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/data/backup_export.dart';
import 'package:classout/domain/demo_sandbox.dart';
import 'package:classout/domain/guide.dart';
import 'package:classout/ui/guide_bar.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  tearDown(() => guidePromptEnabled = true);

  test('步骤脚本：7 步、文案非空、标签页都在 0..3', () {
    final steps = guideSteps();
    expect(steps.length, 7);
    for (final s in steps) {
      expect(s.title.trim(), isNotEmpty);
      expect(s.body.trim(), isNotEmpty);
      expect(s.tab, inInclusiveRange(0, 3));
    }
    // 上一步/下一步都夹在范围内
    expect(prevGuideStep(0), 0);
    expect(nextGuideStep(steps.length - 1), steps.length - 1);
    expect(isLastGuideStep(steps.length - 1), isTrue);
    expect(isLastGuideStep(0), isFalse);
    expect(guideStepAt(99).title, steps.last.title);
  });

  testWidgets('首次启动 → 开始演练 → 完成演练后真实数据原样回来', (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final mine = _demo();
    final repo = MemoryRepo(mine);
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();

    // ① 首次启动的询问（鸿蒙端 GuidePromptCard：整屏薄纱 + 居中玻璃卡）
    expect(find.text('第一次用 ClassOUT？'), findsOneWidget);
    expect(find.text('共 ${guideStepCount()} 步，大约两分钟。'), findsOneWidget);
    expect(find.text('先自己用用'), findsOneWidget);
    await tester.tap(find.text('开始演练'));
    await tester.pumpAndSettle();

    // ② 进入沙箱：数据换成演练数据（演示学期名一样，靠引导条与 kv 判断）
    final inSandbox = (await repo.load())!;
    expect(inSandbox.courses.length, 4);
    expect(await repo.getKv(guidePromptedKey), '1');
    expect((await repo.getKv(sandboxBackupKey) ?? '').isNotEmpty, isTrue);
    expect(find.byType(GuideBar), findsOneWidget);
    expect(find.text('第 1/7 步'), findsOneWidget);
    // 鸿蒙端两个按钮**等宽**：第一步时「上一步」只是变淡，仍然占位
    expect(find.text('上一步'), findsOneWidget);
    final prevRect = tester.getRect(find.text('上一步'));
    final nextRect = tester.getRect(find.text('下一步'));
    expect((prevRect.width - nextRect.width).abs(), lessThan(1.0),
        reason: '两个按钮等宽');

    // ③ 下一步会切到「待办」标签
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('第 2/7 步'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    // 第 4 步在待办页：能看到演练数据里的待办（鸿蒙沙箱没有"待确认"条目）
    expect(find.text('数学作业 P12 第 3-5 题'), findsWidgets);

    // ④ 还剩 3 步（5/6/7）→ 走到最后一步并完成演练
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    expect(find.text('完成演练'), findsOneWidget);
    await tester.tap(find.text('完成演练'));
    await tester.pumpAndSettle();

    // ⑤ 真实数据回来：课程/待办/块与原来逐项一致，备份 key 清空
    final restored = (await repo.load())!;
    expect(restored.courses.length, mine.courses.length);
    expect(restored.todos.length, mine.todos.length);
    expect(restored.blocks.length, mine.blocks.length);
    expect(restored.semester!.name, mine.semester!.name);
    expect(await repo.getKv(sandboxBackupKey), '');
    expect(find.byType(GuideBar), findsNothing);
  });

  testWidgets('演练里改的偏好不会留到真库：退出时整份还原，并回到课表页', (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = MemoryRepo(_demo());
    await repo.setKv('motto', '真实标语'); // 用户自己的首页标语
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始演练'));
    await tester.pumpAndSettle();

    // 演练里随手改了标语 + 加了个不存在于真库的键（模拟"沙箱里新写的设置"）
    await repo.setKv('motto', '演练里改的标语');
    await repo.setKv('sandbox_only_key', 'x');
    expect((await AppSettings.load(repo)).motto, '演练里改的标语');

    // 走到最后一步并完成演练
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('完成演练'));
    await tester.pumpAndSettle();

    // ① 偏好整份回到进沙箱前（鸿蒙沙箱是另一个 db 文件，安卓靠这份快照对齐）
    expect((await AppSettings.load(repo)).motto, '真实标语');
    expect(await repo.getKv('sandbox_only_key'), isNull, reason: '沙箱里新写的键要删掉');
    expect(await repo.getKv(sandboxPrefsKey), isNull);
    // ② 回到课表页（鸿蒙 doExitGuide 里 this.tab = 0）
    expect(find.text('管理课程'), findsOneWidget, reason: '应该停在课表页');
    expect(find.byType(GuideBar), findsNothing);
  });

  testWidgets('冷启动：沙箱备份 + 偏好快照都还原（演练被杀也不脏真库）', (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final mine = _demo();
    final repo = MemoryRepo(buildDemoSandbox(now: DateTime(2026, 10, 16)));
    await repo.setKv(sandboxBackupKey, backupToJson(mine));
    await repo.setKv(sandboxPrefsKey, '{"motto":"真实标语"}');
    await repo.setKv('motto', '演练里改的标语');
    await repo.setKv('sandbox_only_key', 'x');

    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();

    expect((await AppSettings.load(repo)).motto, '真实标语');
    expect(await repo.getKv('sandbox_only_key'), isNull);
    expect(await repo.getKv(sandboxPrefsKey), isNull);
    expect(await repo.getKv(sandboxBackupKey), '');
  });

  testWidgets('切数据那一下有「正在准备演练…」忙碌层（鸿蒙 GuideBusyLayer）',
      (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = MemoryRepo(_demo());
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始演练'));
    // 切数据是异步的：逐帧推进直到忙碌层出现（弹窗要先关掉、再 setKv、再进沙箱）
    var seen = false;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      if (find.text('正在准备演练…').evaluate().isNotEmpty) {
        seen = true;
        break;
      }
    }
    expect(seen, isTrue, reason: '进沙箱时应该先出「正在准备演练…」');
    await tester.pumpAndSettle();
    expect(find.text('正在准备演练…'), findsNothing);
    expect(find.byType(GuideBar), findsOneWidget);
  });

  testWidgets('进沙箱时偏好回到默认值（鸿蒙是一个全新的库）', (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = MemoryRepo(_demo());
    await repo.setKv('motto', '真实标语');
    await repo.setKv('wallpaper_path', '/data/user/0/x/wall.jpg');
    await repo.setKv('todo_categories', '["我的类型"]');
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始演练'));
    await tester.pumpAndSettle();

    // 鸿蒙沙箱是另一个 .db：壁纸/标语/自定义类型都回到默认
    final s = await AppSettings.load(repo);
    expect(s.motto, '', reason: '演练里应该是默认标语（显示层再兜底）');
    expect(s.wallpaperPath, '');
    expect(s.customCategories, isEmpty);
  });

  testWidgets('选「先自己用用」→ 不进沙箱、也记下问过了', (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final repo = MemoryRepo(_demo());
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('先自己用用'));
    await tester.pumpAndSettle();

    expect(find.byType(GuideBar), findsNothing);
    expect(await repo.getKv(guidePromptedKey), '1');
    expect(await repo.getKv(sandboxBackupKey), isNull);
  });

  testWidgets('冷启动发现沙箱备份 → 先把真实数据还原、再清掉 kv（演练被杀也不丢数据）',
      (tester) async {
    guidePromptEnabled = true;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final mine = _demo();
    final sandbox = buildDemoSandbox(now: DateTime(2026, 10, 16));
    final repo = MemoryRepo(sandbox); // 库里现在是"演练数据"
    await repo.setKv(sandboxBackupKey, backupToJson(mine));

    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();

    final restored = (await repo.load())!;
    expect(restored.semester!.name, mine.semester!.name,
        reason: '冷启动应把真实数据还原回来');
    expect(restored.courses.length, mine.courses.length);
    expect(await repo.getKv(sandboxBackupKey), '');
  });
}
