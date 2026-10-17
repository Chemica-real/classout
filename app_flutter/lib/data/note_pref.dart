// 备注区是否展开 —— 鸿蒙端 `data/Prefs.ets` 的 NOTE_EXPANDED_* 与 `AppStorage('noteExpanded')`。
//
// 待办编辑窗和计划块属性面板共用这一个开关（鸿蒙端就是同一个键），
// 这样「在待办里展开备注」之后，去计划页看同一个待办的备注也是展开的。

import 'repo.dart';

/// kv 键（与鸿蒙端一致）
const String noteExpandedKv = 'note_expanded';

/// 内存态（等价于鸿蒙端的 AppStorage('noteExpanded')）
bool noteExpanded = false;

/// 冷启动读回来（读不到 = 收起）
Future<bool> loadNoteExpanded(ClassOutRepo repo) async {
  try {
    return (await repo.getKv(noteExpandedKv)) == '1';
  } catch (_) {
    return false;
  }
}

/// 切换并写回 kv
Future<void> saveNoteExpanded(ClassOutRepo repo, bool on) async {
  noteExpanded = on;
  try {
    await repo.setKv(noteExpandedKv, on ? '1' : '0');
  } catch (_) {
    // 写失败不影响本次会话的观感
  }
}
