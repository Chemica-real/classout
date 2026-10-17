// 计划页「待安排」托盘是否展开 —— 鸿蒙端 `view/Motion.ets`：
//   TRAY_OPEN_KEY = 'planTrayOpen' / loadTrayOpen / persistTrayOpen
//
// 为什么值得记：托盘展开后占掉屏幕下半截，用户调整计划时通常希望它一直开着；
// 每次切进计划页又弹回"收起"会很烦（鸿蒙端就是这么处理的）。

import 'repo.dart';

/// kv 键（与鸿蒙端逐字一致）
const String planTrayOpenKv = 'planTrayOpen';

/// 内存态（等价于鸿蒙端冷启动时读回的那份）
bool planTrayOpen = false;

/// 冷启动读回来（读不到 = 收起，与鸿蒙 `loadTrayOpen` 同）
Future<bool> loadPlanTrayOpen(ClassOutRepo repo) async {
  try {
    return (await repo.getKv(planTrayOpenKv)) == '1';
  } catch (_) {
    return false;
  }
}

/// 切换并写回 kv
Future<void> savePlanTrayOpen(ClassOutRepo repo, bool open) async {
  planTrayOpen = open;
  try {
    await repo.setKv(planTrayOpenKv, open ? '1' : '0');
  } catch (_) {
    // 写失败不影响本次会话
  }
}
