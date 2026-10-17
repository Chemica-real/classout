// 应用外壳：负责「读数据 → 画界面 → 导入后重画」。
// 数据仓库是注入的，所以 web 用内存版、原生用 SQLite 版都能跑同一套 UI。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/blacklist.dart';
import '../data/backup_export.dart';
import '../data/note_pref.dart';
import '../data/repo.dart';
import '../data/settings.dart';
import '../domain/reminders.dart';
import '../domain/sync_cadence.dart';
import '../domain/categories.dart';
import '../domain/dates.dart';
import '../domain/demo_sandbox.dart';
import '../domain/guide.dart';
import '../domain/migrate.dart';
import '../domain/motto.dart';
import '../domain/timetable.dart';
import '../domain/todo_generator.dart';
import '../model/types.dart' show Todo;
import '../notify/flutter_notifier.dart';
import '../notify/notifier.dart';
import '../notify/scheduler.dart';
import 'app_frame.dart';
import 'backup_picker.dart';
import 'import_dialog.dart';
import 'palette.dart';
import 'plan_page.dart';
import 'settings_page.dart';
import 'boot_screen.dart';
import 'course_header.dart';
import 'guide_bar.dart';
import 'course_manager.dart';
import 'session_sheet.dart';
import 'theme.dart' as theme;
import 'timetable_page.dart';
import 'todo_editor.dart';
import 'todo_page.dart';

class HomeShell extends StatefulWidget {
  final ClassOutRepo repo;

  /// 库是空的时，用这份兜底数据（演示版就是这么起来的）
  final BackupBundle? fallback;

  /// 通知实现（默认真实插件；测试可注入 FakeNotifier）
  final ReminderNotifier? notifier;

  /// 「从文件选备份」的实现（默认真实 file_picker；测试可注入假实现）
  final BackupPicker? backupPicker;

