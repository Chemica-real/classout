// 设置页（第一版）：同步节奏 / 计划时间范围 / 待办类型 / 不可排时段 / 关于。
//
// 设置项分两类：
//  - **kv 类**（同步节奏、时间范围、自定义类型、标语）→ AppSettings，经 repo 持久化；
//  - **数据类**（不可排时段 rest_window 表）→ 跟 bundle 一起整份写回。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/settings.dart';
import '../domain/categories.dart';
import '../domain/dates.dart';
import '../domain/plan_math.dart';
import '../domain/reminders.dart';
import '../domain/sync_cadence.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'palette.dart';

const String appVersion = '0.2.0';

class SettingsPage extends StatefulWidget {
  final BackupBundle bundle;

  /// 「导入备份」入口（对应鸿蒙端「管理课程 → 备份与恢复 → 恢复」）
  final Future<void> Function()? onImport;
  final void Function(BackupBundle next) onChanged;
  final AppSettings settings;
  final void Function(AppSettings next) onSettingsChanged;

  /// 立即重排提醒（由外壳注入：它才知道仓库与通知实现）；返回给用户看的结果文案
  final Future<String> Function()? onResyncReminders;

  const SettingsPage({
    super.key,
    required this.bundle,
    required this.onChanged,
    required this.settings,
    required this.onSettingsChanged,
    this.onResyncReminders,
    this.onImport,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AppSettings _s = widget.settings;
  late List<RestWindow> _rest = _effectiveRest();

  List<RestWindow> _effectiveRest() {
    if (widget.bundle.restWindows.isNotEmpty)
      return List.of(widget.bundle.restWindows);
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
    );
  }

  void _saveRest() {
    widget.onChanged(_withRest(_rest));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Glass(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: const [
              Text('设置',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: inkPrimary)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Title('日历同步'),
                const _Hint('连续使用到 n 分钟的整数倍时自动同步一次；闲置超过 n 分钟再打开会重新走一遍启动流程。'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in syncIntervalChoices)
                      ChoiceChip(
                        key: ValueKey('sync-$m'),
                        label:
                            Text('$m 分钟', style: const TextStyle(fontSize: 12)),
                        selected: _s.syncIntervalMin == m,
                        onSelected: (_) {
                          _s.syncIntervalMin = m;
                          _saveSettings();
                        },
                      ),
                  ],
                ),
                Text(
                    '当前：每 ${_s.syncIntervalMin} 分钟（默认 $syncIntervalDefault 分钟）',
                    style: const TextStyle(fontSize: 11, color: inkTertiary)),
                const _Title('提醒'),
                const _Hint('每天一条简报 + 上课前提醒。提醒写在系统通知里（不是后台常驻）。'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _s.briefEnabled,
                  title: const Text('每日简报',
                      style: TextStyle(fontSize: 13, color: inkPrimary)),
                  subtitle: const Text('今天几节课 + 今天截止什么',
                      style: TextStyle(fontSize: 11, color: inkTertiary)),
                  onChanged: (v) {
                    _s.briefEnabled = v;
                    _saveSettings();
                  },
                ),
                const _Hint('简报时间'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final t in const [
                      6 * 60 + 30,
                      7 * 60 + 30,
                      8 * 60,
                      9 * 60
                    ])
                      ChoiceChip(
                        label: Text(minToHHmm(t),
                            style: const TextStyle(fontSize: 12)),
                        selected: _s.briefMin == t,
                        onSelected: (_) {
                          _s.briefMin = t;
                          _saveSettings();
                        },
                      ),
                  ],
                ),
                const _Hint('上课提前多久提醒'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in const [5, 10, 15, 30, 60])
                      ChoiceChip(
                        key: ValueKey('lead-$m'),
                        label:
                            Text('$m 分钟', style: const TextStyle(fontSize: 12)),
                        selected: _s.classLeadMin == m,
                        onSelected: (_) {
                          _s.classLeadMin = m;
                          _saveSettings();
                        },
                      ),
                  ],
                ),
                Text('当前：提前 ${_s.classLeadMin} 分钟（默认 $defaultClassLeadMin 分钟）',
                    style: const TextStyle(fontSize: 11, color: inkTertiary)),
                if (widget.onResyncReminders != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TextButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final msg = await widget.onResyncReminders!();
                        messenger.showSnackBar(SnackBar(content: Text(msg)));
                      },
                      icon: const Icon(Icons.notifications_active, size: 16),
                      label:
                          const Text('立即重排提醒', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: accentBlue),
                    ),
                  ),
                const _Title('计划页时间范围'),
                const _Hint('网格从几点画到几点，按整半小时调。只影响显示，不改数据。'),
                Row(
                  children: [
                    _StepChip(
                      label: minToHHmm(_s.planWindow.startMin),
                      onMinus: () => _shiftWindow(start: -30),
                      onPlus: () => _shiftWindow(start: 30),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('—', style: TextStyle(color: inkTertiary)),
                    ),
                    _StepChip(
                      label: minToHHmm(_s.planWindow.endMin),
                      onMinus: () => _shiftWindow(end: -30),
                      onPlus: () => _shiftWindow(end: 30),
                    ),
                  ],
                ),
                const _Title('待办类型'),
                const _Hint('内置的作业 / 自学 / 考试 / 无不能删；自定义的用名字当 key。'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final o in builtinCategoryOptions())
                      Chip(
                        label:
                            Text(o.label, style: const TextStyle(fontSize: 12)),
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                      ),
                    for (final name in _s.customCategories)
                      Chip(
                        label: Text(name, style: const TextStyle(fontSize: 12)),
                        onDeleted: () {
                          _s.customCategories =
                              removeCustomCategory(_s.customCategories, name);
                          _saveSettings();
                        },
                      ),
                    ActionChip(
                      avatar:
                          const Icon(Icons.add, size: 14, color: accentBlue),
                      label: const Text('新建类型', style: TextStyle(fontSize: 12)),
                      onPressed: _addCategory,
                    ),
                  ],
                ),
                const _Title('不可排时段'),
                const _Hint('「⚡找空档」会跳过这些时段（午休、吃饭、睡觉…）。'),
                for (final w in _rest)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${w.label}　${minToHHmm(w.startMin)} – ${minToHHmm(w.endMin)}',
                          style:
                              const TextStyle(fontSize: 13, color: inkPrimary),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() =>
                              _rest = _rest.where((x) => x != w).toList());
                          _saveRest();
                        },
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFFF8080)),
                        child: const Text('删除', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                TextButton.icon(
                  onPressed: _addRest,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加时段', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(foregroundColor: accentBlue),
                ),
                const _Title('数据'),
                const _Hint('备份可以在鸿蒙端「管理课程 → 备份与恢复 → 导出备份」拿到（.json），'
                    '也可以在这里导入。导入是**整份替换**，会覆盖当前所有数据。'),
                if (widget.onImport != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: TextButton.icon(
                      key: const ValueKey('settings-import'),
                      onPressed: widget.onImport,
                      icon: const Icon(Icons.move_to_inbox, size: 16),
                      label:
                          const Text('导入备份…', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: accentBlue),
                    ),
                  ),
                const _Title('关于'),
                Row(
                  children: [
                    const Expanded(
                      child: Text('ClassOUT（iOS / Android）',
                          style: TextStyle(fontSize: 13, color: inkPrimary)),
                    ),
                    Text(appVersion,
                        style:
                            const TextStyle(fontSize: 12, color: inkTertiary)),
                  ],
                ),
                const SizedBox(height: 4),
                const _Hint('纯离线：没有账号、不联网、不上报。数据只在本机（SQLite）。'),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _shiftWindow({int start = 0, int end = 0}) {
    final w = TimeWindow(
      (_s.planWindow.startMin + start).clamp(windowMinStart, windowMaxEnd),
      (_s.planWindow.endMin + end).clamp(windowMinStart, windowMaxEnd),
    );
    _s.planWindow = normalizeWindow(w);
    _saveSettings();
  }

  Future<void> _addCategory() async {
    final name = await _askText('新建类型', '类型名（最多 $categoryNameMax 个字）');
    if (name == null) return;
    final verdict = validateCategoryName(name, _s.customCategories);
    if (!verdict.ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(verdict.message)));
      return;
    }
    _s.customCategories = addCustomCategory(_s.customCategories, name);
    _saveSettings();
  }

  Future<void> _addRest() async {
    final label = await _askText('添加不可排时段', '名称（如「午休」）');
    if (label == null || label.trim().isEmpty) return;
    setState(() => _rest = [
          ..._rest,
          RestWindow(
              weekday: 0,
              startMin: 12 * 60,
              endMin: 13 * 60,
              label: label.trim()),
        ]);
    _saveRest();
  }

  Future<String?> _askText(String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 16, 6, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: inkPrimary)),
      );
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: inkTertiary)),
      );
}

class _StepChip extends StatelessWidget {
  final String label;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _StepChip(
      {required this.label, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
              onPressed: onMinus,
              icon: const Icon(Icons.remove, size: 16, color: inkSecondary),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28)),
          Text(label, style: const TextStyle(fontSize: 13, color: inkPrimary)),
          IconButton(
              onPressed: onPlus,
              icon: const Icon(Icons.add, size: 16, color: inkSecondary),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28)),
        ],
      ),
    );
  }
}
