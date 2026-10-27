import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from './Db';
import { DEFAULT_WINDOW, TimeWindow, formatWindow, normalizeWindow, parseWindow } from '../domain/PlanMath';
import { parseCustomCategories, serializeCustomCategories } from '../domain/Categories';
import { SYNC_INTERVAL_DEFAULT, normalizeSyncInterval } from '../domain/SyncCadence';

/**
 * 首页标语（ClassOUT 字标下面那一行）。
 *
 * 用户要求（2026-10-14）：「首页可以显示一行定制语句在 ClassOUT 下方代替那几个
 * XX·XX·XX，定制语句可以在设置里更改（有字数限制）」。
 *
 * 三条约定：
 * 1. **有字数上限**（`MOTTO_MAX`）。首页那行是拉开字距的小字，太长会折行、
 *    把字标下面的排版撑坏；实测 16 个汉字正好一行放得下（设置页里也照这个截断）。
 * 2. **空串 = 用默认标语**。也就是"清空输入框 + 保存"等于恢复默认，
 *    这样不需要再区分"从没设过"和"用户清空了"（kv 读不到就是空串）。
 * 3. 存在 kv 里（和壁纸路径、动画开关同一张表），冷启动第一件事就把它读进
 *    `AppStorage`，好让**加载页第一帧**就能显示自己的标语。
 */

/** kv 键。⚠️ 组件里 `@StorageLink` 要写字面量 `'bootMotto'` */
export const MOTTO_KEY: string = 'bootMotto';

/**
 * 字数上限（**按显示宽度算，不是一个字符一格**）。
 *
 * 用户反馈：「个性化语句支持的英文字母数应当更多吧」—— 原来按"字符数"卡 16，
 * 于是 16 个汉字和 16 个英文字母一样长，而英文字母只有汉字一半宽，明显吃亏。
 * 现在按**显示宽度**：一个全角（汉字、全角标点）算 2，一个半角（英文/数字/半角符号）算 1。
 * 所以上限 32 宽度 = 16 个汉字 **或** 32 个英文字母 ✓
 */
export const MOTTO_MAX_UNITS: number = 32;

/** 单个字符的显示宽度：全角 2、半角 1 */
function charUnits(code: number): number {
  if (code >= 0x1100 && (
    code <= 0x115F
      || (code >= 0x2E80 && code <= 0xA4CF)
      || (code >= 0xAC00 && code <= 0xD7A3)
      || (code >= 0xF900 && code <= 0xFAFF)
      || (code >= 0xFE30 && code <= 0xFE4F)
      || (code >= 0xFF00 && code <= 0xFF60)
      || (code >= 0xFFE0 && code <= 0xFFE6)
      || (code >= 0x20000 && code <= 0x3FFFD))) {
    return 2;
  }
  return 1;
}

/** 一段文字的显示宽度 */
export function mottoUnits(text: string): number {
  let w: number = 0;
  for (let i = 0; i < text.length; i++) {
    w += charUnits(text.charCodeAt(i));
  }
  return w;
}

/**
 * 按显示宽度截断（超出上限就砍掉尾巴）。
 * ⚠️ 输入框的 `maxLength` 只能按"字符数"卡，挡不住"16 个汉字 = 32 宽度"这种，
 * 所以**输入时就用这个函数实时截断**，而不是只在保存时截。
 */
export function clampMottoUnits(text: string): string {
  let w: number = 0;
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const u: number = charUnits(text.charCodeAt(i));
    if (w + u > MOTTO_MAX_UNITS) {
      break;
    }
    w += u;
    out += text.charAt(i);
  }
  return out;
}

/** 默认标语 */
export const MOTTO_DEFAULT: string = '离线课表 · 待办 · 计划';

/** 读换算后的标语（空 → 默认；超宽 → 按显示宽度截断） */
export function cleanMotto(raw: string): string {
  const t: string = raw.trim();
  if (t.length === 0) {
    return MOTTO_DEFAULT;
  }
  return clampMottoUnits(t);
}

