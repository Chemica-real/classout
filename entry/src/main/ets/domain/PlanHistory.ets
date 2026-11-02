/**
 * 计划页撤销/重做历史。
 *
 * 设计约束（用户 2026-11-01 拍板）：
 * - 只存在本次运行内（模块单例），切标签保留，杀进程清空；
 * - 最多 30 步，新动作清空 redo；
 * - 每个动作保存“同一待办/虚拟课时的全部块 + todo 行”的前后快照，
 *   撤销/重做按整组替换，避免拆块/跨天/完成状态出现半截状态；
 * - 历史本身不写数据库。
 */

import { PlanBlock, Todo } from '../model/Types';

export interface PlanHistoryEntry {
  label: string;
  todoId: number;
  lessonId: number;
  blocksBefore: PlanBlock[];
  blocksAfter: PlanBlock[];
  todoBefore?: Todo;
  todoAfter?: Todo;
}

export function clonePlanBlock(b: PlanBlock): PlanBlock {
  return {
    id: b.id, todoId: b.todoId, lessonId: b.lessonId, date: b.date,
    startMin: b.startMin, endMin: b.endMin, done: b.done
  };
}

export function clonePlanTodo(t: Todo): Todo {
  return {
    id: t.id, title: t.title, courseId: t.courseId, category: t.category,
    priority: t.priority, ddl: t.ddl, endAt: t.endAt, estimateMin: t.estimateMin,
    status: t.status, source: t.source, generationKey: t.generationKey, note: t.note,
    submitChannel: t.submitChannel, repeatRule: t.repeatRule, photos: t.photos,
    createdAt: t.createdAt, confirmedAt: t.confirmedAt, doneAt: t.doneAt
  };
}

export function samePlanBlocks(a: PlanBlock[], b: PlanBlock[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    const x: PlanBlock = a[i];
    const y: PlanBlock = b[i];
    if (x.todoId !== y.todoId || x.lessonId !== y.lessonId || x.date !== y.date
      || x.startMin !== y.startMin || x.endMin !== y.endMin || x.done !== y.done) {
      return false;
    }
  }
  return true;
}

export function samePlanTodo(a: Todo | undefined, b: Todo | undefined): boolean {
  if (a === undefined || b === undefined) {
    return a === b;
  }
  return a.id === b.id && a.title === b.title && a.courseId === b.courseId
    && a.category === b.category && a.priority === b.priority && a.ddl === b.ddl
    && a.endAt === b.endAt && a.estimateMin === b.estimateMin && a.status === b.status
    && a.note === b.note && a.confirmedAt === b.confirmedAt && a.doneAt === b.doneAt;
}

/** 整份计划数据的稳定签名：块按日期/开始/id，待办按 id 排序后拼字段。 */
export function planDataSignature(blocks: PlanBlock[], todos: Todo[]): string {
  const bs: PlanBlock[] = blocks.slice();
  bs.sort((a: PlanBlock, b: PlanBlock): number => {
    if (a.date !== b.date) {
      return a.date < b.date ? -1 : 1;
    }
    if (a.startMin !== b.startMin) {
      return a.startMin - b.startMin;
    }
    return a.id - b.id;
  });
  const ts: Todo[] = todos.slice();
  ts.sort((a: Todo, b: Todo): number => a.id - b.id);
  let out: string = '';
  for (const b of bs) {
    out += `B${b.id}|${b.todoId}|${b.lessonId}|${b.date}|${b.startMin}|${b.endMin}|${b.done ? 1 : 0};`;
  }
  for (const t of ts) {
    out += `T${t.id}|${t.title}|${t.courseId}|${t.category}|${t.ddl}|${t.estimateMin}|`
      + `${t.status}|${t.note}|${t.confirmedAt}|${t.doneAt};`;
  }
  return out;
}

/**
 * 把同一待办/课时的块按“日期→开始→结束”排序后比较；
 * 只比较内容，不比较数据库 id（撤销恢复后 id 会变）。
 */
export function samePlanBlockSet(a: PlanBlock[], b: PlanBlock[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  const sortFn = (x: PlanBlock, y: PlanBlock): number => {
    if (x.date !== y.date) {
      return x.date < y.date ? -1 : 1;
    }
    if (x.startMin !== y.startMin) {
      return x.startMin - y.startMin;
    }
    return x.endMin - y.endMin;
  };
  const aa: PlanBlock[] = a.slice();
  const bb: PlanBlock[] = b.slice();
  aa.sort(sortFn);
  bb.sort(sortFn);
  for (let i = 0; i < aa.length; i++) {
    const x: PlanBlock = aa[i];
    const y: PlanBlock = bb[i];
    if (x.date !== y.date || x.startMin !== y.startMin || x.endMin !== y.endMin
      || x.done !== y.done || x.todoId !== y.todoId || x.lessonId !== y.lessonId) {
      return false;
    }
  }
  return true;
}

/** 撤销/重做栈。模块单例由 PlanDayView 共用；只存快照，不碰数据库。 */
export class PlanHistoryStore {
  private entries: PlanHistoryEntry[] = [];
  private cursor: number = 0;
  private max: number = 30;
  /** 最近一次同步的整份计划数据签名；外部改动会让签名变化 */
  signature: string = '';

  push(entry: PlanHistoryEntry): void {
    // 新动作把 redo 分支截掉
    if (this.cursor < this.entries.length) {
      this.entries = this.entries.slice(0, this.cursor);
    }
    this.entries.push(entry);
    if (this.entries.length > this.max) {
      this.entries = this.entries.slice(this.entries.length - this.max);
    }
    this.cursor = this.entries.length;
  }

  canUndo(): boolean {
    return this.cursor > 0;
  }

  canRedo(): boolean {
    return this.cursor < this.entries.length;
  }

  peekUndo(): PlanHistoryEntry | undefined {
    return this.cursor > 0 ? this.entries[this.cursor - 1] : undefined;
  }

  peekRedo(): PlanHistoryEntry | undefined {
    return this.cursor < this.entries.length ? this.entries[this.cursor] : undefined;
  }

  commitUndo(): void {
    if (this.cursor > 0) {
      this.cursor--;
    }
  }

  commitRedo(): void {
    if (this.cursor < this.entries.length) {
      this.cursor++;
    }
  }

  clear(): void {
    this.entries = [];
    this.cursor = 0;
    this.signature = '';
  }

  hasEntries(): boolean {
    return this.entries.length > 0;
  }

  size(): number {
    return this.entries.length;
  }

  /**
   * 外部写操作后同步数据签名。若已有历史且签名变了，说明数据在计划页之外被改过，
   * 旧快照不再可信，直接清空。
   */
  syncSignature(sig: string): boolean {
    if (this.entries.length > 0 && this.signature.length > 0 && this.signature !== sig) {
      this.clear();
      this.signature = sig;
      return true;
    }
    this.signature = sig;
    return false;
  }

  markSignature(sig: string): void {
    this.signature = sig;
  }
}

export const planHistory: PlanHistoryStore = new PlanHistoryStore();
