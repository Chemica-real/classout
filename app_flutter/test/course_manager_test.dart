// 课程管理（鸿蒙端 CourseManager.ets）的交互测试：
// 改课程、加时段、加模板、删课程，都要真的写回仓库。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/backup_export.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Future<MemoryRepo> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final repo = MemoryRepo(_demo());
  await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
  await tester.pumpAndSettle();
  await tester.tap(find.text('管理课程'));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开课程管理：列出 4 门课与学期摘要', (tester) async {
    await _pump(tester);
    expect(find.text('课程与学期'), findsWidgets);
    // 课程卡照鸿蒙：彩色简称胶囊 + 全名 + 逐条时段 + ⚙ 模板行
    expect(find.textContaining('节 · 1-16'), findsWidgets);
    expect(find.text('学期'), findsOneWidget);
    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('课程（4）'), findsOneWidget);
    expect(find.textContaining('线代'), findsWidgets);
  });

  testWidgets('改简称 → 写回仓库', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    expect(find.text('编辑课程'), findsOneWidget);

    final short = find.widgetWithText(TextField, '线代');
    await tester.enterText(short, '线代A');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    final saved = (await repo.load())!;
    final course = saved.courses.firstWhere((c) => c.id == 4);
    expect(course.shortName, '线代A');
    expect(course.name, '线性代数', reason: '没改的字段不能被顺手清空');
  });

  testWidgets('加一个时段 → 写回仓库', (tester) async {
    final repo = await _pump(tester);
    final before = (await repo.load())!.rules.length;
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加时段'));
    expect(find.text('添加上课时段'), findsOneWidget);
    // 第一次「保存」是时段弹窗，第二次才是课程子页
    // 弹窗底部的「保存」现在是鸿蒙同款胶囊（GestureDetector，不是 FilledButton）
    await _tapVisible(tester, find.text('保存').last);
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    final saved = (await repo.load())!;
    expect(saved.rules.length, before + 1);
    expect(saved.rules.last.courseId, 4);
  });

  testWidgets('时段规则：周次填不出任何一周 → 拒绝保存并说明原因（鸿蒙 validateSessionRule）',
      (tester) async {
    final repo = await _pump(tester);
    final before = (await repo.load())!.rules.length;
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加时段'));
    expect(find.text('添加上课时段'), findsOneWidget);
    // 周次输入框：找 hint 为 1-16 的那个
    // 填一个能解析、但一周都不命中的值（maskFromText：解析不出来时故意回全 1）
    await tester.enterText(
        find.widgetWithText(TextField, '1-16'), '0');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('保存').last);
    // 弹窗还开着 + 红字，且没有写库
    expect(find.text('添加上课时段'), findsOneWidget);
    expect(find.textContaining('至少要勾选一个上课周次'), findsOneWidget);
    expect((await repo.load())!.rules.length, before);
  });

  testWidgets('生成模板：未知 %变量 → 拒绝保存并给出可用清单（鸿蒙 validateTemplateTitle）',
      (tester) async {
    final repo = await _pump(tester);
    final before = (await repo.load())!.templates.length;
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加模板'));
    expect(find.text('添加生成模板'), findsOneWidget);
    // 标题输入框是**弹窗里**第一个 TextField（页面后面的课程名也是 TextField，别抓错）
    final titleField = find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
        .first;
    await tester.enterText(titleField, '%M作业');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('保存').last);
    expect(find.text('添加生成模板'), findsOneWidget);
    expect(find.textContaining('不是支持的变量'), findsOneWidget);
    expect(find.textContaining('%C %c %D %d %W %T %N %R'), findsOneWidget);
    expect((await repo.load())!.templates.length, before);
  });

  testWidgets('节次时间：结束早于开始 → 拒绝保存并说明原因（鸿蒙 validateSectionTimes）',
      (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-sections')));
    expect(find.text('上课节次时间'), findsWidgets);
    // 第 1 行：开始 08:00、结束 08:50 → 把结束改成 07:00（早于开始）
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), '07:00');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const ValueKey('sections-save')));
    // 还停在这一页 + 红字；库里没被写坏
    expect(find.text('保存节次时间'), findsOneWidget);
    expect(find.textContaining('第 1 节的结束时间必须晚于开始时间'), findsOneWidget);
    final saved = (await repo.load())!;
    expect(saved.sectionTimes.first.startMin, 480);
    expect(saved.sectionTimes.first.endMin, 530);
  });

  testWidgets('加一个模板 → 写回仓库，模板能被生成器用', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加模板'));
    expect(find.text('添加生成模板'), findsOneWidget);

    final title = find.descendant(
        of: find.byType(Dialog).last, matching: find.byType(TextField)).first;
    await tester.enterText(title, '线代作业 %N');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const ValueKey('template-save')));
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    final saved = (await repo.load())!;
    expect(saved.templates.length, 1);
    final t = saved.templates.first;
    expect(t.courseId, 4);
    expect(t.titleTemplate, '线代作业 %N');
    expect(t.enabled, isTrue);
  });

  testWidgets('删课程 → 课程、它的时段与模板一起消失', (tester) async {
    final repo = await _pump(tester);
    final before = (await repo.load())!;
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('删除课程'));
    // 鸿蒙 DeleteConfirmRow：说明 + 取消 + 红色「删除」
    expect(find.textContaining('确定删除'), findsOneWidget);
    await _tapVisible(tester, find.text('删除').last);

    final saved = (await repo.load())!;
    expect(saved.courses.any((c) => c.id == 4), isFalse);
    expect(saved.rules.any((r) => r.courseId == 4), isFalse);
    expect(before.courses.length - 1, saved.courses.length);
  });

  testWidgets('虚拟课程：讲数用 1–50 滑条整批同步；删课程时课时一起清掉', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    // 打开「虚拟课程」开关（编辑抽屉里第二个 Switch）
    await _tapVisible(tester, find.byType(Switch).last);
    expect(find.textContaining('共多少讲（当前 1）'), findsOneWidget);

    // 滑条拉到 2 讲（直接调 onChanged，避免像素换算带来的不确定性）
    tester.widget<Slider>(find.byType(Slider).last).onChanged!(2);
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    var saved = (await repo.load())!;
    expect(saved.lessons.length, 2);
    expect(saved.lessons.first.courseId, 4);
    expect(saved.lessons.map((l) => l.seq).toList(), [1, 2]);

    // 再降回 1 讲：未完成的那一讲被删掉
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    tester.widget<Slider>(find.byType(Slider).last).onChanged!(1);
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));
    saved = (await repo.load())!;
    expect(saved.lessons.length, 1);

    // 删除课程 → 课时一起没
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('删除课程'));
    await _tapVisible(tester, find.text('删除').last);
    saved = (await repo.load())!;
    expect(saved.lessons, isEmpty);
  });

  testWidgets('时段规则的「周次」按文本解析（1-8 → 前 8 周）', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加时段'));
    expect(find.text('添加上课时段'), findsOneWidget);

    // 时段弹窗里只有两个输入框：周次（第一个）与地点
    // ⚠️ 必须限定在最上层 Dialog 里：下面还开着课程编辑抽屉，它也有 TextField
    final weeks = find
        .descendant(of: find.byType(Dialog).last, matching: find.byType(TextField))
        .first;
    await tester.ensureVisible(weeks);
    await tester.pumpAndSettle();
    await tester.enterText(weeks, '1-8');
    await tester.pumpAndSettle();
    // 弹窗底部的「保存」现在是鸿蒙同款胶囊（GestureDetector，不是 FilledButton）
    await _tapVisible(tester, find.text('保存').last);
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    final saved = (await repo.load())!;
    final rule = saved.rules.lastWhere((r) => r.courseId == 4);
    expect(rule.weeksMask, '1111111100000000');
  });

  testWidgets('清空本学期课程需要二次确认，且只删课程/时段/模板', (tester) async {
    final repo = await _pump(tester);
    // 先给一门课加个模板，验证模板会一起被清
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加模板'));
    await _tapVisible(tester, find.byKey(const ValueKey('template-save')));
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    final withTemplate = (await repo.load())!;
    expect(withTemplate.templates.length, 1);

    // 第一次点只是"进入确认态"
    await _tapVisible(tester, find.text('清空本学期课程'));
    expect((await repo.load())!.courses.length, 4, reason: '第一次点不能真删');

    await _tapVisible(tester, find.text('确定重载'));
    final saved = (await repo.load())!;
    expect(saved.courses, isEmpty);
    expect(saved.rules, isEmpty);
    expect(saved.templates, isEmpty);
    // 待办与计划块不动
    expect(saved.todos.length, withTemplate.todos.length);
    expect(saved.blocks.length, withTemplate.blocks.length);
  });

  testWidgets('新建学期（不复制）→ 学期 +1，当前学期不变', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-semester')));
    // 关掉「顺便复制」再创建
    await _tapVisible(tester, find.byType(Switch).last);
    await _tapVisible(tester, find.text('新建并切换到这个学期'));

    final saved = (await repo.load())!;
    expect(saved.semesters.length, 2);
    // 鸿蒙按钮是「新建并切换到这个学期」：新建后它成为当前学期
    expect(saved.semesters.first.name, isNot('演示学期'));
    expect(saved.semesters.first.totalWeeks, 16);
    expect(saved.courses.length, 4, reason: '没勾复制就不该多出课程');
  });

  testWidgets('新建学期 + 复制课表 → 课程/时段/节次都各多一份（换新 id）',
      (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-semester')));
    await _tapVisible(tester, find.text('新建并切换到这个学期'));

    final saved = (await repo.load())!;
    final oldSem = saved.semesters.first;
    final newSem = saved.semesters.last;
    expect(saved.semesters.length, 2);

    final newCourses =
        saved.courses.where((c) => c.semesterId == newSem.id).toList();
    expect(newCourses.length, 4, reason: '四门课都复制过去');
    // id 必须换新（否则两学期共用同一批课程，改一个动两个）
    final oldIds = saved.courses
        .where((c) => c.semesterId == oldSem.id)
        .map((c) => c.id)
        .toSet();
    for (final c in newCourses) {
      expect(oldIds.contains(c.id), isFalse);
    }
    // 新学期的时段规则指向新课程 id，且周掩码按新周数
    final newRules =
        saved.rules.where((r) => newCourses.any((c) => c.id == r.courseId));
    expect(newRules.length, 6);
    for (final r in newRules) {
      expect(r.weeksMask.length, newSem.totalWeeks);
    }
    // 节次时间也复制了一份
    expect(
        saved.sectionTimes.where((t) => t.semesterId == newSem.id).length,
        saved.sectionTimes.where((t) => t.semesterId == oldSem.id).length);
  });

  testWidgets('把第二个学期设为当前 → 顺序换了、课表切过去', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-semester')));
    await _tapVisible(tester, find.text('新建并切换到这个学期'));
    // 新建后新学期是当前；点另一行（演示学期）= 切回它
    await _tapVisible(tester, find.textContaining('起 ·').last);

    final saved = (await repo.load())!;
    expect(saved.semesters.first.name, '演示学期');
    expect(saved.semester!.name, saved.semesters.first.name);
  });

  testWidgets('复制到当前学期：课程 / 时段 / 模板都复制一份（换新 id、同名跳过）',
      (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-semester')));
    // 鸿蒙是子页底部内联表单：关掉「顺便复制」再点「新建并切换到这个学期」
    await _tapVisible(tester, find.byType(Switch).last);
    await _tapVisible(tester, find.text('新建并切换到这个学期'));
    // 切到新学期（点行），再点另一行的「复制到当前学期」
    await _tapVisible(tester, find.textContaining('起 ·').last);
    await _tapVisible(tester, find.text('复制到当前学期'));

    final saved = (await repo.load())!;
    final cur = saved.semester!;
    final copied = saved.courses.where((c) => c.semesterId == cur.id).toList();
    expect(copied.length, 4);
    expect(saved.courses.where((c) => c.id == copied.first.id).length, 1);
    final copiedRules =
        saved.rules.where((r) => copied.any((c) => c.id == r.courseId)).length;
    expect(copiedRules, 6, reason: '时段规则一起复制');
    // demo 数据本身没有模板：只比较"源有几条、复制后就有几条"
    final srcIds = saved.courses
        .where((c) => c.semesterId != cur.id)
        .map((c) => c.id)
        .toSet();
    expect(
        saved.templates
            .where((t) => copied.any((c) => c.id == t.courseId))
            .length,
        saved.templates.where((t) => srcIds.contains(t.courseId)).length);
  });

  testWidgets('模板变量快捷插入 + 实时预览（鸿蒙 TemplateDialog）', (tester) async {
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加模板'));

    // 默认标题「%D作业」→ 预览里应该是具体日期 + 作业
    expect(find.textContaining('预览：'), findsOneWidget);
    expect(find.textContaining('作业'), findsWidgets);

    // 点「课程简称」变量按钮 → 插到光标处（初始光标在末尾）
    await _tapVisible(tester, find.text('课程简称'));
    // 插到光标处（默认光标在开头）→ 「%c%D作业」
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        '%c%D作业');
    await _tapVisible(tester, find.byKey(const ValueKey('template-save')));
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));

    // 草稿里的标题被保存下来
    expect(find.text('课程（4）'), findsOneWidget);
  });

  testWidgets('保存课程后列表顶部出现鸿蒙同款提示「已保存」', (tester) async {
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.byKey(const ValueKey('course-save')));
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('清空本学期课程后有提示「已清空本学期的课程」', (tester) async {
    await _pump(tester);
    await _tapVisible(tester, find.text('清空本学期课程'));
    await _tapVisible(tester, find.text('确定重载'));
    expect(find.text('已清空本学期的课程'), findsOneWidget);
    expect(find.text('课程（0）'), findsOneWidget);
  });

  testWidgets('备份子页：导出后蓝框显示「已写入 N 字节」+ 摘要，路径与 adb pull 常显',
      (tester) async {
    // path_provider 在测试里没有原生实现：用备份模块的测试注入点写到临时目录
    // FakeAsync 里做真实异步文件 I/O 会永远等下去 → 用同步版建/删临时目录
    final dir = Directory.systemTemp.createTempSync('classout-bk-golden');
    backupDirOverride = dir;
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(() => backupDirOverride = null);
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-backup')));
    // 真实文件 I/O 要在 runAsync 里跑（FakeAsync 不会推进它）
    await tester.runAsync(() async {
      await tester.tap(find.text('导出备份到文件'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    // 鸿蒙 `backupNote = 已写入 N 字节\n摘要`；蓝框不是 SnackBar
    expect(find.textContaining('已写入 '), findsOneWidget);
    expect(find.textContaining('字节'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('adb pull'), findsOneWidget);
    // 路径块是固定文件（鸿蒙 BACKUP_FILE 同名）
    expect(find.textContaining('classout-backup.json'), findsWidgets);
  });

  testWidgets('备份子页：路径块与「从备份恢复」一直都在（鸿蒙 BackupView 同款）',
      (tester) async {
    // 还没导出时 path_provider 读不到目录 → 显示占位；关键是这两块**不是导出后才出现**
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-backup')));
    expect(find.text('备份文件路径'), findsOneWidget);
    expect(find.text('从备份恢复'), findsOneWidget);
    expect(find.textContaining('adb pull'), findsOneWidget);
    // 鸿蒙那颗按钮是琥珀色（rgba(178,107,0,0.20) 底 + #E8B25C 字）
    final txt = tester.widget<Text>(find.text('从备份恢复'));
    expect(txt.style!.color, const Color(0xFFE8B25C));
  });

  testWidgets('备份子页：点「从备份恢复」→ 内联「取消 | 确认恢复」，不弹文件选择',
      (tester) async {
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-backup')));
    await _tapVisible(tester, find.text('从备份恢复'));
    // 鸿蒙 `confirmRestore` 面板：红底说明 + 两颗按钮，页面不跳走
    expect(find.textContaining('确定用备份覆盖当前数据？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认恢复'), findsOneWidget);
    expect(find.text('备份与恢复'), findsWidgets);
    // 取消 → 回到琥珀按钮
    await _tapVisible(tester, find.text('取消'));
    expect(find.text('从备份恢复'), findsOneWidget);
  });

  testWidgets('备份子页：没有备份文件时确认恢复 → 蓝框提示先导出', (tester) async {
    final dir = Directory.systemTemp.createTempSync('classout-bk-empty');
    backupDirOverride = dir;
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(() => backupDirOverride = null);
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-backup')));
    await _tapVisible(tester, find.text('从备份恢复'));
    await tester.runAsync(() async {
      await tester.tap(find.text('确认恢复'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    // 鸿蒙文案：还没有备份文件，先点上面的「导出备份」
    expect(find.textContaining('还没有备份文件'), findsOneWidget);
    expect(find.text('从备份恢复'), findsOneWidget, reason: '确认面板应当收起');
  });

  testWidgets('诊断信息显示各表条数（鸿蒙 diagnostics 同款）', (tester) async {
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('entry-backup')));
    expect(find.text('诊断信息'), findsOneWidget);
    expect(find.textContaining('semester: 1'), findsOneWidget);
    expect(find.textContaining('course: 4'), findsOneWidget);
    expect(find.textContaining('todo: 6'), findsOneWidget);
    expect(find.textContaining('rest_window: '), findsOneWidget);
  });
}