/** 冷启动读回来 */
export async function loadMotto(context: common.Context): Promise<string> {
  try {
    const v: string = await Db.getKv(context, MOTTO_KEY);
    return cleanMotto(v);
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load motto failed: %{public}s', JSON.stringify(e));
    return MOTTO_DEFAULT;
  }
}

/** 设置页保存：内存（加载页立刻可见）+ kv 一起写 */
export async function saveMotto(context: common.Context, raw: string): Promise<string> {
  const t: string = cleanMotto(raw);
  AppStorage.setOrCreate(MOTTO_KEY, t);
  try {
    await Db.setKv(context, MOTTO_KEY, t === MOTTO_DEFAULT ? '' : t);
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'save motto failed: %{public}s', JSON.stringify(e));
  }
  return t;
}

// ---------------- 计划页时间范围（上下限） ----------------

/**
 * 计划页时间窗的 AppStorage 键（分钟）。
 * ⚠️ 组件里 `@StorageLink` **必须写字面量** `'planStartMin'` / `'planEndMin'`，
 *    用常量会静默不生效（项目里踩过一次，见 HANDOFF §20.8）。
 */
export const PLAN_START_KEY: string = 'planStartMin';
export const PLAN_END_KEY: string = 'planEndMin';
/** kv 里的持久化键，值是 `'start,end'` */
export const PLAN_WINDOW_KV: string = 'plan_window';

/** 冷启动读回来（读不到/坏了都退回默认窗 07:00–24:00） */
export async function loadPlanWindow(context: common.Context): Promise<TimeWindow> {
  try {
    return parseWindow(await Db.getKv(context, PLAN_WINDOW_KV));
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load plan window failed: %{public}s', JSON.stringify(e));
    return DEFAULT_WINDOW;
  }
}

/**
 * 设置页保存：规范化（吸附 30 分钟 + 夹紧 + 最小跨度）→ 写 AppStorage + kv。
 * 返回真正生效的那个窗，让调用方把 UI 也刷新成规范后的值。
 */
export async function savePlanWindow(context: common.Context,
  w: TimeWindow): Promise<TimeWindow> {
  const n: TimeWindow = normalizeWindow(w);
  AppStorage.setOrCreate(PLAN_START_KEY, n.startMin);
  AppStorage.setOrCreate(PLAN_END_KEY, n.endMin);
  try {
    await Db.setKv(context, PLAN_WINDOW_KV, formatWindow(n));
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'save plan window failed: %{public}s', JSON.stringify(e));
  }
  return n;
}

// ---------------- 日历同步节奏 / 闲置重启 ----------------

/**
 * 用户 2026-10-16：一个 `n`（分钟）管两件事 ——
 * ① 连续使用到 n 的整数倍时自动与日历同步一次；② 闲置超过 n 后回到前台就重新启动。
 * 默认 10 分钟，设置页可选 5/10/15/30/60。
 *
 * ⚠️ `@StorageLink` 的键名必须写字面量 `'syncIntervalMin'`。
 */
export const SYNC_INTERVAL_KEY: string = 'syncIntervalMin';
export const SYNC_INTERVAL_KV: string = 'sync_interval_min';
/** 上次进入后台的时刻（毫秒时间戳，存真实库 kv） */
export const LAST_BG_KV: string = 'last_background_at';

export async function loadSyncInterval(context: common.Context): Promise<number> {
  try {
    const raw: string = await Db.getKv(context, SYNC_INTERVAL_KV);
    return normalizeSyncInterval(raw.length > 0 ? parseInt(raw, 10) : SYNC_INTERVAL_DEFAULT);
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load sync interval failed: %{public}s', JSON.stringify(e));
    return SYNC_INTERVAL_DEFAULT;
  }
}

export async function saveSyncInterval(context: common.Context, min: number): Promise<number> {
  const n: number = normalizeSyncInterval(min);
  AppStorage.setOrCreate(SYNC_INTERVAL_KEY, n);
  try {
    await Db.setKv(context, SYNC_INTERVAL_KV, `${n}`);
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'save sync interval failed: %{public}s', JSON.stringify(e));
  }
  return n;
}

