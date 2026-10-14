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

/** 字数上限（按字符数算，中英文一样） */
export const MOTTO_MAX: number = 16;

/** 默认标语 */
export const MOTTO_DEFAULT: string = '离线课表 · 待办 · 计划';

/** 读换算后的标语（空/超长都会归一） */
export function cleanMotto(raw: string): string {
  const t: string = raw.trim();
  if (t.length === 0) {
    return MOTTO_DEFAULT;
  }
  return t.length > MOTTO_MAX ? t.substring(0, MOTTO_MAX) : t;
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
