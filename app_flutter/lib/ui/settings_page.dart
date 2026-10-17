// 设置页（第一版）：同步节奏 / 计划时间范围 / 待办类型 / 不可排时段 / 关于。
//
// 设置项分两类：
//  - **kv 类**（同步节奏、时间范围、自定义类型、标语）→ AppSettings，经 repo 持久化；
//  - **数据类**（不可排时段 rest_window 表）→ 跟 bundle 一起整份写回。

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/wallpaper.dart';
import '../data/settings.dart';
import '../domain/categories.dart';
import '../domain/dates.dart';
import '../domain/motto.dart';
import '../domain/plan_math.dart';
import '../domain/sync_cadence.dart';
import '../domain/validate.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'inline_toast.dart';
import 'privacy_page.dart';
import 'wallpaper_adjust.dart';
import 'palette.dart';
import 'theme.dart' as theme;

const String appVersion = '0.2.0';

class SettingsPage extends StatefulWidget {
  final BackupBundle bundle;

  final void Function(BackupBundle next) onChanged;
  final AppSettings settings;
  final void Function(AppSettings next) onSettingsChanged;

  /// 立即重排提醒（由外壳注入：它才知道仓库与通知实现）；返回给用户看的结果文案
  final Future<String> Function()? onResyncReminders;

  /// 发一条 10 秒后的测试提醒（真机验证通知权限/锁屏用）
  final Future<String> Function()? onTestReminder;

  /// 重新走一遍新手演练（沙箱 + 引导条）
  final Future<void> Function()? onStartGuide;