// ---------------- 备注输入框：单行 / 大文本 ----------------

/**
 * 备注区是"单行输入框"还是"展开后的大文本框"（用户 2026-10-16：
 * 「是单行文本还是大文本框需要记忆，在待办区新建/查看，在计划区查看的时候要显示正确」）。
 *
 * ⚠️ `@StorageLink` 的键名必须写字面量 `'noteExpanded'`。
 */
export const NOTE_EXPANDED_KEY: string = 'noteExpanded';
export const NOTE_EXPANDED_KV: string = 'note_expanded';

export async function loadNoteExpanded(context: common.Context): Promise<boolean> {
  try {
    return (await Db.getKv(context, NOTE_EXPANDED_KV)) === '1';
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load note expanded failed: %{public}s', JSON.stringify(e));
    return false;
  }
}

export async function saveNoteExpanded(context: common.Context, on: boolean): Promise<void> {
  AppStorage.setOrCreate(NOTE_EXPANDED_KEY, on);
  try {
    await Db.setKv(context, NOTE_EXPANDED_KV, on ? '1' : '0');
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'save note expanded failed: %{public}s', JSON.stringify(e));
  }
}

// ---------------- 待办类型（自定义 category） ----------------

/**
 * 自定义待办类型的 AppStorage 键，值是 `'\n'` 分隔的字符串。
 * ⚠️ 组件里 `@StorageLink` 必须写字面量 `'todoCategories'`（常量会静默不生效）。
 */
export const TODO_CATEGORIES_KEY: string = 'todoCategories';
/** kv 持久化键 */
export const TODO_CATEGORIES_KV: string = 'todo_categories';

/** 冷启动读回来（坏数据由 `parseCustomCategories` 兜底成空列表） */
export async function loadCustomCategories(context: common.Context): Promise<string[]> {
  try {
    return parseCustomCategories(await Db.getKv(context, TODO_CATEGORIES_KV));
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load todo categories failed: %{public}s', JSON.stringify(e));
    return [];
  }
}

/**
 * 保存自定义类型：内存（设置页与待办编辑窗立刻同步）+ kv 一起写。
 * 返回规范化之后的列表，让调用方拿它回写自己的草稿。
 */
export async function saveCustomCategories(context: common.Context,
  list: string[]): Promise<string[]> {
  const clean: string[] = parseCustomCategories(serializeCustomCategories(list));
  AppStorage.setOrCreate(TODO_CATEGORIES_KEY, serializeCustomCategories(clean));
  try {
    await Db.setKv(context, TODO_CATEGORIES_KV, serializeCustomCategories(clean));
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'save todo categories failed: %{public}s', JSON.stringify(e));
  }
  return clean;
}

// ---------------- 首次启动的隐私政策同意 ----------------

/**
 * 隐私政策同意的 kv 键。**值 = 同意时的政策版本**（`privacyUpdatedAt()` 的日期串）。
 *
 * 为什么要存版本而不是存 `'1'`：政策内容一改（更新日期跟着改），老用户下次启动会
 * 被重新问一次 —— 这是上架合规想要的（"同意"必须对应**他看过的那一版**）。
 */
export const PRIVACY_AGREED_KV: string = 'privacy_agreed';

/** 读回"同意过的政策版本"；从没同意过 / 读失败都返回 ''（= 需要弹窗） */
export async function loadPrivacyAgreed(context: common.Context): Promise<string> {
  try {
    return await Db.getKv(context, PRIVACY_AGREED_KV);
  } catch (e) {
    hilog.warn(0x0000, 'ClassOUT', 'load privacy agreed failed: %{public}s', JSON.stringify(e));
    return '';
  }
}

/** 记下"同意的政策版本"（首启弹窗点「同意并继续」时写） */
export async function savePrivacyAgreed(context: common.Context, version: string): Promise<void> {
  await Db.setKv(context, PRIVACY_AGREED_KV, version);
}