  const HomeShell({
    super.key,
    required this.repo,
    this.fallback,
    this.notifier,
    this.backupPicker,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  BackupBundle? _bundle;
  AppSettings _settings = AppSettings();
  bool _loading = true;
  String? _error;
  int _tab = 0;
  bool _syncing = false;

  /// 启动清单走到第几步（0..4），见 boot_screen.dart 的 bootSteps
  int _bootStep = 0;
  bool _bootReady = false;

  /// 过场层是否还在（true = 显示加载页/小球）
  bool _bootVisible = true;

  /// 悬浮页头的实测高度（课表/待办页据此在滚动内容顶部留白）
  double _headerH = 134;

  // ---- 同步节奏（鸿蒙端 SyncCadence：连续使用到 n 分钟的整数倍自动同步；
  //      闲置超过 n 分钟再打开会重新走一遍启动流程）----
  Timer? _tick;
  DateTime _lastActiveAt = DateTime.now();
  int _activeSec = 0;

  /// 新手演练：是否在沙箱里、走到第几步、这次运行里问过没有
  bool _sandbox = false;

  /// 切库/换数据时挡一下（鸿蒙 `GuideBusyLayer`）：那一瞬间数据是半截的
  bool _guideBusy = false;

  /// 忙碌层上那句话：进演练 / 回真实课表
  bool _guideBusyEntering = false;
  int _guideStep = 0;
  bool _guidePromptShown = false;

  /// 当前周次（页头 ‹ › 改它；课表页照着画）
  int _week = 1;
  late final ReminderNotifier _notifier = widget.notifier ?? FlutterNotifier();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload(boot: true);
    // 计时器只在真机跑（测试里不能让 1s 周期定时器挂着）
    if (ambientMotion) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('[ClassOUT] lifecycle: $state');
    if (state == AppLifecycleState.resumed) {
      final idle = DateTime.now().difference(_lastActiveAt);
      debugPrint('[ClassOUT] idle=${idle.inSeconds}s '
          'interval=${_settings.syncIntervalMin}min');
      if (shouldRestartAfterIdle(
          idle.inMilliseconds, _settings.syncIntervalMin)) {
        // 闲置太久 → 当成一次冷启动（鸿蒙端就是这么做的：重新走一遍启动流程）
        _activeSec = 0;
        _reload(boot: true);
      }
    } else {
      _lastActiveAt = DateTime.now();
    }
  }

  /// 每秒走一格：连续使用到 n 分钟的整数倍时自动同步一次
  void _onTick() {
    if (!mounted) return;
    _activeSec++;
    if (_activeSec % 60 != 0) return;
    final activeMin = _activeSec ~/ 60;
    if (isSyncBoundary(activeMin, _settings.syncIntervalMin)) {
      debugPrint('[ClassOUT] sync boundary: activeMin=$activeMin '
          'interval=${_settings.syncIntervalMin}');
      _manualSync();
    }
  }

  /// [boot] = 是否重播启动过场（只有冷启动那一次；导入/演练/补生成之后只静默重读）
  Future<void> _reload({bool boot = false}) async {
    setState(() {
      _loading = true;
      if (boot) {
        _bootStep = 0;
        _bootReady = false;
        _bootVisible = true;
      }
    });
    try {
      var settings = await AppSettings.load(widget.repo);
      // 演练沙箱的"安全网"：鸿蒙端演练用的是**另一个库文件**，App 被杀也只是丢沙箱；
      // 安卓是整份替换同一个库，所以冷启动时必须先把 kv 里的真实备份还原回去。
      // 否则（演练中被杀/被更新覆盖）用户再打开就是演示数据，而且没有"退出演练"可点。
      final sandboxBackup = await widget.repo.getKv(sandboxBackupKey) ?? '';
      // ⚠️ 正在演练里（_sandbox=true）时不要还原：`_startGuide` 刚把真实数据写进 kv，
      // 这时还原会把刚进沙箱的状态又弹回去。
      if (!_sandbox && sandboxBackup.isNotEmpty) {
        try {
          await widget.repo.replaceAll(BackupBundle.decode(sandboxBackup));
          debugPrint('[ClassOUT] restored real data from sandbox backup');
        } catch (e) {
          debugPrint('[ClassOUT] sandbox restore failed: $e');
        }
        await widget.repo.setKv(sandboxBackupKey, '');
        // 偏好也一起还原（沙箱里可能改过标语/时间范围/类型）
        final prefs = await widget.repo.getKv(sandboxPrefsKey) ?? '';
        if (prefs.isNotEmpty) await _restorePrefs(prefs);
        settings = await AppSettings.load(widget.repo);
      }
      var data = await widget.repo.load();
      if (data == null && widget.fallback != null) {
        await widget.repo.replaceAll(widget.fallback!);
        data = await widget.repo.load();
      }
      // 老数据的迁移（鸿蒙 `Seeder.migrateData`）：时长按 5 分钟分度、考试归 0、
      // 退役的「其他」→「无」。幂等，返回 null 表示无事可做。
      if (data != null) {
        final migrated = migrateBundle(data);
        if (migrated != null) {
          data = migrated;
          await widget.repo.replaceAll(data);
          debugPrint('[ClassOUT] migrated legacy estimates/categories');
        }
      }
      // CI 自检：这一行出现 = 数据层真的读通了
      debugPrint('[ClassOUT] loaded: courses=${data?.courses.length} '
          'todos=${data?.todos.length} rules=${data?.rules.length}');
      // 动画总开关是"内存态"（鸿蒙端 AppStorage('motionOn')）：读库后立刻生效
      theme.motionOn = settings.motionEnabled;
      // 备注展开状态同理（待办编辑窗与计划块面板共用）
      noteExpanded = await loadNoteExpanded(widget.repo);
      if (!mounted) return;
      setState(() {
        _bundle = data;
        _settings = settings;
        _loading = false;
        _error = null;
        _bootStep = 1;
        final sem = data?.semester;
        if (sem != null) {
          _week = weekOfDate(sem, DateTime.now()).clamp(1, sem.totalWeeks);
        }
      });
      // 首次启动问一句要不要走一遍新手演练。
      // 有启动页时**等过场播完再问**（否则对话框会压在加载页上，鸿蒙端也是进应用后才问）。
      if (!ambientMotion) await _maybePromptGuide();
      // 打开 App 时静默补生成「已经下课」的待办（鸿蒙端 generateMissedTodos）
      if (data != null) {
        setState(() => _bootStep = 2);
        await _generateMissed(data);
      }
      // 提醒同步这一步没有真实工作（排提醒是用户手动/定时触发的），只让清单走完
      if (!mounted) return;
      setState(() => _bootStep = 3);
      // 「人为放慢」只在真机生效；测试里不等，免得留下未完成的定时器
      if (ambientMotion) await Future<void>.delayed(dur(bootStepMs));
      if (!mounted) return;
      setState(() {
        _bootStep = 4;
        _bootReady = true;
      });
    } catch (e) {
      debugPrint('[ClassOUT] load error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 页面改了数据（勾完成/新建待办…）：先更新界面，再整份写回仓库
  Future<void> _apply(BackupBundle next) async {
    var b = next;
    final prev = _bundle;
    if (prev != null) {
      final black = await loadBlacklist(widget.repo);
      // ① 用户删掉的**自动生成**待办 → 进黑名单，下次补生成不再回来
      final before = {
        for (final t in prev.todos)
          if (t.generationKey.isNotEmpty) t.generationKey
      };
      final after = {
        for (final t in next.todos)
          if (t.generationKey.isNotEmpty) t.generationKey
      };
      final removed = before.difference(after);
      if (removed.isNotEmpty) await addToBlacklist(widget.repo, removed);
      // ② 万一某条被重新造出来了，但它的键在黑名单里 → 丢掉
      //    （虚拟课时那条生成路径在 block_editor 里，先在这里兜一层，效果与
      //    鸿蒙 `generateForSession` 的 `isBlacklisted` 相同）
      if (black.isNotEmpty) {
        final kept = next.todos
            .where((t) =>
                t.generationKey.isEmpty || !black.contains(t.generationKey))
            .toList();
        if (kept.length != next.todos.length) {
          b = next.copyWith(todos: kept);
        }
      }
    }
    setState(() => _bundle = b);
    await widget.repo.replaceAll(b);
  }

  /// 在待办编辑窗里新建的类型 → 回写设置页那份列表
  void _addCustomCategory(String name) {
    _settings.customCategories =
        addCustomCategory(_settings.customCategories, name);
    _settings.save(widget.repo).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// 计划页「截止标记」点一条 → 打开那条待办的编辑窗（鸿蒙 DdlExpandPanel 的行为）
  Future<void> _openTodoById(int id) async {
    final b = _bundle;
    if (b == null) return;
    Todo? existing;
    for (final t in b.todos) {
      if (t.id == id) existing = t;
    }
    if (existing == null) return;
    final result = await showTodoEditor(
      context,
      courses: b.courses,
      existing: existing,
      customCategories: _settings.customCategories,
      onAddCategory: _addCustomCategory,
      onNotePref: (on) {
        noteExpanded = on;
        saveNoteExpanded(widget.repo, on);
      },
    );
    if (!mounted || result == null) return;
    final List<Todo> todos;
    if (result.delete) {
      todos = b.todos.where((t) => t.id != id).toList();
    } else {
      final draft = result.todo!;
      todos = b.todos.map((t) => t.id == id ? draft : t).toList();
    }
    await _apply(BackupBundle(
      app: b.app,
      version: b.version,
      exportedAt: b.exportedAt,
      semesters: b.semesters,
      sectionTimes: b.sectionTimes,
      courses: b.courses,
      rules: b.rules,
      overrides: b.overrides,
      todos: todos,
      blocks: b.blocks,
      restWindows: b.restWindows,
      templates: b.templates,
      lessons: b.lessons,
    ));
  }

  /// 立即重排提醒：算出计划 → 交给系统通知 → 返回一句人话
  Future<String> _resyncReminders() async {
    final bundle = _bundle;
    if (bundle == null || bundle.semester == null) return '还没有课表，无法排提醒';
    final sem = bundle.semester!;
    final plan = planReminders(
      sem: sem,
      courses: bundle.courses,
      rules: bundle.rules,
      times: bundle.sectionTimes,
      overrides: bundle.overrides,
      todos: bundle.todos.where((t) => t.status == 'active').toList(),
      blocks: bundle.blocks,
      lessons: bundle.lessons,
      settings: _settings.reminderSettings,
      now: DateTime.now(),
    );
    try {
      final r = await syncNotifications(_notifier, plan);
      if (!r.granted) return '没有通知权限，提醒没排上（去系统设置里开一下）';
      final extra =
          r.skippedByBudget > 0 ? '，另有 ${r.skippedByBudget} 条超出额度' : '';
      return '已排 ${r.scheduled} 条提醒（系统待发 ${r.pending} 条）$extra';
    } catch (e) {
      return '排提醒失败：$e';
    }
  }

  Widget _header(BackupBundle bundle) => CourseHeader(
        sem: bundle.semester,
        week: _week,
        adjustCount: _adjustCount(bundle),
        onPrev: () => setState(() => _week = (_week - 1).clamp(1, _totalWeeks)),
        onNext: () => setState(() => _week = (_week + 1).clamp(1, _totalWeeks)),
        onToday: () => setState(() => _week =
            weekOfDate(bundle.semester!, DateTime.now()).clamp(1, _totalWeeks)),
        onSync: _manualSync,
        onExtra: () => showExtraSheet(context,
            bundle: bundle, week: _week, onChanged: _apply),
        onManage: () =>
            showCourseManager(context,
                bundle: bundle, onChanged: _apply, onImport: _import),
        onOpenAdjust: () =>
            showAdjustSheet(context, bundle: bundle, onChanged: _apply),
      );

  int get _totalWeeks => _bundle?.semester?.totalWeeks ?? 1;

  /// 本周有几条单周调整（页头的「本周调整 N」；没有就不显示）
  int _adjustCount(BackupBundle bundle) {
    final sem = bundle.semester;
    if (sem == null) return 0;
    final dates = {
      for (var d = 1; d <= 7; d++) formatDate(dateOfWeekday(sem, _week, d)),
    };
    return bundle.overrides
        .where((o) => dates.contains(o.newDate) || dates.contains(o.date))
        .length;
  }

  /// 首次启动的「要不要走一遍演练」——非模态选择的弹窗，选完记 kv（只问一次）
  Future<void> _maybePromptGuide() async {
    if (!guidePromptEnabled || _sandbox || _guidePromptShown) return;
    _guidePromptShown = true;
    final v = await widget.repo.getKv(guidePromptedKey);
    if (v != null && v.isNotEmpty) return;
    if (!mounted) return;
    // 鸿蒙端 `GuidePromptCard`：整屏薄纱 + 居中的玻璃卡（不是常规 Dialog）
    final start = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '关闭演练提示',
      barrierColor: const Color(0x8C0C121C), // rgba(12,18,28,0.55)
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, _, __) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Glass(
            sheet: true,
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('第一次用 ClassOUT？',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                const SizedBox(height: 8),
                const Text(
                    '可以在「演练」里走一遍：会建一个沙箱（里面有几门演示课和演示待办），'
                    '你随便改、随便删；退出时整个沙箱删掉，你自己的课表一点都不会动。',
                    style: TextStyle(
                        fontSize: 12, height: 1.45, color: Color(0xFFC3CDDE))),
                const SizedBox(height: 6),
                Text('共 ${guideStepCount()} 步，大约两分钟。',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF8B97AC))),
                const SizedBox(height: 14),
                _GuidePromptButton(
                  text: '开始演练',
                  background: const Color(0xFF2E6BE6),
                  foreground: Colors.white,
                  onTap: () => Navigator.of(ctx).pop(true),
                ),
                const SizedBox(height: 10),
                _GuidePromptButton(
                  text: '先自己用用',
                  background: Colors.white.withValues(alpha: 0.14),
                  foreground: const Color(0xFFC3CDDE),
                  onTap: () => Navigator.of(ctx).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await widget.repo.setKv(guidePromptedKey, '1');
    if (start == true) await _startGuide();
  }

  /// 进沙箱前把整张 kv 表记下来（退出/冷启动时整份还回去）
  ///
  /// 鸿蒙端沙箱是**另一个 .db 文件**，演练里改的偏好天然不串；安卓两端共用一个库，
  /// 不记这一份的话，演练里改的标语 / 时间范围 / 待办类型会留在真实设置里。
  Future<void> _snapshotPrefs() async {
    final kv = await widget.repo.dumpKv();
    kv.remove(sandboxBackupKey);
    kv.remove(sandboxPrefsKey);
    await widget.repo.setKv(sandboxPrefsKey, jsonEncode(kv));
  }

  /// 把 kv 整份还原成进沙箱前的样子：快照里有的写回，
  /// 沙箱期间**新写**的键删掉（鸿蒙那边它们本来就在另一个库里）
  Future<void> _restorePrefs(String raw) async {
    Map<String, String> snap;
    try {
      snap = (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (e) {
      debugPrint('[ClassOUT] sandbox prefs restore failed: $e');
      return;
    }
    const keep = <String>{sandboxBackupKey, sandboxPrefsKey, guidePromptedKey};
    final now = await widget.repo.dumpKv();
    for (final k in now.keys) {
      if (!keep.contains(k) && !snap.containsKey(k)) {
        await widget.repo.removeKv(k);
      }
    }
    for (final e in snap.entries) {
      await widget.repo.setKv(e.key, e.value);
    }
    await widget.repo.removeKv(sandboxPrefsKey);
    debugPrint('[ClassOUT] restored prefs from sandbox snapshot');
  }

  /// 进入沙箱：真实数据整份存进 kv（库表不动 kv），换成演练数据
  Future<void> _startGuide() => _withBusy(true, _startGuideWork);

  Future<void> _startGuideWork() async {
    final current = _bundle;
    if (current != null) {
      await widget.repo.setKv(sandboxBackupKey, backupToJson(current));
    }
    await _snapshotPrefs();
    // 鸿蒙沙箱是一个**全新的库**，所以演练里看到的偏好都是默认值
    // （默认渐变壁纸、默认标语、默认同步节奏、没有自定义类型…）。
    // 安卓共用一个 kv，这里显式把偏好写回默认值，退出时再整份还原（见 _restorePrefs）。
    await AppSettings().save(widget.repo);
    // 鸿蒙沙箱是**全新的库**：没有黑名单、也没有 last_gen_date
    await widget.repo.removeKv(todoBlacklistKv);
    await widget.repo.removeKv('last_gen_date');
    // 演练沙箱按"今天"现造（鸿蒙 `GuideRepo.seedDemoData` 同款），不是固定日期的演示备份
    final demo = buildDemoSandbox();
    await widget.repo.replaceAll(demo);
    if (!mounted) return;
    setState(() {
      _sandbox = true;
      _guideStep = 0;
      _tab = guideStepAt(0).tab;
    });
    await _reload();
  }

  /// 退出沙箱：还原 kv 里的真实数据与偏好，并**回到课表页**
  /// （鸿蒙 `doExitGuide` 里 `this.tab = 0` 是刻意的：让待办/计划/设置重新挂载、重读真库）
  Future<void> _exitGuide() => _withBusy(false, _exitGuideWork);

  /// 鸿蒙 `guideBusy`：切数据那一下整屏挡一下，并至少亮 320ms（真机上数据换得太快会一闪而过）
  Future<void> _withBusy(bool entering, Future<void> Function() work) async {
    if (_guideBusy) return;
    setState(() {
      _guideBusy = true;
      _guideBusyEntering = entering;
    });
    final started = DateTime.now();
    // 先让忙碌层**画出来一帧**（否则数据换得太快，它只会在同一帧里出现又消失）
    await WidgetsBinding.instance.endOfFrame;
    try {
      await work();
    } finally {
      // 真机上再补到至少 320ms：鸿蒙切库要一两秒，天然能看见；这边太快就一闪而过
      if (ambientMotion) {
        final wait = 320 - DateTime.now().difference(started).inMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      }
      if (mounted) setState(() => _guideBusy = false);
    }
  }

  Future<void> _exitGuideWork() async {
    final raw = await widget.repo.getKv(sandboxBackupKey) ?? '';
    final prefs = await widget.repo.getKv(sandboxPrefsKey) ?? '';
    if (!mounted) return;
    setState(() {
      _sandbox = false;
      _tab = 0;
    });
    if (prefs.isNotEmpty) await _restorePrefs(prefs);
    if (raw.isEmpty) {
      await _reload();
      return;
    }
    final real = BackupBundle.decode(raw);
    await widget.repo.replaceAll(real);
    await widget.repo.setKv(sandboxBackupKey, '');
    if (!mounted) return;
    await _reload();
    // 鸿蒙 `doExitGuide` 是**静默**的（只写 hilog）：不弹提示条，界面直接换回真数据。
    // 这里原来会弹一条 SnackBar（"演练结束…"），两端截图一比就多出一条。
  }

  void _goToStep(int index) {
    setState(() {
      _guideStep = index.clamp(0, guideStepCount() - 1);
      _tab = guideStepAt(_guideStep).tab;
    });
  }

  /// 下课自动生成待办：把 last_gen_date 到现在之间已经下课的课时，
  /// 按课程模板生成「待确认」待办（去重键 course|date|template，见 domain/todo_generator.dart）
  Future<void> _generateMissed(BackupBundle data) async {
    final sem = data.semester;
    if (sem == null || data.templates.isEmpty) return;
    final last = await widget.repo.getKv('last_gen_date') ?? '';
    final black = await loadBlacklist(widget.repo);
    final outcome = generateMissedTodos(
      sem: sem,
      courses: data.courses,
      rules: data.rules,
      overrides: data.overrides,
      times: data.sectionTimes,
      templates: data.templates,
      todos: data.todos,
      lastGenDate: last,
      now: DateTime.now(),
      nextId: data.todos.fold<int>(0, (m, t) => t.id > m ? t.id : m),
      blacklist: black,
    );
    await widget.repo.setKv('last_gen_date', outcome.lastGenDate);
    if (outcome.created.isEmpty || !mounted) return;
    setState(() {
      _bundle = BackupBundle(
        app: data.app,
        version: data.version,
        exportedAt: data.exportedAt,
        semesters: data.semesters,
        sectionTimes: data.sectionTimes,
        courses: data.courses,
        rules: data.rules,
        overrides: data.overrides,
        todos: [...data.todos, ...outcome.created],
        blocks: data.blocks,
        restWindows: data.restWindows,
        templates: data.templates,
        lessons: data.lessons,
      );
    });
    await widget.repo.replaceAll(_bundle!);
  }

  /// 「试一条提醒」：10 秒后弹一条系统通知（真机验证权限/锁屏/免打扰用）
  Future<String> _testReminder() async {
    try {
      final ok = await _notifier.ensurePermission();
      if (!ok) return '没有通知权限，去系统设置里开一下';
      // 先立刻弹一条：如果这条也不出现，说明是系统把通知拦了（不是排期问题）
      await _notifier.showNow(PlannedNotification(
        id: 9000,
        at: DateTime.now(),
        title: 'ClassOUT 自检通知',
        body: '如果你看到了这条，说明通知权限没问题',
        kind: 'test',
      ));
      await _notifier.schedule(PlannedNotification(
        id: 9001,
        at: DateTime.now().add(const Duration(seconds: 10)),
        title: 'ClassOUT 测试提醒',
        body: '看到这条就说明通知排上了（10 秒后弹出）',
        kind: 'test',
      ));
      return '10 秒后弹一条测试提醒';
    } catch (e) {
      return '测试提醒失败：$e';
    }
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    // 让「正在与日历同步」至少露一下脸（真机上重排可能几毫秒就完事）
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _resyncReminders();
    if (!mounted) return;
    setState(() => _syncing = false);
    // 鸿蒙 `doCalendarSync` 只把结果写 hilog，界面只有页头那条「正在与日历同步」；
    // 原来这里还弹一条完成 SnackBar，是与鸿蒙多出来的东西（§112 同款问题）。
  }

  Future<void> _applySettings(AppSettings next) async {
    setState(() => _settings = next);
    await next.save(widget.repo);
  }

  /// 导入：弹导入框 → 整份覆盖 → 刷新。
  ///
  /// 返回导入的那份数据，让「备份与恢复」子页像鸿蒙 `BackupView` 一样
  /// 在页内显示一行「已从备份恢复：…」（不弹提示条、也不关页）。
  Future<BackupBundle?> _import() async {
    final bundle = await showImportDialog(context, picker: widget.backupPicker);
    if (bundle == null) return null;
    await widget.repo.replaceAll(bundle);
    // 鸿蒙 `BackupRepo.restore` 会 `DELETE FROM todo_blacklist`：整份覆盖时黑名单一起清
    await widget.repo.removeKv(todoBlacklistKv);
    await _reload();
    return bundle;
  }

  @override
  Widget build(BuildContext context) {
    final app = _buildWithBoot(context);
    final base = !_sandbox
        ? app
        // 演练引导条：浮在导航栏上方（鸿蒙端 GuideBar 也是这样压在内容上）
        : Stack(
            children: [
              Positioned.fill(child: app),
              Positioned(
                left: floatSide,
                right: floatSide,
                bottom: tabBarInset + floatGap,
                child: GuideBar(
                  step: _guideStep,
                  onPrev: () => _goToStep(prevGuideStep(_guideStep)),
                  onNext: () {
                    if (isLastGuideStep(_guideStep)) {
                      _exitGuide();
                    } else {
                      _goToStep(nextGuideStep(_guideStep));
                    }
                  },
                  onExit: _exitGuide,
                ),
              ),
            ],
          );
    if (!_guideBusy) return base;
    // 鸿蒙 `GuideBusyLayer`：整屏压暗 + 中间一条玻璃卡片（"正在准备演练…" / "正在恢复你的课表…"）
    return Stack(
      children: [
        Positioned.fill(child: base),
        Positioned.fill(
          child: ColoredBox(
            color: const Color(0x8C0C121C),
            child: Center(
              child: Glass(
                sheet: true,
                padding: const EdgeInsets.all(18),
                child: Text(
                    _guideBusyEntering ? '正在准备演练…' : '正在恢复你的课表…',
                    style: const TextStyle(fontSize: 13, color: inkPrimary)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWithBoot(BuildContext context) {
    // 测试/截图（ambientMotion=false）不播启动流程：直接给应用本体
    if (!ambientMotion) return _buildApp(context);
    return Stack(
      children: [
        Positioned.fill(child: _buildApp(context)),
        if (_bootVisible)
          Positioned.fill(
            child: BootScreen(
              step: _bootStep,
              motto: normalMotto(_settings.motto),
              ready: _bootReady,
              onReveal: () {}, // 应用本体一直挂在下层，扩张时自然露出
              onDone: () {
                if (!mounted) return;
                setState(() => _bootVisible = false);
                _maybePromptGuide();
              },
            ),
          ),
      ],
    );
  }

  Widget _buildApp(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('读数据出错：\n$_error', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final bundle = _bundle;
    if (bundle == null || bundle.semester == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text('还没有课表', style: TextStyle(fontSize: 18, color: inkPrimary)),
              SizedBox(height: 8),
              Text('用右上角的「导入」把备份粘进来',
                  style: TextStyle(fontSize: 12, color: inkTertiary)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AppFrame(
              tab: _tab,
              onTab: (i) {
                final was = _tab;
                setState(() => _tab = i);
                // 用户 2026-10-16：「每次切换到待办列时，立即补生成下课列表」
                if (i == 1 && was != 1 && _bundle != null) {
                  _generateMissed(_bundle!);
                }
              },
              wallpaperPath: _settings.wallpaperPath,
              wallpaperFocus: _settings.wallpaperFocus,
              // 课表 / 待办 / 计划 三页共用同一条页头（鸿蒙端 FloatingBars），
              // 设置页没有它 —— 那些是课表页的导航控件。
              child: _tab == 3
                  ? SettingsPage(
                      bundle: bundle,
                      onChanged: _apply,
                      settings: _settings,
                      onSettingsChanged: _applySettings,
                      onResyncReminders: _resyncReminders,
                      onTestReminder: _testReminder,
                      onStartGuide: () async {
                        Navigator.of(context).maybePop();
                        await _startGuide();
                      })
                  // 课表 / 待办 / 计划：页头都是**悬浮浮窗**，内容从它下面滑过
                  // （计划页自己的日期条由 PlanPage 叠在页头下面）
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: switch (_tab) {
                            0 => TimetablePage(
                                bundle: bundle,
                                week: _week,
                                topInset: _headerH,
                                onOpenSession: (s) => showSessionSheet(context,
                                    bundle: bundle,
                                    session: s,
                                    onChanged: _apply),
                              ),
                            1 => TodoPage(
                                bundle: bundle,
                                onChanged: _apply,
                                topInset: _headerH,
                                customCategories: _settings.customCategories,
                                onAddCategory: (name) {
                                  _settings.customCategories = addCustomCategory(
                                      _settings.customCategories, name);
                                  _settings.save(widget.repo).then((_) {
                                    if (mounted) setState(() {});
                                  });
                                }),
                            _ => PlanPage(
                                bundle: bundle,
                                onChanged: _apply,
                                topInset: _headerH,
                                window: _settings.planWindow,
                                restWindows: bundle.restWindows,
                                onOpenTodo: _openTodoById),
                          },
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          child: MeasureSize(
                            onSize: (size) {
                              if ((size.height - _headerH).abs() > 0.5) {
                                setState(() => _headerH = size.height);
                              }
                            },
                            child: _header(bundle),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          // 同步中：顶部一条玻璃提示（鸿蒙端 SyncToast：5 点点阵 + 两行字，贴浮窗下面）
          if (_syncing)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(child: _SyncToast()),
            ),
        ],
      ),
    );
  }
}

/// 演练提示卡里的整宽按钮（鸿蒙端默认 Button：高 40、圆角胶囊）
class _GuidePromptButton extends StatelessWidget {
  final String text;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  const _GuidePromptButton({
    required this.text,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: foreground)),
      ),
    );
  }
}

/// 「正在与系统日历同步…」提示条（鸿蒙端 `SyncToast`）：
/// 5 个点依次亮起（只动 opacity/scale，关掉动画时保持半亮）+ 两行说明。
class _SyncToast extends StatefulWidget {
  const _SyncToast();

  @override
  State<_SyncToast> createState() => _SyncToastState();
}

class _SyncToastState extends State<_SyncToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 660),
  );

  @override
  void initState() {
    super.initState();
    if (theme.motionOn) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(floatSide, MediaQuery.of(context).padding.top + floatGap, floatSide, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: Glass(
          sheet: true,
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _c,
                builder: (_, __) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 5; i++) ...[
                      if (i > 0) const SizedBox(width: 9),
                      Transform.scale(
                        scale: theme.motionOn
                            ? 0.85 + 0.33 * _dotPhase(i)
                            : 0.85,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            // 鸿蒙：亮度 0.18 ↔ 1 与缩放同步呼吸
                            color: const Color(0xFF7FA8FF).withValues(
                                alpha: theme.motionOn ? _dotPhase(i) : 0.55),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text('正在与系统日历同步…',
                  style: TextStyle(fontSize: 12, color: inkPrimary)),
              const SizedBox(height: 2),
              const Text('把上课与截止提醒重排一遍，避免漏提醒',
                  style: TextStyle(fontSize: 10, color: Color(0xFF8B97AC))),
            ],
          ),
        ),
      ),
    );
  }

  /// 第 i 个点的亮度相位（opacity 0.18 → 1），错开 140ms 依次亮
  double _dotPhase(int i) {
    if (!theme.motionOn) return 0.55;
    final t = (_c.value + i * 0.21) % 1.0;
    return 0.18 + 0.82 * (t < 0.5 ? t * 2 : (1 - t) * 2);
  }
}