  const SettingsPage({
    super.key,
    required this.bundle,
    required this.onChanged,
    required this.settings,
    required this.onSettingsChanged,
    this.onResyncReminders,
    this.onTestReminder,
    this.onStartGuide,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with InlineToastMixin {
  late final AppSettings _s = widget.settings;
  late List<RestWindow> _rest = _effectiveRest();

  /// 「设置」标题条实测高度（悬浮浮窗：内容从它下面滑过）
  double _barH = 56;

  // ---- 「提醒」卡的草稿（鸿蒙端 remSettings：点「保存提醒设置」才落库）----
  late bool _briefOn = _s.briefEnabled;
  late int _briefMin = _s.briefMin;
  late int _classLead = _s.classLeadMin;

  // ---- 「不可排时段」卡的行内表单（鸿蒙端 newRestLabel / newRestWeekday / newRestStart / newRestEnd）----
  String _restLabel = '';
  int _restWeekday = 0;
  int _restStartMin = 12 * 60;
  int _restEndMin = 13 * 60;
  String _restPending = '';
  String _restError = '';

  // ---- 「待办类型」卡的草稿与删除确认 ----
  String _catDraft = '';
  String _catError = '';
  String _catPending = '';
  int _catPendingCount = 0;

  List<RestWindow> _effectiveRest() {
    if (widget.bundle.restWindows.isNotEmpty) {
      return List.of(widget.bundle.restWindows);
    }
    return [
      for (final w in defaultRestWindows())
        RestWindow(
            weekday: 0,
            startMin: w.$1,
            endMin: w.$2,
            label: _defaultRestLabel(w.$1)),
    ];
  }

  static String _defaultRestLabel(int startMin) {
    if (startMin >= 23 * 60) return '睡觉';
    if (startMin >= 17 * 60) return '晚饭';
    if (startMin >= 12 * 60) return '午休';
    return '睡觉';
  }

  void _saveSettings() {
    widget.onSettingsChanged(_s);
    setState(() {});
  }


  BackupBundle _withRest(List<RestWindow> rest) {
    final b = widget.bundle;
    return BackupBundle(
      app: b.app,
      version: b.version,
      exportedAt: b.exportedAt,
      semesters: b.semesters,
      sectionTimes: b.sectionTimes,
      courses: b.courses,
      rules: b.rules,
      overrides: b.overrides,
      todos: b.todos,
      blocks: b.blocks,
      restWindows: rest,
      templates: b.templates,
      lessons: b.lessons,
    );
  }

  void _saveRest() {
    widget.onChanged(_withRest(_rest));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 内容从悬浮标题条下面滑过；底部给悬浮导航栏让位
        Positioned.fill(
          child: SingleChildScrollView(
            // 鸿蒙：`top: 12 + topInset + titleH + FLOAT_GAP`（设置页 topInset = 0），
            // `bottom: 30 + bottomInset`。_barH 是"上缝 + 标题条 + 下缝"的实测高度，
            // 所以这里等价于 `12 + 标题条高 + 下缝`。
            padding: EdgeInsets.fromLTRB(
                16, 12 + _barH - floatTop, 16, 30 + tabBarInset - floatGap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                toastLine(),
                _WallpaperCard(
                  path: _s.wallpaperPath,
                  focus: _s.wallpaperFocus,
                  onPick: _pickWallpaper,
                  onReset: _resetWallpaper,
                  onAdjust: _adjustWallpaper,
                  onCenter: _centerWallpaper,
                ),
                _MottoCard(
                    settings: _s, onSave: _saveSettings, onToast: showToast),
                _MotionCard(
                  enabled: _s.motionEnabled,
                  onChanged: (v) {
                    _s.motionEnabled = v;
                    theme.motionOn = v;
                    _saveSettings();
                    showToast(v ? '动画已开启' : '动画已关闭（所有动效直接切换）');
                  },
                ),
                _reminderCard(),
                _syncCard(),
                _restCard(),
                _categoryCard(),
                _planWindowCard(),
                _guideCard(),
                _aboutCard(),
              ],
            ),
          ),
        ),
        // 设置页自己的标题条（鸿蒙端 SettingsPage 内部浮动的那一条）
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: MeasureSize(
            onSize: (size) {
              if ((size.height - _barH).abs() > 0.5) {
                setState(() => _barH = size.height);
              }
            },
            child: Glass(
              margin: const EdgeInsets.fromLTRB(
                  floatSide, floatTop, floatSide, floatGap),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: const [
                  Text('设置',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- 提醒 / 日历同步 / 不可排时段 / 待办类型 / 时间范围 / 引导 / 关于 ----------------

  /// 鸿蒙端 `ChipButton` 的横排容器（Flex wrap）
  Widget _chips(List<Widget> children) => Wrap(
        spacing: 8,
        runSpacing: 4,
        children: children,
      );

  Widget _reminderCard() {
    return _Card(
      title: '提醒',
      description: '提醒写在系统通知里（不是后台常驻）；每次启动 App 会把未来一段时间的提醒重排一遍。'
          '到点没看到提示时，先看系统是不是开了「免打扰」——开着时通知会被静音或收起。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('每日简报',
                        style: TextStyle(fontSize: 14, color: inkPrimary)),
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text('每天一条：今天几节课 + 今天截止什么',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF94A0B5))),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _briefOn,
                activeThumbColor: const Color(0xFF2E6BE6),
                onChanged: (v) => setState(() => _briefOn = v),
              ),
            ],
          ),
          if (_briefOn) ...[
            const _FieldLabel('简报时间'),
            _chips([
              for (final m in const [390, 420, 450, 480, 540, 720])
                _Choice(
                  key: ValueKey('brief-$m'),
                  text: minToHHmm(m),
                  selected: _briefMin == m,
                  onTap: () => setState(() => _briefMin = m),
                ),
            ]),
          ],
          const _FieldLabel('上课提前多久提醒'),
          _chips([
            for (final m in const [5, 10, 15, 20, 30, 45])
              _Choice(
                key: ValueKey('lead-$m'),
                text: '$m 分钟',
                selected: _classLead == m,
                onTap: () => setState(() => _classLead = m),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: GestureDetector(
              key: const ValueKey('save-reminder'),
              onTap: _saveReminder,
              // 长按 = 安卓专属的提醒诊断（重排 / 试一条）；鸿蒙端没有这两项，
              // 所以不放在界面上，免得破坏 1:1
              onLongPress: _reminderDiagnostics,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 40,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E6BE6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('保存提醒设置',
                    // 鸿蒙是默认 Button（16）
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _saveReminder() {
    _s.briefEnabled = _briefOn;
    _s.briefMin = _briefMin;
    _s.classLeadMin = _classLead;
    _saveSettings();
    final resync = widget.onResyncReminders;
    if (resync == null) {
      showToast('提醒设置已保存');
      return;
    }
    resync().then((msg) => showToast('提醒设置已保存 · $msg'));
  }

  Future<void> _reminderDiagnostics() async {
    if (widget.onResyncReminders == null && widget.onTestReminder == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141B2A),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onResyncReminders != null)
              ListTile(
                leading: const Icon(Icons.notifications_active,
                    color: Color(0xFF7FA8FF)),
                title: const Text('立即重排提醒'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(ctx);
                  Navigator.pop(ctx);
                  final msg = await widget.onResyncReminders!();
                  messenger.showSnackBar(SnackBar(content: Text(msg)));
                },
              ),
            if (widget.onTestReminder != null)
              ListTile(
                leading:
                    const Icon(Icons.notifications, color: Color(0xFF7FA8FF)),
                title: const Text('试一条提醒（10 秒后）'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(ctx);
                  Navigator.pop(ctx);
                  final msg = await widget.onTestReminder!();
                  messenger.showSnackBar(SnackBar(content: Text(msg)));
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _syncCard() {
    return _Card(
      title: '日历同步',
      description: '连续使用到 ${_s.syncIntervalMin} 分钟的整数倍时会自动同步一次（页面上方会弹出提示）；'
          '闲置超过 ${_s.syncIntervalMin} 分钟后再次打开，App 会重新启动一次，好让提醒始终是最新的。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chips([
            for (final m in syncIntervalChoices)
              _Choice(
                key: ValueKey('sync-$m'),
                text: '$m 分钟',
                selected: _s.syncIntervalMin == m,
                onTap: () {
                  _s.syncIntervalMin = m;
                  _saveSettings();
                },
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                '当前：每 ${_s.syncIntervalMin} 分钟同步一次（默认 $syncIntervalDefault 分钟）',
                style:
                    const TextStyle(fontSize: 11, color: Color(0xFF8B97AC))),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('页头「⟳ 立即与日历同步」可以随时手动同步一次。',
                style: TextStyle(fontSize: 11, color: Color(0xFF8B97AC))),
          ),
        ],
      ),
    );
  }

  String _weekdayText(int wd) => wd == 0 ? '每天' : '周${weekdayCn[wd - 1]}';

  Widget _restCard() {
    return _Card(
      title: '不可排时段',
      description: '「一键找空档」会跳过这些时段（午休、吃饭、睡觉…）。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_rest.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('还没有设置。加几条之后，一键找空档就不会把待办排到饭点或深夜。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8B97AC))),
            ),
          for (final w in _rest) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(w.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFFF2F5FA))),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text(_weekdayText(w.weekday),
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFFA9B5C9))),
                        ),
                        Expanded(
                          child: Text(
                              '${minToHHmm(w.startMin)} – ${minToHHmm(w.endMin)}',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFFA9B5C9))),
                        ),
                        GestureDetector(
                          onTap: () => setState(() => _restPending = '${w.id}'),
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text('删',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFFFF8080))),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_restPending == '${w.id}')
                    _DeleteConfirmRow(
                      message: '确定删除「${w.label} ${_weekdayText(w.weekday)}」？',
                      onCancel: () => setState(() => _restPending = ''),
                      onConfirm: () {
                        setState(() {
                          _rest = _rest.where((x) => x.id != w.id).toList();
                          _restPending = '';
                        });
                        _saveRest();
                      },
                    ),
                ],
              ),
            ),
          ],
          const _FieldLabel('名称'),
          _InputBox(
            key: const ValueKey('rest-label'),
            hint: '午休',
            onChanged: (v) => setState(() => _restLabel = v),
          ),
          const _FieldLabel('适用哪天'),
          _chips([
            _Choice(
              text: '每天',
              selected: _restWeekday == 0,
              onTap: () => setState(() => _restWeekday = 0),
            ),
            for (var wd = 1; wd <= 7; wd++)
              _Choice(
                text: '周${weekdayCn[wd - 1]}',
                selected: _restWeekday == wd,
                onTap: () => setState(() => _restWeekday = wd),
              ),
          ]),
          const _FieldLabel('时间'),
          _restTimeRow('开始', _restStartMin, (m) => _restStartMin = m),
          _restTimeRow('结束', _restEndMin, (m) => _restEndMin = m),
          if (_restError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_restError,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFFFF8A8A))),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _PillBtn(
              key: const ValueKey('rest-add'),
              text: '添加',
              background: const Color(0xFF2E6BE6),
              foreground: Colors.white,
              onTap: _addRest,
            ),
          ),
        ],
      ),
    );
  }

  Widget _restTimeRow(String label, int minute, void Function(int) apply) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF94A0B5))),
          ),
          Expanded(
            child: Text(minToHHmm(minute),
                style:
                    const TextStyle(fontSize: 15, color: Color(0xFFF2F5FA))),
          ),
          GestureDetector(
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
              );
              if (picked == null) return;
              setState(() => apply(picked.hour * 60 + picked.minute));
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text('选择…',
                  style: TextStyle(fontSize: 12, color: Color(0xFF7FA8FF))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryCard() {
    return _Card(
      title: '待办类型',
      description:
          '内置的四个不能删；自定义的可以加、可以删（最多 $categoryMaxCount 个）。'
          '删掉一个类型时，用了它的待办会改成「无」。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('内置',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
          const SizedBox(height: 6),
          _chips([
            for (final o in builtinCategoryOptions())
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(o.label,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFA9B5C9))),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text('自定义（${_s.customCategories.length}）',
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
          ),
          if (_s.customCategories.isEmpty)
            const Text('还没有自定义类型。下面加一个，或者直接在待办编辑窗里点「＋新建类型」。',
                style: TextStyle(fontSize: 12, color: Color(0xFF8B97AC))),
          for (final name in _s.customCategories) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(name,
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFFF2F5FA))),
                        ),
                        GestureDetector(
                          onTap: () {
                            final n = widget.bundle.todos
                                .where((t) => t.category == name)
                                .length;
                            setState(() {
                              _catPending = name;
                              _catPendingCount = n;
                            });
                          },
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text('删',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFFFF8080))),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_catPending == name)
                    _DeleteConfirmRow(
                      message: _catPendingCount > 0
                          ? '确定删除「$name」？$_catPendingCount 条待办会改成「无」。'
                          : '确定删除「$name」？',
                      onCancel: () => setState(() {
                        _catPending = '';
                        _catPendingCount = 0;
                      }),
                      onConfirm: () {
                        setState(() {
                          _s.customCategories = removeCustomCategory(
                              _s.customCategories, name);
                          _catPending = '';
                          _catPendingCount = 0;
                        });
                        _saveSettings();
                      },
                    ),
                ],
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                Expanded(
                  child: _InputBox(
                    key: const ValueKey('cat-input'),
                    hint: '新类型名（最多 $categoryNameMax 个字）',
                    onChanged: (v) => setState(() {
                      _catDraft = v;
                      _catError = '';
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                _PillBtn(
                  key: const ValueKey('cat-add'),
                  text: '添加',
                  height: 40,
                  fontSize: 13,
                  background: const Color(0xFF2E6BE6),
                  foreground: Colors.white,
                  onTap: _addCategory,
                ),
              ],
            ),
          ),
          if (_catError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_catError,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFFFF8A8A))),
            ),
        ],
      ),
    );
  }

  Widget _planWindowCard() {
    return _Card(
      title: '计划页时间范围',
      description: '计划网格画哪一段（上下限），按整半小时调。它只管显示范围，和「不可排时段」是两件事。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final isStart in [true, false])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(isStart ? '上边界（最早）' : '下边界（最晚）',
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFFF2F5FA))),
                  ),
                  _stepButton('‹', () => _shiftWindow(start: isStart ? -30 : 0, end: isStart ? 0 : -30)),
                  SizedBox(
                    width: 64,
                    child: Text(
                        minToHHmm(isStart
                            ? _s.planWindow.startMin
                            : _s.planWindow.endMin),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 14, color: Color(0xFFEAF0FA))),
                  ),
                  _stepButton('›', () => _shiftWindow(start: isStart ? 30 : 0, end: isStart ? 0 : 30)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '当前：${minToHHmm(_s.planWindow.startMin)} – ${minToHHmm(_s.planWindow.endMin)}'
                '（共 ${((_s.planWindow.endMin - _s.planWindow.startMin) / 60).toStringAsFixed(1)} 小时）',
                style:
                    const TextStyle(fontSize: 11, color: Color(0xFF8B97AC))),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: GestureDetector(
              onTap: () {
                _s.planWindow = defaultWindow;
                _saveSettings();
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 32,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text('恢复默认 07:00–24:00',
                    style: TextStyle(fontSize: 12, color: Color(0xFFC3CDDE))),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                '最窄 ${windowMinSpan ~/ 60} 小时；最晚到 ${minToHHmm(windowMaxEnd)}。',
                style:
                    const TextStyle(fontSize: 10, color: Color(0xFF7C8798))),
          ),
        ],
      ),
    );
  }

  Widget _stepButton(String glyph, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 38,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Text(glyph,
            style: const TextStyle(fontSize: 15, color: Color(0xFF7FA8FF))),
      ),
    );
  }

  Widget _guideCard() {
    return _Card(
      title: '新手引导',
      description: '第一次上手？可以在「演练」里走一遍：会开一个沙箱（几门演示课 + 演示待办），'
          '你随便改、随便删，退出时整份丢弃。',
      footnote: '演练期间右下角会有一条「第 n/N 步」的引导条，跟着点就行；随时可以「退出演练」。',
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _PillBtn(
          key: const ValueKey('settings-guide'),
          text: '开始演练',
          fontSize: 14, // 鸿蒙这颗显式写了 fontSize(14)
          background: const Color(0xFF2E6BE6),
          foreground: Colors.white,
          onTap: () => widget.onStartGuide?.call(),
        ),
      ),
    );
  }

  Widget _aboutCard() {
    return _Card(
      title: '关于',
      description: '本应用纯离线运行：不联网、不上传、不需要账号，也不收集任何信息。',
      footnote: '隐私政策正文也在仓库根目录的 PRIVACY.md（应用市场里填链接用那份）。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('ClassOUT',
                    style: TextStyle(fontSize: 14, color: Color(0xFFF2F5FA))),
              ),
              Text('v$appVersion',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF8B97AC))),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('settings-privacy'),
                    onTap: () => showPrivacyPage(context),
                    behavior: HitTestBehavior.opaque,
                    child: const Text('隐私政策',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFF7FA8FF))),
                  ),
                ),
                const Text('MIT 许可',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8B97AC))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _addRest() {
    final label = _restLabel.trim().isEmpty ? '休息' : _restLabel.trim();
    final draft = RestWindow(
      id: _rest.fold<int>(0, (m, w) => w.id > m ? w.id : m) + 1,
      weekday: _restWeekday,
      startMin: _restStartMin,
      endMin: _restEndMin,
      label: label,
    );
    final verdict = validateRestWindow(draft);
    if (!verdict.ok) {
      setState(() => _restError = verdict.message);
      return;
    }
    setState(() {
      _rest = [..._rest, draft];
      _restLabel = '';
      _restError = '';
    });
    _saveRest();
    showToast('已添加不可排时段');
  }

  void _addCategory() {
    final name = _catDraft.trim();
    final verdict = validateCategoryName(name, _s.customCategories);
    if (!verdict.ok) {
      setState(() => _catError = verdict.message);
      return;
    }
    setState(() {
      _s.customCategories = addCustomCategory(_s.customCategories, name);
      _catDraft = '';
      _catError = '';
    });
    _saveSettings();
  }

  // ---------------- 壁纸 ----------------

  Future<void> _pickWallpaper() async {
    try {
      final path = await pickAndSaveWallpaper();
      if (path == null) return;
      final old = _s.wallpaperPath;
      _s.wallpaperPath = path;
      _saveSettings();
      if (old.isNotEmpty && old != path) await clearWallpaper(old);
      showToast('背景已换（所有玻璃面跟着变）');
    } catch (e) {
      if (!mounted) return;
      showToast('选图失败：$e');
    }
  }

  /// 「调整位置 / 区域」：全屏拖动/缩放，保存后立刻重绘所有玻璃面
  Future<void> _adjustWallpaper() async {
    final path = _s.wallpaperPath;
    if (path.isEmpty) return;
    // 再进调整页要停在**保存时的构图**（鸿蒙 `openAdjust` 从存的值起）
    final next = await showWallpaperAdjust(context,
        path: path, focus: _s.wallpaperFocus);
    if (next == null) return;
    _s.wallpaperFocus = next;
    _saveSettings();
    showToast('背景位置已保存（所有页面立刻生效）');
  }

  /// 「居中」：位置归零、缩放回 1
  void _centerWallpaper() {
    _s.wallpaperFocus = '0,0,1';
    _saveSettings();
  }

  Future<void> _resetWallpaper() async {
    final old = _s.wallpaperPath;
    _s.wallpaperPath = '';
    _saveSettings();
    await clearWallpaper(old);
    showToast('已恢复默认渐变背景');
  }

  void _shiftWindow({int start = 0, int end = 0}) {
    final w = TimeWindow(
      (_s.planWindow.startMin + start).clamp(windowMinStart, windowMaxEnd),
      (_s.planWindow.endMin + end).clamp(windowMinStart, windowMaxEnd),
    );
    _s.planWindow = normalizeWindow(w);
    _saveSettings();
  }

}

