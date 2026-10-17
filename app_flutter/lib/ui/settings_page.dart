// 设置页（第一版）：同步节奏 / 计划时间范围 / 待办类型 / 不可排时段 / 关于。
//
// 设置项分两类：
//  - **kv 类**（同步节奏、时间范围、自定义类型、标语）→ AppSettings，经 repo 持久化；
//  - **数据类**（不可排时段 rest_window 表）→ 跟 bundle 一起整份写回。

import 'dart:io';

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/wallpaper.dart';
import '../data/settings.dart';
import '../domain/categories.dart';
import '../domain/dates.dart';
import '../domain/motto.dart';
import '../domain/plan_math.dart';
import '../domain/reminders.dart';
import '../domain/sync_cadence.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'palette.dart';
import 'theme.dart' as theme;

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
      templates: b.templates,
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
        // 设置页自己的标题条（鸿蒙端 SettingsPage 内部浮动的那一条）
        Glass(
          margin: const EdgeInsets.fromLTRB(
              floatSide, floatTop, floatSide, floatGap),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: const [
              Text('设置',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: inkPrimary)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _WallpaperCard(
                  path: _s.wallpaperPath,
                  onPick: _pickWallpaper,
                  onReset: _resetWallpaper,
                ),
                _MottoCard(settings: _s, onSave: _saveSettings),
                _MotionCard(
                  enabled: _s.motionEnabled,
                  onChanged: (v) {
                    _s.motionEnabled = v;
                    theme.motionOn = v;
                    _saveSettings();
                  },
                ),

                // ---------------- 日历同步 ----------------
                _Card(
                  title: '日历同步',
                  description: '连续使用到 n 分钟的整数倍时自动同步一次；闲置超过 n 分钟再打开会重新走一遍启动流程。',
                  footnote:
                      '当前：每 ${_s.syncIntervalMin} 分钟（默认 $syncIntervalDefault 分钟）',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
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
                    ],
                  ),
                ),

                // ---------------- 提醒 ----------------
                _Card(
                  title: '提醒',
                  description: '每天一条简报 + 上课前提醒。提醒写在系统通知里（不是后台常驻）。',
                  footnote:
                      '当前：提前 ${_s.classLeadMin} 分钟（默认 $defaultClassLeadMin 分钟）',
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
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: inkPrimary)),
                                Text('今天几节课 + 今天截止什么',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF94A0B5))),
                              ],
                            ),
                          ),
                          Switch(
                            value: _s.briefEnabled,
                            activeThumbColor: const Color(0xFF2E6BE6),
                            onChanged: (v) {
                              _s.briefEnabled = v;
                              _saveSettings();
                            },
                          ),
                        ],
                      ),
                      const _FieldLabel('简报时间'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final t in const [
                            6 * 60 + 30,
                            7 * 60 + 30,
                            8 * 60,
                            9 * 60
                          ])
                            _Choice(
                              text: minToHHmm(t),
                              selected: _s.briefMin == t,
                              onTap: () {
                                _s.briefMin = t;
                                _saveSettings();
                              },
                            ),
                        ],
                      ),
                      const _FieldLabel('上课提前多久提醒'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final m in const [5, 10, 15, 30, 60])
                            _Choice(
                              key: ValueKey('lead-$m'),
                              text: '$m 分钟',
                              selected: _s.classLeadMin == m,
                              onTap: () {
                                _s.classLeadMin = m;
                                _saveSettings();
                              },
                            ),
                        ],
                      ),
                      if (widget.onResyncReminders != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _LinkAction(
                            icon: Icons.notifications_active,
                            text: '立即重排提醒',
                            onTap: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final msg = await widget.onResyncReminders!();
                              messenger
                                  .showSnackBar(SnackBar(content: Text(msg)));
                            },
                          ),
                        ),
                    ],
                  ),
                ),

                // ---------------- 计划页时间范围 ----------------
                _Card(
                  title: '计划页时间范围',
                  description: '网格从几点画到几点，按整半小时调。只影响显示，不改数据。',
                  footnote:
                      '最窄 ${windowMinSpan ~/ 60} 小时；最晚到 ${minToHHmm(windowMaxEnd)}。',
                  child: Row(
                    children: [
                      Expanded(
                        child: _StepChip(
                          label: minToHHmm(_s.planWindow.startMin),
                          onMinus: () => _shiftWindow(start: -30),
                          onPlus: () => _shiftWindow(start: 30),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text('—', style: TextStyle(color: inkTertiary)),
                      ),
                      Expanded(
                        child: _StepChip(
                          label: minToHHmm(_s.planWindow.endMin),
                          onMinus: () => _shiftWindow(end: -30),
                          onPlus: () => _shiftWindow(end: 30),
                        ),
                      ),
                    ],
                  ),
                ),

                // ---------------- 待办类型 ----------------
                _Card(
                  title: '待办类型',
                  description: '内置的作业 / 自学 / 考试 / 无不能删；自定义的用名字当 key。',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final o in builtinCategoryOptions())
                        _StaticTag(text: o.label),
                      for (final name in _s.customCategories)
                        _DeletableTag(
                          text: name,
                          onDelete: () {
                            _s.customCategories =
                                removeCustomCategory(_s.customCategories, name);
                            _saveSettings();
                          },
                        ),
                      _Choice(
                        text: '＋ 新建类型',
                        selected: false,
                        onTap: _addCategory,
                      ),
                    ],
                  ),
                ),

                // ---------------- 不可排时段 ----------------
                _Card(
                  title: '不可排时段',
                  description: '「⚡找空档」会跳过这些时段（午休、吃饭、睡觉…）。',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final w in _rest)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${w.label}　${minToHHmm(w.startMin)} – ${minToHHmm(w.endMin)}',
                                style: const TextStyle(
                                    fontSize: 13, color: inkPrimary),
                              ),
                            ),
                            _LinkAction(
                              text: '删除',
                              color: dangerRed,
                              onTap: () {
                                setState(() => _rest =
                                    _rest.where((x) => x != w).toList());
                                _saveRest();
                              },
                            ),
                          ],
                        ),
                      _LinkAction(
                        icon: Icons.add,
                        text: '添加时段',
                        onTap: _addRest,
                      ),
                    ],
                  ),
                ),

                // ---------------- 数据 ----------------
                _Card(
                  title: '数据',
                  description:
                      '备份可以在鸿蒙端「管理课程 → 备份与恢复 → 导出备份」拿到（.json），也可以在这里导入。'
                      '导入是整份替换，会覆盖当前所有数据。',
                  child: widget.onImport == null
                      ? const SizedBox.shrink()
                      : _LinkAction(
                          key: const ValueKey('settings-import'),
                          icon: Icons.move_to_inbox,
                          text: '导入备份…',
                          onTap: () => widget.onImport!(),
                        ),
                ),

                // ---------------- 关于 ----------------
                _Card(
                  title: '关于',
                  description: '纯离线：没有账号、不联网、不上报。数据只在本机（SQLite）。',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text('ClassOUT（iOS / Android）',
                                style:
                                    TextStyle(fontSize: 13, color: inkPrimary)),
                          ),
                          Text(appVersion,
                              style: const TextStyle(
                                  fontSize: 12, color: inkTertiary)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(normalMotto(_s.motto),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF94A0B5))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选图失败：$e')));
    }
  }

  Future<void> _resetWallpaper() async {
    final old = _s.wallpaperPath;
    _s.wallpaperPath = '';
    _saveSettings();
    await clearWallpaper(old);
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
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: inkPrimary)),
            const SizedBox(height: 4),
            Text(description,
                style: const TextStyle(
                    fontSize: 12, height: 1.4, color: Color(0xFF94A0B5))),
            const SizedBox(height: 10),
            child,
            if (footnote != null) ...[
              const SizedBox(height: 10),
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

class _StaticTag extends StatelessWidget {
  final String text;
  const _StaticTag({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 12, color: Color(0xFFC3CDDE))),
    );
  }
}

