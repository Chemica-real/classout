import { Course, CourseSession, OverrideKind, SectionTime, Semester, SessionOverride,
  SessionRule } from '../model/Types';
import { addDays, diffDays, formatDate, parseDate } from '../util/DateUtil';
import { maskHas } from '../model/WeekMask';

/** 日期落在第几教学周（1 起；学期范围外会返回 <1 或 >totalWeeks） */
export function weekOfDate(sem: Semester, date: Date): number {
  const start: Date = parseDate(sem.startDate);
  return Math.floor(diffDays(date, start) / 7) + 1;
}

/** 第 week 周、星期 weekday（1=周一）的日期 */
export function dateOfWeekday(sem: Semester, week: number, weekday: number): Date {
  const start: Date = parseDate(sem.startDate);
  return addDays(start, (week - 1) * 7 + (weekday - 1));
}

export function buildCourseMap(courses: Course[]): Map<number, Course> {
  const map: Map<number, Course> = new Map<number, Course>();
  for (const c of courses) {
    map.set(c.id, c);
  }
  return map;
}

export function buildSectionMap(times: SectionTime[]): Map<number, SectionTime> {
  const map: Map<number, SectionTime> = new Map<number, SectionTime>();
  for (const t of times) {
    map.set(t.section, t);
  }
  return map;
}

/** 节次区间 → 起止分钟 */
export function sectionMinutes(times: Map<number, SectionTime>, startSection: number,
  endSection: number): number[] {
  const s = times.get(startSection);
  const e = times.get(endSection);
  const startMin: number = s === undefined ? 0 : s.startMin;
  const endMin: number = e === undefined ? startMin + 45 : e.endMin;
  return [startMin, endMin];
}

/** 一节课的展示文本，如 '08:00-09:50' */
export function sessionTimeText(times: Map<number, SectionTime>, s: CourseSession): string {
  const st = times.get(s.startSection);
  const et = times.get(s.endSection);
  if (st === undefined || et === undefined) {
    return '';
  }
  const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  const a = `${pad(Math.floor(st.startMin / 60))}:${pad(st.startMin % 60)}`;
  const b = `${pad(Math.floor(et.endMin / 60))}:${pad(et.endMin % 60)}`;
  return `${a}-${b}`;
}

/**
 * 算出第 week 周的全部课时。
 * 规则层（SessionRule）自动排课，覆盖层（SessionOverride）做单周调整：
 *   cancel → 该周这节不上
 *   move   → 挪到 newDate（可换节次）
 *   room   → 只换教室
 *   extra  → 额外加一节（补课）
 */
export function computeWeekSessions(sem: Semester, courses: Course[], rules: SessionRule[],
  overrides: SessionOverride[], times: SectionTime[], week: number): CourseSession[] {
  const courseMap: Map<number, Course> = buildCourseMap(courses);
  const timeMap: Map<number, SectionTime> = buildSectionMap(times);
  const result: CourseSession[] = [];

  // 覆盖层按 courseId|date 建索引
  const cancelSet: Set<string> = new Set<string>();
  const moveMap: Map<string, SessionOverride> = new Map<string, SessionOverride>();
  const roomMap: Map<string, SessionOverride> = new Map<string, SessionOverride>();
  for (const o of overrides) {
    const key: string = `${o.courseId}|${o.date}`;
    if (o.kind === OverrideKind.Cancel) {
      cancelSet.add(key);
    } else if (o.kind === OverrideKind.Move) {
      moveMap.set(key, o);
    } else if (o.kind === OverrideKind.Room) {
      roomMap.set(key, o);
    }
  }

  for (const rule of rules) {
    if (!maskHas(rule.weeksMask, week)) {
      continue;
    }
    const course = courseMap.get(rule.courseId);
    if (course === undefined) {
      continue;
    }
    let date: Date = dateOfWeekday(sem, week, rule.weekday);
    const originDate: string = formatDate(date);
    let startSection: number = rule.startSection;
    let endSection: number = rule.endSection;
    let location: string = rule.location.length > 0 ? rule.location : course.location;
    const key: string = `${rule.courseId}|${formatDate(date)}`;

    if (cancelSet.has(key)) {
      continue;
    }
    const moved = moveMap.get(key);
    if (moved !== undefined) {
      if (moved.newDate.length > 0) {
        date = parseDate(moved.newDate);
        // 挪出本週就不在这里显示
        if (weekOfDate(sem, date) !== week) {
          continue;
        }
      }
      if (moved.newStartSection > 0) {
        startSection = moved.newStartSection;
        endSection = moved.newEndSection >= moved.newStartSection ? moved.newEndSection : moved.newStartSection;
      }
      if (moved.newLocation.length > 0) {
        location = moved.newLocation;
      }
    }
    const roomChanged = roomMap.get(key);
    if (roomChanged !== undefined && roomChanged.newLocation.length > 0) {
      location = roomChanged.newLocation;
    }

    const minutes: number[] = sectionMinutes(timeMap, startSection, endSection);
    result.push({
      course: course,
      rule: rule,
      date: formatDate(date),
      originDate: originDate,
      weekday: weekdayOfDate(date),
      startSection: startSection,
      endSection: endSection,
      startMin: minutes[0],
      endMin: minutes[1],
      location: location,
      isQuiz: rule.isQuiz,
      fromOverride: moved !== undefined,
      isExtra: false
    });
  }

  // 补课 / 临时加课
  for (const o of overrides) {
    if (o.kind !== OverrideKind.Extra || o.newDate.length === 0) {
      continue;
    }
    const date: Date = parseDate(o.newDate);
    if (weekOfDate(sem, date) !== week) {
      continue;
    }
    const course = courseMap.get(o.courseId);
    if (course === undefined) {
      continue;
    }
    const startSection: number = o.newStartSection > 0 ? o.newStartSection : 1;
    const endSection: number = o.newEndSection >= startSection ? o.newEndSection : startSection;
    const minutes: number[] = sectionMinutes(timeMap, startSection, endSection);
    // 补课这一节也可能被"改地点"：新流程是把地点写回 extra 自己，但老数据里
    // 「补课 + 单独一条 room 覆盖」是两条记录（用户实测报的"补课详情显示两条、地点不刷新"）。
    // 这里让补课也认 room 覆盖，配合 `Index` 里的数据合并，两条路都不会漏。
    const roomForExtra = roomMap.get(`${o.courseId}|${o.newDate}`);
    let extraLocation: string = o.newLocation;
    if (roomForExtra !== undefined && roomForExtra.newLocation.length > 0) {
      extraLocation = roomForExtra.newLocation;
    }
    const synthetic: SessionRule = {
      id: 0,
      courseId: o.courseId,
      weekday: weekdayOfDate(date),
      startSection: startSection,
      endSection: endSection,
      weeksMask: '',
      location: extraLocation,
      isQuiz: false
    };
    result.push({
      course: course,
      rule: synthetic,
      date: formatDate(date),
      originDate: formatDate(date),
      weekday: weekdayOfDate(date),
      startSection: startSection,
      endSection: endSection,
      startMin: minutes[0],
      endMin: minutes[1],
      location: extraLocation.length > 0 ? extraLocation : course.location,
      isQuiz: false,
      fromOverride: true,
      isExtra: true
    });
  }

  result.sort((a: CourseSession, b: CourseSession): number => {
    if (a.weekday !== b.weekday) {
      return a.weekday - b.weekday;
    }
    return a.startMin - b.startMin;
  });
  return result;
}