/// 胶囊输入框（鸿蒙端裸 `TextInput`：高 40、圆角 20、无边框）
class _InputBox extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const _InputBox(
      {super.key, required this.hint, required this.onChanged});

  @override
  State<_InputBox> createState() => _InputBoxState();
}

class _InputBoxState extends State<_InputBox> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(),
      child: TextField(
        controller: _ctrl,
        style: const TextStyle(fontSize: 15, color: inkPrimary),
        cursorColor: accentBlue,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: widget.hint,
          hintStyle:
              const TextStyle(fontSize: 15, color: Color(0xFF8B97AC)),
        ),
      ),
    );
  }
}

/// 行内二次确认（鸿蒙端 `DeleteConfirmRow`）：一句红字 + 取消 / 删除
class _DeleteConfirmRow extends StatelessWidget {
  final String message;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  const _DeleteConfirmRow(
      {required this.message, required this.onCancel, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFFF8A8A))),
          ),
          GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('取消',
                  style: TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
            ),
          ),
          GestureDetector(
            onTap: onConfirm,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFD64545),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('删除',
                  style: TextStyle(fontSize: 12, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置页的一张玻璃卡（鸿蒙端 `glassPanelCard` + SectionTitle）：
/// 标题 16 / 说明 12 / 内容 / 脚注 11
class _Card extends StatelessWidget {
  final String title;
  final String description;
  final String? footnote;
  final Widget child;
  const _Card({
    required this.title,
    required this.description,
    required this.child,
    this.footnote,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Glass(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: inkPrimary)),
            const SizedBox(height: 3),
            Text(description,
                style: const TextStyle(
                    fontSize: 11, height: 1.4, color: Color(0xFF94A0B5))),
            const SizedBox(height: 10),
            child,
            if (footnote != null) ...[
              const SizedBox(height: 8),
              Text(footnote!,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF8B97AC))),
            ],
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
      );
}

