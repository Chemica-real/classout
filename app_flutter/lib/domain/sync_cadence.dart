// 「多久同步一次日历 / 闲置多久就算一次重启」—— 从
// entry/src/main/ets/domain/SyncCadence.ets 逐函数移植（判据：shared/fixtures/sync_cadence.json）。

import 'js_compat.dart';

/// 默认间隔（分钟）
const int syncIntervalDefault = 10;
const int syncIntervalMin = 1;
const int syncIntervalMax = 180;

/// 设置页给用户的档位
const List<int> syncIntervalChoices = <int>[5, 10, 15, 30, 60];

/// 存库/读回来时用的规范化：坏值 → 默认值，越界 → 夹紧并取整
int normalizeSyncInterval(num raw) {
  if (!raw.isFinite || raw <= 0) return syncIntervalDefault;
  final n = jsRound(raw);
  if (n < syncIntervalMin) return syncIntervalMin;
  return n > syncIntervalMax ? syncIntervalMax : n;
}

/// 连续使用的第 [activeMin] 分钟，该不该同步一次（n、2n、3n…；0 不算）
bool isSyncBoundary(int activeMin, num interval) {
  final n = normalizeSyncInterval(interval);
  if (activeMin <= 0) return false;
  return activeMin % n == 0;
}

/// 闲置了 [idleMs] 毫秒，回来时该不该重新启动（用户说"超过"，所以正好等于**不**重启）
bool shouldRestartAfterIdle(int idleMs, num interval) {
  if (idleMs <= 0) return false;
  final n = normalizeSyncInterval(interval);
  return idleMs > n * 60 * 1000;
}
