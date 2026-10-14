import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from './Db';

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
