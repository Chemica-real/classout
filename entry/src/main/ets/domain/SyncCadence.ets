/**
 * 「多久同步一次日历 / 闲置多久就算一次重启」的**节奏**（纯逻辑，进离线断言）。
 *
 * 用户 2026-10-16 的两条要求共用一个 `n`：
 *   ① 「未使用超过 n min 后下次点开必定重新启动应用」→ 回到前台时看闲置了多久；
 *   ② 「长时间使用应用达到 n min（或其整数倍）时」弹出「正在与日历同步」并真的同步一次。
 *
 * 抽出来是因为**"整数倍"这种事最容易差一格**（0 算不算？刚好等于 n 算不算？n 改了怎么办？），
 * 在真机上试这两条要等好几分钟，离线断言便宜得多。
 */

/** 默认间隔（分钟） */
export const SYNC_INTERVAL_DEFAULT: number = 10;
export const SYNC_INTERVAL_MIN: number = 1;
export const SYNC_INTERVAL_MAX: number = 180;

/** 设置页给用户的档位 */
export const SYNC_INTERVAL_CHOICES: number[] = [5, 10, 15, 30, 60];

/** 存库/读回来时用的规范化：坏值 → 默认值，越界 → 夹紧并取整 */
export function normalizeSyncInterval(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) {
    return SYNC_INTERVAL_DEFAULT;
  }
  const n: number = Math.round(raw);
  if (n < SYNC_INTERVAL_MIN) {
    return SYNC_INTERVAL_MIN;
  }
  return n > SYNC_INTERVAL_MAX ? SYNC_INTERVAL_MAX : n;
}

/**
 * 连续使用的第 `activeMin` 分钟，是不是该同步一次。
 *
 * 规则（对应用户那句"n 或其整数倍"）：
 * - `activeMin <= 0` 不算（刚打开就弹一下很怪）；
 * - `activeMin` 是 `interval` 的正整数倍时算 —— n、2n、3n…
 */
export function isSyncBoundary(activeMin: number, interval: number): boolean {
  const n: number = normalizeSyncInterval(interval);
  if (!Number.isFinite(activeMin) || activeMin <= 0) {
    return false;
  }
  return activeMin % n === 0;
}

/**
 * 闲置了 `idleMs` 毫秒，回来时要不要**重新启动**。
 * `<= 0`（时钟回拨/没记录）不重启；刚好等于阈值**不重启**（用户说"超过"）。
 */
export function shouldRestartAfterIdle(idleMs: number, interval: number): boolean {
  if (!Number.isFinite(idleMs) || idleMs <= 0) {
    return false;
  }
  const n: number = normalizeSyncInterval(interval);
  return idleMs > n * 60 * 1000;
}
