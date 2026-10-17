// 应用外壳：负责「读数据 → 画界面 → 导入后重画」。
// 数据仓库是注入的，所以 web 用内存版、原生用 SQLite 版都能跑同一套 UI。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/backup.dart';
import '../data/backup_export.dart';
import '../data/note_pref.dart';
import '../data/repo.dart';
import '../data/settings.dart';
import '../domain/reminders.dart';
import '../domain/dates.dart';
import '../domain/guide.dart';
import '../domain/motto.dart';
import '../domain/timetable.dart';
import '../domain/todo_generator.dart';
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

class _HomeShellState extends State<HomeShell> {
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

  /// 新手演练：是否在沙箱里、走到第几步、这次运行里问过没有
  bool _sandbox = false;
  int _guideStep = 0;
  bool _guidePromptShown = false;

  /// 当前周次（页头 ‹ › 改它；课表页照着画）
  int _week = 1;
  late final ReminderNotifier _notifier = widget.notifier ?? FlutterNotifier();

  @override
  void initState() {
    super.initState();
    _reload(boot: true);
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
      final settings = await AppSettings.load(widget.repo);
      var data = await widget.repo.load();
      if (data == null && widget.fallback != null) {
        await widget.repo.replaceAll(widget.fallback!);
        data = await widget.repo.load();
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
    setState(() => _bundle = next);
    await widget.repo.replaceAll(next);
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
            showCourseManager(context, bundle: bundle, onChanged: _apply),
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
    final start = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xF20C101A),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadius)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('先走一遍演练？',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const SizedBox(height: 6),
              const Text(
                  '演练用的是 4 门演示课，怎么点都不会动到你自己的数据；'
                  '退出时演练数据整份删掉。',
                  style: TextStyle(
                      fontSize: 12, height: 1.45, color: Color(0xFFC3CDDE))),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFA9B5C9)),
                    child: const Text('先自己用用', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E6BE6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                    ),
                    child: const Text('开始演练', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await widget.repo.setKv(guidePromptedKey, '1');
    if (start == true) await _startGuide();
  }

  /// 进入沙箱：真实数据整份存进 kv（库表不动 kv），换成演练数据
  Future<void> _startGuide() async {
    final current = _bundle;
    if (current != null) {
      await widget.repo.setKv(sandboxBackupKey, backupToJson(current));
    }
    final demo = BackupBundle.decode(
        await rootBundle.loadString('assets/demo_backup.json'));
    await widget.repo.replaceAll(demo);
    if (!mounted) return;
    setState(() {
      _sandbox = true;
      _guideStep = 0;
      _tab = guideStepAt(0).tab;
    });
    await _reload();
  }

  /// 退出沙箱：还原 kv 里的真实数据并删掉那份备份
  Future<void> _exitGuide({required bool completed}) async {
    final raw = await widget.repo.getKv(sandboxBackupKey) ?? '';
    if (!mounted) return;
    setState(() => _sandbox = false);
    if (raw.isEmpty) {
      await _reload();
      return;
    }
    final real = BackupBundle.decode(raw);
    await widget.repo.replaceAll(real);
    await widget.repo.setKv(sandboxBackupKey, '');
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(completed ? '演练结束，已回到你自己的课表' : '已退出演练')));
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
      );
    });
    await widget.repo.replaceAll(_bundle!);
  }

  /// 「试一条提醒」：10 秒后弹一条系统通知（真机验证权限/锁屏/免打扰用）
  Future<String> _testReminder() async {
    try {
      final ok = await _notifier.ensurePermission();
      if (!ok) return '没有通知权限，去系统设置里开一下';
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
    final msg = await _resyncReminders();
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _applySettings(AppSettings next) async {
    setState(() => _settings = next);
    await next.save(widget.repo);
  }

  Future<void> _import() async {
    final bundle = await showImportDialog(context, picker: widget.backupPicker);
    if (bundle == null) return;
    await widget.repo.replaceAll(bundle);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入：${bundle.semester?.name ?? ''}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = _buildWithBoot(context);
    if (!_sandbox) return app;
    // 演练引导条：浮在导航栏上方（鸿蒙端 GuideBar 也是这样压在内容上）
    return Stack(
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
                _exitGuide(completed: true);
              } else {
                _goToStep(nextGuideStep(_guideStep));
              }
            },
            onExit: () => _exitGuide(completed: false),
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
                if (i == 1 && was != 1 && _bundle != null)
                  _generateMissed(_bundle!);
              },
              wallpaperPath: _settings.wallpaperPath,
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
                      onImport: _import,
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
                                customCategories: _settings.customCategories),
                            _ => PlanPage(
                                bundle: bundle,
                                onChanged: _apply,
                                topInset: _headerH,
                                window: _settings.planWindow,
                                restWindows: bundle.restWindows),
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
          // 同步中：顶部一条玻璃提示（鸿蒙端也是"页面上方弹出同步提示"）
          if (_syncing)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Glass(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text('正在与日历同步…',
                          style: TextStyle(fontSize: 12, color: inkPrimary)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
