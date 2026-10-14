import { curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';

/**
 * 动画的**唯一集中处**：时长、曲线、以及那个"一键关闭"的全局开关。
 *
 * ★ 用户要求（2026-10-14）：
 *   「动画（在合适的地方加入像打字机动画、丝滑流畅的衔接、显现，删除时碎裂掉出等；
 *     用户可在设置中一次性关闭，可以模仿鸿蒙的沉浸光感效果）」
 *
 * ## 三条设计约束
 *
 * 1. **只动 `transform` / `opacity`，不动布局**。
 *    位移用 `translate`、缩放用 `scale`、淡入淡出用 `opacity` —— 这些不触发重新布局。
 *    尤其**不做"模糊半径"或"宽高"的逐帧动画**：本项目每个列表卡都挂着 `backdropBlur`，
 *    再叠一层每帧重算的模糊会直接把帧率吃掉（滚动流畅度至今没人验证过）。
 * 2. **曲线统一走弹簧**（`curves.springMotion`）。鸿蒙原生手感是"有阻尼的弹簧"，
 *    比 `ease-in-out` 更有质感。
 * 3. **开关关掉 = 动画时长为 0**，而不是"两套代码"。所有地方只写一套动画，
 *    时长从 `dur()` 取；关掉时返回 0，行为退化成"直接切换"。
 *    ⚠️ 别在调用点写 `if (motionOn)` 分支 —— 那样两条路径迟早会长歪。
 *
 * ## 开关怎么存
 * 内存里用 `AppStorage`（组件用 `@StorageLink('motionOn')` 订阅，键名必须是**字面量**），
 * 持久化用 `Db` 的 kv（和"同步到哪一天"、"壁纸路径"同一张表）。
 */

/** AppStorage 的键名。⚠️ 组件里 `@StorageLink` 必须写字面量 `'motionOn'` */
export const MOTION_KEY: string = 'motionOn';

// ============================ 一、时长（想调手感只改这里）============================

/** 标签页/页面切换 */
export const DUR_TAB: number = 200;
/** 编辑抽屉滑入滑出 */
export const DUR_DRAWER: number = 300;
/** 待安排托盘展开/收起 */
export const DUR_TRAY: number = 260;
/** 列表项的增/删（高度收起 + 淡出） */
export const DUR_ITEM: number = 240;
/** 删除时的"碎裂掉出"（碎片飞散的时间，之后才真的删数据） */
export const DUR_SHARD: number = 320;
/** 提示胶囊的进出 */
export const DUR_HINT: number = 200;
/** 背景光晕漂移一个来回 */
export const DUR_ORBIT: number = 22000;
/** 打字机每个字的间隔 */
export const TYPE_MS: number = 45;

/**
 * 启动清单每一步的**最短可见时长**（ms）。
 *
 * 用户实测反馈：「启动的时候主要决速步是同步系统日历提醒，所以导致其他几项的
 * 加载/完成动画完全看不见，可以人为放慢一点」。日历同步是真·耗时（几十秒级的
 * 日历写入），而前面几步是毫秒级的数据库读 —— 不作处理的话，清单会"一步没看清
 * 就直接跳到第四步"。
 *
 * 所以每一步给一个最短停留：真实耗时不够就补一段等待（**不是**把真活儿变慢）。
 * 关掉动画时不补 —— 那种情况下用户要的就是最快启动。
 */
export const BOOT_STEP_MS: number = 380;

/** 整段启动动画**最多**额外拖这么久，避免慢机器上雪上加霜 */
export const BOOT_EXTRA_CAP_MS: number = 1900;

// ============================ 二、曲线 ============================

/** 通用弹簧：有阻尼的收尾，鸿蒙手感 */
export function motionCurve(): ICurve {
  return curves.springMotion(0.34, 0.9);
}

/** 抽屉这种"从屏幕外滑进来"的：响应更快、收尾更紧 */
export function drawerCurve(): ICurve {
  return curves.springMotion(0.30, 0.86);
}

// ============================ 三、全局开关 ============================

/** 当前是否开启动画（内存里的值） */
export function isMotionOn(): boolean {
  const v: boolean | undefined = AppStorage.get<boolean>(MOTION_KEY);
  return v === undefined ? true : v;
}

/**
 * 时长取值：**关掉动画时返回 0**，于是所有 `animateTo` / `transition` 都退化成瞬切。
 * 调用点一律写 `animateTo({ duration: dur(DUR_DRAWER), curve: ... }, ...)`。
 */
export function dur(ms: number): number {
  return isMotionOn() ? ms : 0;
}

/** 曲线取值：关掉动画时给线性（配合 0 时长，没有可感知差别） */
export function curveOrLinear(c: () => ICurve): ICurve {
  return isMotionOn() ? c() : curves.initCurve(Curve.Linear);
}

/** 写内存（组件会通过 @StorageLink 立刻跟着变） */
export function setMotionOn(on: boolean): void {
  AppStorage.setOrCreate(MOTION_KEY, on);
}

/** 冷启动时从 kv 读回来（AppStorage 是内存态，每次启动都要读） */
export async function loadMotionSetting(context: common.Context): Promise<void> {
  try {
    const v: string = await Db.getKv(context, MOTION_KEY);
    // 没存过（空串）= 默认开
    setMotionOn(v !== '0');
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load motion setting failed: %{public}s', JSON.stringify(e));
    setMotionOn(true);
  }
}

/** 设置页改了开关：内存 + kv 一起写 */
export async function persistMotionSetting(context: common.Context, on: boolean): Promise<void> {
  setMotionOn(on);
  try {
    await Db.setKv(context, MOTION_KEY, on ? '1' : '0');
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'persist motion setting failed: %{public}s', JSON.stringify(e));
  }
}

// ============================ 四、其它动画开关的小工具 ============================

/**
 * 待安排托盘"上次是展开还是收起"的记忆键（用户选择"记忆上次状态"）。
 * 它和动画总开关是两件事：关掉动画时托盘照样能用，只是不再滑出滑入。
 */
export const TRAY_OPEN_KEY: string = 'planTrayOpen';

export async function loadTrayOpen(context: common.Context): Promise<boolean> {
  try {
    return (await Db.getKv(context, TRAY_OPEN_KEY)) === '1';
  } catch (e) {
    return false;
  }
}

export async function persistTrayOpen(context: common.Context, open: boolean): Promise<void> {
  try {
    await Db.setKv(context, TRAY_OPEN_KEY, open ? '1' : '0');
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'persist tray state failed: %{public}s', JSON.stringify(e));
  }
}