/// 可选中的小胶囊（鸿蒙端 ChipButton：选中 = #2E6BE6 底 + 白字）
class _Choice extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({
    super.key,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2E6BE6)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : const Color(0xFFC3CDDE))),
      ),
    );
  }
}

/// 胶囊按钮（鸿蒙端默认 `Button` 的样子）：高 40、胶囊圆角、居中白字
class _PillBtn extends StatelessWidget {
  final String text;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  final double height;
  final double fontSize;
  const _PillBtn({
    super.key,
    required this.text,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.height = 40,
    // 鸿蒙这些整宽 Button 大多没写 fontSize（= 默认 16）
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: height,
        // 鸿蒙 Button 默认左右各 16 padding：两个字也有胶囊的宽度
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(height / 2),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                color: foreground)),
      ),
    );
  }
}

// ---------------- 三张鸿蒙端特有的卡 ----------------

/// 背景卡：预览 + 「从相册选一张」+ 「恢复默认渐变」
class _WallpaperCard extends StatelessWidget {
  final String path;
  final String focus;
  final Future<void> Function() onPick;
  final Future<void> Function() onReset;
  final Future<void> Function() onAdjust;
  final VoidCallback onCenter;
  const _WallpaperCard({
    required this.path,
    required this.focus,
    required this.onPick,
    required this.onReset,
    required this.onAdjust,
    required this.onCenter,
  });

