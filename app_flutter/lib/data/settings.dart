// 设置项（存在 kv 表里，对应鸿蒙端的 Prefs）。
//
// 键名与鸿蒙端保持一致，方便将来两条线对照：
//   sync_interval_min / plan_start+plan_end / todo_categories / motto

import '../domain/categories.dart';
import '../domain/dates.dart';
import '../domain/plan_math.dart';
import '../domain/reminders.dart';
import '../domain/sync_cadence.dart';
import 'repo.dart';

class AppSettings {
  int syncIntervalMin;
  TimeWindow planWindow;
  List<String> customCategories;
  String motto;

  // ---- 提醒（键名与鸿蒙端 Prefs 一致：brief_enabled / brief_time / class_lead）----
  bool briefEnabled;
  int briefMin;
  int classLeadMin;

  AppSettings({
    this.syncIntervalMin = syncIntervalDefault,
    this.planWindow = defaultWindow,
    this.customCategories = const [],
    this.motto = '',
    this.briefEnabled = true,
    this.briefMin = defaultBriefMin,
    this.classLeadMin = defaultClassLeadMin,
  });

  ReminderSettings get reminderSettings => ReminderSettings(
        briefEnabled: briefEnabled,
        briefMin: briefMin,
        classLeadMin: classLeadMin,
      );

  static const String _kSync = 'sync_interval_min';
  static const String _kWindow = 'plan_window';
  static const String _kCats = 'todo_categories';
  static const String _kMotto = 'motto';
  static const String _kBriefEnabled = 'brief_enabled';
  static const String _kBriefTime = 'brief_time';
  static const String _kClassLead = 'class_lead';

  static Future<AppSettings> load(ClassOutRepo repo) async {
    final sync = await repo.getKv(_kSync);
    final win = await repo.getKv(_kWindow);
    final cats = await repo.getKv(_kCats);
    final motto = await repo.getKv(_kMotto);
    final briefEnabledRaw = await repo.getKv(_kBriefEnabled);
    final briefTimeRaw = await repo.getKv(_kBriefTime);
    final leadRaw = await repo.getKv(_kClassLead);
    return AppSettings(
      briefEnabled: briefEnabledRaw == null || briefEnabledRaw.isEmpty
          ? true
          : briefEnabledRaw == '1',
      briefMin: _parseHHmm(briefTimeRaw) ?? defaultBriefMin,
      classLeadMin: _parseLead(leadRaw),
      syncIntervalMin: normalizeSyncInterval(sync == null || sync.isEmpty
          ? syncIntervalDefault
          : (int.tryParse(sync) ?? syncIntervalDefault)),
      planWindow: win == null || win.isEmpty ? defaultWindow : parseWindow(win),
      customCategories: cats == null ? const [] : parseCustomCategories(cats),
      motto: motto ?? '',
    );
  }

  Future<void> save(ClassOutRepo repo) async {
    await repo.setKv(_kSync, '$syncIntervalMin');
    await repo.setKv(_kWindow, formatWindow(planWindow));
    await repo.setKv(_kCats, serializeCustomCategories(customCategories));
    await repo.setKv(_kMotto, motto);
    await repo.setKv(_kBriefEnabled, briefEnabled ? '1' : '0');
    await repo.setKv(_kBriefTime, minToHHmm(briefMin));
    await repo.setKv(_kClassLead, '$classLeadMin');
  }

  /// 'HH:mm' → 分钟；坏值返回 null（与鸿蒙端 loadReminderSettings 一致）
  static int? _parseHHmm(String? raw) {
    if (raw == null || raw.length != 5) return null;
    final h = int.tryParse(raw.substring(0, 2));
    final m = int.tryParse(raw.substring(3, 5));
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  /// 0..120 之外一律回默认（与鸿蒙端一致）
  static int _parseLead(String? raw) {
    final n = raw == null ? null : int.tryParse(raw);
    if (n == null || n < 0 || n > 120) return defaultClassLeadMin;
    return n;
  }
}
