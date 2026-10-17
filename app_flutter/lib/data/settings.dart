// 设置项（存在 kv 表里，对应鸿蒙端的 Prefs）。
//
// 键名与鸿蒙端保持一致，方便将来两条线对照：
//   sync_interval_min / plan_start+plan_end / todo_categories / motto

import '../domain/categories.dart';
import '../domain/plan_math.dart';
import '../domain/sync_cadence.dart';
import 'repo.dart';

class AppSettings {
  int syncIntervalMin;
  TimeWindow planWindow;
  List<String> customCategories;
  String motto;

  AppSettings({
    this.syncIntervalMin = syncIntervalDefault,
    this.planWindow = defaultWindow,
    this.customCategories = const [],
    this.motto = '',
  });

  static const String _kSync = 'sync_interval_min';
  static const String _kWindow = 'plan_window';
  static const String _kCats = 'todo_categories';
  static const String _kMotto = 'motto';

  static Future<AppSettings> load(ClassOutRepo repo) async {
    final sync = await repo.getKv(_kSync);
    final win = await repo.getKv(_kWindow);
    final cats = await repo.getKv(_kCats);
    final motto = await repo.getKv(_kMotto);
    return AppSettings(
      syncIntervalMin: normalizeSyncInterval(
          sync == null || sync.isEmpty ? syncIntervalDefault : (int.tryParse(sync) ?? syncIntervalDefault)),
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
  }
}
