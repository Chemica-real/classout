/** 日期 / 时间小工具（全部按本地时区，日期字符串统一 'YYYY-MM-DD'） */

export const WEEKDAY_CN: string[] = ['一', '二', '三', '四', '五', '六', '日'];

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** 'YYYY-MM-DD' → Date（当天 00:00） */
export function parseDate(s: string): Date {
  const y: number = parseInt(s.substring(0, 4), 10);
  const m: number = parseInt(s.substring(5, 7), 10);
  const d: number = parseInt(s.substring(8, 10), 10);
  return new Date(y, m - 1, d);
}

export function formatDate(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function today(): Date {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

export function todayStr(): string {
  return formatDate(today());
}

export function addDays(d: Date, n: number): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
}

/** a - b，按「天」计 */
export function diffDays(a: Date, b: Date): number {
  const am: number = new Date(a.getFullYear(), a.getMonth(), a.getDate()).getTime();
  const bm: number = new Date(b.getFullYear(), b.getMonth(), b.getDate()).getTime();
  return Math.round((am - bm) / 86400000);
}

/** 分钟数 → 'HH:mm' */
export function minToHHmm(min: number): string {
  const h: number = Math.floor(min / 60);
  const m: number = min % 60;
  return `${pad2(h)}:${pad2(m)}`;
}

/** 'HH:mm' → 分钟数 */
export function hhmmToMin(s: string): number {
  const h: number = parseInt(s.substring(0, 2), 10);
  const m: number = parseInt(s.substring(3, 5), 10);
  return h * 60 + m;
}

/** Date（含时分）→ 'YYYY-MM-DD HH:mm'。`parseDateTime` 的逆运算 */
export function formatDateTime(d: Date): string {
  return `${formatDate(d)} ${minToHHmm(d.getHours() * 60 + d.getMinutes())}`;
}

/**
 * 'YYYY-MM-DD HH:mm' → **带时分的** Date。
 *
 * ⚠️ 和 `parseDate` 的分工：`parseDate` 只认日期、时分归零（比较日期用）；
 * 这个把时分也带上，专门喂给鸿蒙的 DatePicker / TimePicker 当初始值 ——
 * 拿 `parseDate` 的结果去喂，每次打开选择器都会把手表重置成 00:00，
 * 用户会以为"刚挑的时刻没生效"。解析不出来就退回此刻（而不是 00:00）。
 */
export function parseDateTime(s: string): Date {
  if (s.length < 16) {
    return new Date();
  }
  const d: Date = parseDate(s.substring(0, 10));
  const min: number = hhmmToMin(s.substring(11, 16));
  d.setHours(Math.floor(min / 60), min % 60, 0, 0);
  return d;
}

/** 1 = 周一 ... 7 = 周日 */
export function weekdayOf(d: Date): number {
  const w: number = d.getDay();
  return w === 0 ? 7 : w;
}

/** 相对今天的自然语言，如「今天」「明天」「3 天后」「逾期 2 天」 */
export function relativeDayText(target: Date): string {
  const d: number = diffDays(target, today());
  if (d === 0) {
    return '今天';
  }
  if (d === 1) {
    return '明天';
  }
  if (d === 2) {
    return '后天';
  }
  if (d > 0) {
    return `${d} 天后`;
  }
  return `逾期 ${-d} 天`;
}

/** 'M.D'，用于 %D 变量 */
export function monthDayText(d: Date): string {
  return `${d.getMonth() + 1}.${d.getDate()}`;
}

/**
 * 考试倒计时文案。from 显式传进来（而不是内部取 today），这样它是纯函数、能被离线断言覆盖。
 */
export function countdownText(target: Date, from: Date): string {
  const d: number = diffDays(target, from);
  if (d > 1) {
    return `还有 ${d} 天`;
  }
  if (d === 1) {
    return '明天';
  }
  if (d === 0) {
    return '就是今天';
  }
  return `已结束 ${-d} 天`;
}

/**
 * **最近的周一**。
 *
 * 学期开始日必须是周一 —— 周次是从"开始日那一周"数起的（`Timetable.weekOfDate`），
 * 开始日落在周三会让整张周表平移。用户 2026-10-15 拍定：日期选择器选完之后
 * **自动吸附到最近的周一**，并把改成了哪天告诉他。
 *
 * 周一原样；周二→往回 1 天；周四→往回 3 天（比往后 4 天近）；周五→往后 3 天；周日→往后 1 天。
 * 前后一样远的情况在整数上不存在（2·wd = 9 无整数解），所以不用定"平局规则"。
 */
export function nearestMonday(d: Date): Date {
  const wd: number = weekdayOf(d);
  if (wd === 1) {
    return d;
  }
  const back: number = wd - 1;      // 往回退几天到周一
  const forward: number = 8 - wd;   // 往后几天到周一
  return addDays(d, back <= forward ? -back : forward);
}