  @override
  Widget build(BuildContext context) {
    final has = path.isNotEmpty && wallpaperExists(path);
    return _Card(
      title: '背景',
      description: '玻璃态要有东西可透才好看。默认是柔和渐变；换成自己的照片后，所有玻璃面会自动跟着变。',
      child: Column(
        children: [
          // 预览（对应鸿蒙 `Stack` + 110 高 + 圆角 12）：渐变永远在底层，
          // 有图才盖上去 + 同一层可读性薄纱，最上面压一块玻璃标签。
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 110,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                      decoration: BoxDecoration(gradient: pageGradient)),
                  if (has) ...[
                    // 鸿蒙 `WallpaperCard` 的预览是 `Image(...).objectFit(Cover)`：
                    // **按原图 cover 显示，不带用户设的缩放/位置**（那是整屏背景的事）。
                    // 原来这里用 `WallpaperImage(focus:)`，预览比实际背景"更放大"。
                    Image.file(File(path), fit: BoxFit.cover),
                    // WALLPAPER_VEIL = rgba(6,8,16,0.62)
                    const ColoredBox(color: Color(0x9E060810)),
                  ],
                  Center(
                    child: Glass(
                      radius: glassRadius,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Text(has ? '自定义照片' : '默认渐变',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFF2F5FA))),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _PillBtn(
                  text: '从相册选一张',
                  background: const Color(0xFF2E6BE6),
                  foreground: Colors.white,
                  onTap: () => onPick(),
                ),
              ),
              if (has) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _PillBtn(
                    text: '恢复默认渐变',
                    background: Colors.white.withValues(alpha: 0.14),
                    foreground: const Color(0xFFC3CDDE),
                    onTap: () => onReset(),
                  ),
                ),
              ],
            ],
          ),
          // 选区域 / 调位置（鸿蒙端只在有自定义照片时出现）
          if (has) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _PillBtn(
                    key: const ValueKey('wp-adjust'),
                    text: '调整位置 / 区域',
                    background: const Color(0x382E6BE6),
                    foreground: const Color(0xFF7FA8FF),
                    onTap: () => onAdjust(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PillBtn(
                    key: const ValueKey('wp-center'),
                    text: '居中',
                    background: Colors.white.withValues(alpha: 0.14),
                    foreground: const Color(0xFFC3CDDE),
                    onTap: onCenter,
                  ),
                ),
              ],
            ),
          ],
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('照片会拷进 App 内部保存，不联网、也不需要相册权限。',
                style: TextStyle(fontSize: 11, color: Color(0xFF8B97AC))),
          ),
        ],
      ),
    );
  }
}