class _DeletableTag extends StatelessWidget {
  final String text;
  final VoidCallback onDelete;
  const _DeletableTag({required this.text, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(fontSize: 12, color: inkPrimary)),
          GestureDetector(
            onTap: onDelete,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.close, size: 13, color: Color(0xFF94A0B5)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 纯文字动作（带可选图标）
class _LinkAction extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;
  const _LinkAction({
    super.key,
    required this.text,
    this.icon,
    this.color = accentBlue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
            ],
            Text(text, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}

// ---------------- 三张鸿蒙端特有的卡 ----------------

/// 背景卡：预览 + 「从相册选一张」+ 「恢复默认渐变」
class _WallpaperCard extends StatelessWidget {
  final String path;
  final Future<void> Function() onPick;
  final Future<void> Function() onReset;
  const _WallpaperCard({
    required this.path,
    required this.onPick,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final has = path.isNotEmpty && wallpaperExists(path);
    return _Card(
      title: '背景',
      description: '玻璃态要有东西可透才好看。默认是柔和渐变；换成自己的照片后，所有玻璃面会自动跟着变。',
      footnote: '照片会拷进 App 内部保存，不联网、也不需要相册权限。',
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 120,
              width: double.infinity,
              child: has
                  ? Image.file(File(path), fit: BoxFit.cover)
                  : const DecoratedBox(
                      decoration: BoxDecoration(gradient: pageGradient),
                      child: Center(
                        child: Text('默认渐变',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFC3CDDE))),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => onPick(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 40,
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF2E6BE6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('从相册选一张',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.white)),
            ),
          ),
          if (has)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _LinkAction(text: '恢复默认渐变', onTap: () => onReset()),
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
  const _MottoCard({required this.settings, required this.onSave});

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
          TextField(
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
            decoration: const InputDecoration(
              isDense: true,
              hintText: mottoDefault,
              hintStyle: TextStyle(fontSize: 15, color: Color(0xFF8B97AC)),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0x24FFFFFF))),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accentBlue)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Text('$units/$mottoMaxUnits',
                    style: TextStyle(
                        fontSize: 11,
                        color: units >= mottoMaxUnits
                            ? const Color(0xFFE8B25C)
                            : const Color(0xFF8B97AC))),
                const Spacer(),
                _LinkAction(
                  text: '恢复默认',
                  color: const Color(0xFFA9B5C9),
                  onTap: () {
                    _ctrl.text = mottoDefault;
                    setState(() {});
                  },
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () {
                    widget.settings.motto = normalMotto(_ctrl.text);
                    widget.onSave();
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('标语已保存')));
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E6BE6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text('保存',
                        style: TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: onMinus,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(Icons.remove, size: 16, color: inkSecondary),
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 13, color: inkPrimary)),
          GestureDetector(
            onTap: onPlus,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(Icons.add, size: 16, color: inkSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