/** 1..7 → 下标 0..6 */
export function weekdayOfDate(d: Date): number {
  const w: number = d.getDay();
  return w === 0 ? 7 : w;
}

/**
 * 「补课 / 调课」与「另外单独存的一条换教室」合并成**一条**。
 *
 * 用户实测报的 bug：「如果是补课，再加上改了补课的地点，那么应该在补课详情里面
 * 只显示一条，而不应该显示成两条」。成因是「换教室」无条件新建一条 `room` 覆盖，
 * 而补课/调课本身已经占了一条记录 —— 同一天同一门课于是有两条。
 *
 * 合并规则：`room` 覆盖若与同 `courseId|date` 的 `move` / `extra` 撞上，
 * 就把地点写进后者（后者的 `newLocation` 本来就支持存地点），并标记删除前者。
 * 纯函数，方便离线断言；**不碰数据库**，调用方负责按 `deleteIds` 删行。
 */
export interface RoomMergePlan {
  /** 合并之后该保留的覆盖（被并入的 `move`/`extra` 已就地更新过地点） */
  list: SessionOverride[];
  /** 需要从库里删掉的 `room` 覆盖 id */
  deleteIds: number[];
}

export function mergeRoomOverrides(overrides: SessionOverride[]): RoomMergePlan {
  const byKey: Map<string, SessionOverride> = new Map<string, SessionOverride>();
  for (const o of overrides) {
    if (o.kind === OverrideKind.Move || o.kind === OverrideKind.Extra) {
      byKey.set(`${o.courseId}|${o.date}`, o);
    }
  }
  const list: SessionOverride[] = [];
  const deleteIds: number[] = [];
  for (const o of overrides) {
    if (o.kind !== OverrideKind.Room) {
      list.push(o);
      continue;
    }
    const target: SessionOverride | undefined = byKey.get(`${o.courseId}|${o.date}`);
    if (target === undefined) {
      list.push(o);
      continue;
    }
    if (o.newLocation.length > 0) {
      target.newLocation = o.newLocation;
    }
    if (o.id > 0) {
      deleteIds.push(o.id);
    }
  }
  return { list: list, deleteIds: deleteIds };
}

/** 按星期分组（下标 0 = 周一） */
export function groupByWeekday(sessions: CourseSession[]): CourseSession[][] {
  const groups: CourseSession[][] = [[], [], [], [], [], [], []];
  for (const s of sessions) {
    const idx: number = s.weekday - 1;
    if (idx >= 0 && idx < 7) {
      groups[idx].push(s);
    }
  }
  return groups;
}

/** 某一天的全部课时（待办生成会用到） */
export function sessionsOnDate(sem: Semester, courses: Course[], rules: SessionRule[],
  overrides: SessionOverride[], times: SectionTime[], date: Date): CourseSession[] {
  const week: number = weekOfDate(sem, date);
  const all: CourseSession[] = computeWeekSessions(sem, courses, rules, overrides, times, week);
  const target: string = formatDate(date);
  const hit: CourseSession[] = [];
  for (const s of all) {
    if (s.date === target) {
      hit.push(s);
    }
  }
  return hit;
}
