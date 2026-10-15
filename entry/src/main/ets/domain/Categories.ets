/**
 * 待办类型（category）的类型系统 —— 纯逻辑，进离线断言。
 *
 * 用户 2026-10-15 要求：
 *   「待办类型允许在设置里添加或者删除自定义的类型，当然在编辑/新建待办的卡片上也可以新建
 *    （这也是全局新建），同时可以选择类型为无」
 *   追加：「在新建/编辑界面现在的那个『其他』更改为新建类型按钮（其颜色略微不同）」。
 *
 * 三个约定：
 * 1. **内置类型固定四个**：作业 / 自学 / 考试 / 无。内置的**不能删**（考试那套固定时间、
 *    自动排块的语义挂在 `exam` 上；作业/自学是老的默认值）。
 * 2. **「其他」退役**：它的位置让给「新建类型」按钮；存量 `category = 'other'` 的待办
 *    由 `Seeder.migrateData` 迁移成 `'none'`（无）。这里保留 `'other'` 只是为了：
 *    迁移前的显示兜底、以及解析老 kv 时把它当保留字拒掉。
 * 3. **自定义类型就用名字本身当 key**（存进 `todo.category`），删类型时调用方负责把
 *    在用它的待办改成 `'none'`（用户拍定）。不做重命名 —— 没这个需求，少一份映射。
 *
 * 存储形态：kv 里一行一个名字（`'\n'` 分隔）。刻意不用 JSON：
 * ArkTS 解析 `JSON.parse` 出来的对象要自己收窄类型，得不偿失；名字里不可能有换行。
 */

import { TodoCategory } from '../model/Types';

export interface CategoryOption {
  key: string;
  label: string;
  builtin: boolean;
}

/** 自定义类型名最长几个字（汉字按 1 个字算；首页标语那套"显示宽度"这里用不上） */
export const CATEGORY_NAME_MAX: number = 8;
/** 自定义类型最多几个（防止列表无限长） */
export const CATEGORY_MAX_COUNT: number = 20;

/** kv 分隔符 */
const SEP: string = '\n';

/** 已退役的「其他」：迁移用，别再往新数据里写 */
export const LEGACY_OTHER: string = 'other';

/** 保留字：不能拿来当自定义类型名（key 或显示名都不行） */
const RESERVED_KEYS: string[] = [
  TodoCategory.Homework, TodoCategory.Self, TodoCategory.Exam, TodoCategory.None, LEGACY_OTHER
];
const RESERVED_LABELS: string[] = ['作业', '自学', '考试', '无', '其他'];

/** 内置类型（顺序 = 胶囊顺序） */
export function builtinCategoryOptions(): CategoryOption[] {
  return [
    { key: TodoCategory.Homework, label: '作业', builtin: true },
    { key: TodoCategory.Self, label: '自学', builtin: true },
    { key: TodoCategory.Exam, label: '考试', builtin: true },
    { key: TodoCategory.None, label: '无', builtin: true }
  ];
}

/** 内置类型里的显示名；不是内置就返回 '' */
export function builtinLabel(key: string): string {
  for (const o of builtinCategoryOptions()) {
    if (o.key === key) {
      return o.label;
    }
  }
  return '';
}

function isReservedName(name: string): boolean {
  return RESERVED_KEYS.indexOf(name) >= 0 || RESERVED_LABELS.indexOf(name) >= 0;
}

/**
 * 解析 kv 里存的自定义类型。
 * 坏数据（空行、重复、保留字、带换行的名字）在这里被静默丢掉 —— 读库绝不能因为
 * 一个脏字符串就崩掉（和 `PlanMath.parseWindow` 同一条规矩）。
 */
export function parseCustomCategories(raw: string): string[] {
  const out: string[] = [];
  const parts: string[] = raw.split(SEP);
  for (const p of parts) {
    const name: string = p.trim();
    if (name.length === 0 || name.length > CATEGORY_NAME_MAX || isReservedName(name)) {
      continue;
    }
    if (out.indexOf(name) < 0) {
      out.push(name);
    }
  }
  return out;
}

/** 自定义类型列表 → kv 字符串（顺带去重/去掉保留字，保证往返稳定） */
export function serializeCustomCategories(list: string[]): string {
  return parseCustomCategories(list.join(SEP)).join(SEP);
}

export interface CategoryVerdict {
  ok: boolean;
  message: string;
}

/** 新建自定义类型时的校验（纯函数，有断言） */
export function validateCategoryName(name: string, custom: string[]): CategoryVerdict {
  const t: string = name.trim();
  if (t.length === 0) {
    return { ok: false, message: '类型名不能为空' };
  }
  if (t.length > CATEGORY_NAME_MAX) {
    return { ok: false, message: `类型名最多 ${CATEGORY_NAME_MAX} 个字` };
  }
  if (isReservedName(t) || custom.indexOf(t) >= 0) {
    return { ok: false, message: '这个类型已经有了' };
  }
  if (custom.length >= CATEGORY_MAX_COUNT) {
    return { ok: false, message: `自定义类型最多 ${CATEGORY_MAX_COUNT} 个` };
  }
  return { ok: true, message: '' };
}

/** 追加一个自定义类型（调用方先用 `validateCategoryName` 校验） */
export function addCustomCategory(custom: string[], name: string): string[] {
  const t: string = name.trim();
  const out: string[] = custom.slice();
  if (t.length > 0 && out.indexOf(t) < 0 && !isReservedName(t)) {
    out.push(t);
  }
  return out;
}

export function removeCustomCategory(custom: string[], name: string): string[] {
  const out: string[] = [];
  for (const c of custom) {
    if (c !== name) {
      out.push(c);
    }
  }
  return out;
}

/** 内置 + 自定义，给胶囊列表用 */
export function allCategoryOptions(custom: string[]): CategoryOption[] {
  const out: CategoryOption[] = builtinCategoryOptions();
  for (const name of custom) {
    out.push({ key: name, label: name, builtin: false });
  }
  return out;
}

/**
 * 类型的显示名。
 * - `'none'`（无）→ `''`（卡片上不画标签，"无"就是没有类型）
 * - 内置 → 中文名
 * - 自定义 → 名字本身
 * - 认不出的（比如备份恢复后少了定义、或迁移前的 `'other'`）→ 尽量给个人话，
 *   实在没有就原样显示，**绝不显示空白**（否则用户会以为数据丢了）。
 */
export function categoryLabel(key: string, custom: string[]): string {
  if (key === TodoCategory.None || key.length === 0) {
    return '';
  }
  if (key === LEGACY_OTHER) {
    return '其他';
  }
  const b: string = builtinLabel(key);
  if (b.length > 0) {
    return b;
  }
  return key;
}
