import { Course, PlanBlock, RestWindow, Semester, SessionOverride, SessionRule, Todo,
  TodoTemplate, VirtualLesson } from '../model/Types';

/**
 * 备份包的格式定义与序列化。
 *
 * 刻意做成纯逻辑（不碰鸿蒙 API）：这样「导出 → 导入」的往返能在 tools/domain-check 里验证。
 * 备份坏了等于数据没了，这是最不该靠"看起来没问题"的地方。
 */

export const BACKUP_APP: string = 'ClassOUT';
export const BACKUP_FORMAT_VERSION: number = 1;

/** 备份里的节次行（SectionTime 本身不带 semesterId，落库时才带上） */
export interface SectionTimeRow {
  semesterId: number;
  section: number;
  startMin: number;
  endMin: number;
  flexible: boolean;
}

export interface BackupBundle {
  app: string;
  version: number;
  exportedAt: string;
  semesters: Semester[];
  sectionTimes: SectionTimeRow[];
  courses: Course[];
  rules: SessionRule[];
  overrides: SessionOverride[];
  templates: TodoTemplate[];
  todos: Todo[];
  lessons: VirtualLesson[];
  blocks: PlanBlock[];
  restWindows: RestWindow[];
}

export interface BackupCounts {
  semesters: number;
  sectionTimes: number;
  courses: number;
  rules: number;
  overrides: number;
  templates: number;
  todos: number;
  lessons: number;
  blocks: number;
  restWindows: number;
}

export function countBackup(b: BackupBundle): BackupCounts {
  return {
    semesters: b.semesters.length,
    sectionTimes: b.sectionTimes.length,
    courses: b.courses.length,
    rules: b.rules.length,
    overrides: b.overrides.length,
    templates: b.templates.length,
    todos: b.todos.length,
    lessons: b.lessons.length,
    blocks: b.blocks.length,
    restWindows: b.restWindows.length
  };
}

export function emptyBundle(exportedAt: string): BackupBundle {
  return {
    app: BACKUP_APP,
    version: BACKUP_FORMAT_VERSION,
    exportedAt: exportedAt,
    semesters: [],
    sectionTimes: [],
    courses: [],
    rules: [],
    overrides: [],
    templates: [],
    todos: [],
    lessons: [],
    blocks: [],
    restWindows: []
  };
}

export function serializeBackup(b: BackupBundle): string {
  return JSON.stringify(b);
}

/**
 * 解析备份文本。解析不了 / 不是本 App 的备份 / 版本比当前新 → 返回 undefined。
 * 宁可明确失败，也不要"部分导入"把数据搅成半截。
 */
export function parseBackup(text: string): BackupBundle | undefined {
  if (text.length === 0) {
    return undefined;
  }
  let bundle: BackupBundle | undefined = undefined;
  try {
    bundle = JSON.parse(text) as BackupBundle;
  } catch (e) {
    return undefined;
  }
  if (bundle === undefined || bundle === null) {
    return undefined;
  }
  if (bundle.app !== BACKUP_APP) {
    return undefined;
  }
  if (bundle.version <= 0 || bundle.version > BACKUP_FORMAT_VERSION) {
    return undefined;
  }
  return bundle;
}

/** 给界面看的摘要文本 */
export function backupSummary(b: BackupBundle): string {
  const c: BackupCounts = countBackup(b);
  return `学期 ${c.semesters} · 课程 ${c.courses} · 时段 ${c.rules} · 节次 ${c.sectionTimes} · ` +
    `生成模板 ${c.templates} · 待办 ${c.todos} · 计划块 ${c.blocks} · 课时 ${c.lessons} · ` +
    `单周覆盖 ${c.overrides} · 休息时段 ${c.restWindows}`;
}