/// 首页标语卡：输入 + 宽度计数 + 恢复默认 / 保存
class _MottoCard extends StatefulWidget {
  final AppSettings settings;
  final VoidCallback onSave;
  final void Function(String text) onToast;
  const _MottoCard(
      {required this.settings, required this.onSave, required this.onToast});

  @override
  State<_MottoCard> createState() => _MottoCardState();
}

class _MottoCardState extends State<_MottoCard> {
  late final TextEditingController _ctrl =
      TextEditingController(text: normalMotto(widget.settings.motto));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final units = mottoUnits(_ctrl.text);
    return _Card(
      title: '首页标语',
      description: '写在 ClassOUT 下面那一行。上限按显示宽度算：32 宽度 = 16 个汉字或 32 个英文字母；'
          '留空恢复默认。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 鸿蒙端是裸 TextInput（默认深色圆角底、高 40、圆角 20）
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            // 鸿蒙的裸 TextInput 没有可见底色（对照 docs/manual/04 的标语输入框）
            decoration: const BoxDecoration(),
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(fontSize: 15, color: inkPrimary),
              cursorColor: accentBlue,
              onChanged: (v) {
                final clamped = clampMottoUnits(v);
                if (clamped != v) {
                  _ctrl.value = TextEditingValue(
                    text: clamped,
                    selection: TextSelection.collapsed(offset: clamped.length),
                  );
                }
                setState(() {});
              },
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: mottoDefault,
                hintStyle: TextStyle(fontSize: 15, color: Color(0xFF8B97AC)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                Text('$units/$mottoMaxUnits',
                    style: TextStyle(
                        fontSize: 11,
                        color: units >= mottoMaxUnits
                            ? const Color(0xFFE8B25C)
                            : const Color(0xFF8B97AC))),
                const Spacer(),
                _PillBtn(
                  text: '恢复默认',
                  height: 30,
                  fontSize: 12,
                  background: Colors.white.withValues(alpha: 0.10),
                  foreground: const Color(0xFFC3CDDE),
                  onTap: () {
                    _ctrl.text = mottoDefault;
                    setState(() {});
                    _save();
                  },
                ),
                const SizedBox(width: 8),
                _PillBtn(
                  text: '保存',
                  height: 30,
                  fontSize: 12,
                  background: const Color(0xFF2E6BE6),
                  foreground: Colors.white,
                  onTap: _save,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _save() {
    widget.settings.motto = normalMotto(_ctrl.text);
    widget.onSave();
    widget.onToast('首页标语已保存');
  }
}

/// 动画卡：一个开关关掉所有动效
class _MotionCard extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const _MotionCard({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: '动画',
      description: '关掉之后所有动效都退化为直接切换：列表增删、抽屉、托盘、打字机与背景光晕漂移全部停。',
      footnote: '不会影响数据的读写与提醒；关掉只是不再播放过渡效果。',
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('界面动画',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                const SizedBox(height: 2),
                Text(enabled ? '开着：进出场、碎裂掉出、光晕漂移都在跑' : '已关闭：一切直接切换（更省电）',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF94A0B5))),
              ],
            ),
          ),
          Switch(
            value: enabled,
            activeThumbColor: const Color(0xFF2E6BE6),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
