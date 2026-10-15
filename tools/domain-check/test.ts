/**
 * ClassOUT 领域逻辑断言
 *
 * 这些纯逻辑没法在真机上先跑，所以单独抽出来离线验证。
 * 其中 ddl 一节直接对照用户 2026-10-13 截图里的真实数据（高数=10/14、课乙=10/15、
 * 课丁=10/18、课丙=10/19，作业名形如「10.13作业」）。
 */

import { SEED_COURSES, SEED_START_DATE, SEED_TOTAL_WEEKS, SeedCourse, SeedTemplate } from './SeedData';
import { Course, CourseSession, DEFAULT_REST_WINDOWS, OverrideKind, PlanBlock, RestWindow,
  Semester, SectionTime, SessionOverride, SessionRule, Todo, PKU_SECTION_TIMES } from './Types';
import { computeWeekSessions, mergeRoomOverrides, weekOfDate, weekdayOfDate } from './Timetable';
import { WALLPAPER_MAX_ZOOM, WallpaperGeometry, clampFocus, formatWallpaperFocus,
  parseWallpaperFocus, wallpaperGeometry } from './Wallpaper';
import { maskAll, maskFromText, maskToText, maskHas } from './WeekMask';
import { countdownText, formatDateTime, minToHHmm, parseDate, parseDateTime } from './DateUtil';
import { computeDdl, renderTitle } from './TodoGenerator';
import { TimeAxis, DEFAULT_WINDOW, WINDOW_MAX_END, WINDOW_MIN_SPAN, WINDOW_SNAP_MIN,
  allBlocksDone, dragOffsetWithScroll,
  dropRange, edgeScrollDepth, edgeScrollDirection, edgeScrollStep, findFreeSlot, formatWindow, moveRange,
  normalizeDuration, normalizeWindow, parseWindow,
  overlaps, resizeRange,
  hasBlockOnDate, halveMinutes, scheduledDays,
  DdlGroup, ddlGroupsOn, ddlMinuteOf, selectPoolTodos, snap, sortBlocksByTime, sortPoolTodos,
  windowForContent } from './PlanMath';

/**
 * 断言用的固定时间轴：06:00–24:00。
 *
 * 刻意**不用**新的默认窗（07:00–24:00），这样下面那批早就写好、已经抓到过真 bug 的
 * 期望值一个都不用动 —— 改期望值会掩盖回归。默认窗另有专门的断言。
 */
const AX: TimeAxis = new TimeAxis({ startMin: 6 * 60, endMin: 24 * 60 });
const DAY_START_MIN: number = AX.startMin;
const DAY_END_MIN: number = AX.endMin;
import { buildBriefing } from './Briefing';
import { BackupBundle, backupSummary, countBackup, emptyBundle, parseBackup,
  serializeBackup } from './Backup';
import { AXIS_W, compactMinH, compactThreshold, COLS_DAY, COLS_THREE, columnAtX, columnHeaderText,
  columnWidth, columnX, contentWidth, centerIndex, dayDates, dropColumnOrFallback, canBeginDrag,
  LAYOUT, TAP_OPEN, TAP_SELECT, tapAction } from './PlanLayout';
import { ExamRange, examRangeOf, findRuleConflicts, isStepMultiple, migrateEstimate,
  normalizeEstimate, pinchDeltaLabel, pinchEnd, resizeEndTo, spanOfRule, totalBlockMinutes,
  validateEstimate, validateExamRange, validateRestWindow, normalizeRestEnd,
  validateSectionTime, validateSectionTimes, validateSessionRule, validateTemplateDdl,
  validateTemplateTitle } from './Validate';

let pass = 0;
let fail = 0;

function check(name: string, actual: string, expected: string): void {
  if (actual === expected) {
    pass++;
    console.log(`  ok   ${name}`);
  } else {
    fail++;
    console.log(`  FAIL ${name}`);
    console.log(`         期望: ${expected}`);
    console.log(`         实际: ${actual}`);
  }
}

// ---------- 构造与 App 里一致的运行时数据 ----------
const sem: Semester = {
  id: 1,
  name: '大一上',
  startDate: SEED_START_DATE,
  totalWeeks: SEED_TOTAL_WEEKS,
  firstDayOfWeek: 1,
  showWeekend: true
};

const courses: Course[] = [];
const rules: SessionRule[] = [];
const fullMask: string = maskAll(SEED_TOTAL_WEEKS);
let courseId = 1;
let ruleId = 1;
for (const sc of SEED_COURSES) {
  courses.push({
    id: courseId,
    semesterId: 1,
    name: sc.name,
    shortName: sc.shortName,
    teacher: sc.teacher,
    location: sc.location,
    colorIndex: sc.colorIndex,
    autoTodoEnabled: sc.templates.length > 0,
    isVirtual: false,
    note: ''
  });
  for (const r of sc.rules) {
    rules.push({
      id: ruleId++,
      courseId: courseId,
      weekday: r.weekday,
      startSection: r.startSection,
      endSection: r.endSection,
      weeksMask: fullMask,
      location: sc.location,
      isQuiz: r.isQuiz
    });
  }
  courseId++;
}
const times: SectionTime[] = PKU_SECTION_TIMES;

function sessionOf(short: string, weekday: number): CourseSession {
  const all: CourseSession[] = computeWeekSessions(sem, courses, rules, [], times, 6);
  for (const s of all) {
    if (s.course.shortName === short && s.weekday === weekday) {
      return s;
    }
  }
  throw new Error(`找不到课时：${short} 周${weekday}`);
}

function seedOf(short: string): SeedCourse {
  for (const sc of SEED_COURSES) {
    if (sc.shortName === short) {
      return sc;
    }
  }
  throw new Error(`找不到种子课程：${short}`);
}

// ---------- 1. 周次掩码 ----------
console.log('【周次掩码】');
check("'1-16'", maskFromText('1-16', 16), '1111111111111111');
check("'1-16单'", maskFromText('1-16单', 16), '1010101010101010');
check("'2-16双'", maskFromText('2-16双', 16), '0101010101010101');
check("'1-8,10-16'", maskFromText('1-8,10-16', 16), '1111111101111111');
check("'1-8、10-16'（顿号）", maskFromText('1-8、10-16', 16), '1111111101111111');
check("'5'", maskFromText('5', 16), '0000100000000000');
check("'1-15(单)'", maskFromText('1-15(单)', 16), '1010101010101010');
check('解析不出来时兜底为全上', maskFromText('瞎写', 16), '1111111111111111');
check('maskToText 回读', maskToText('1111111100111111'), '1-8、11-16');
check('maskHas 命中第 6 周', `${maskHas('1111111111111111', 6)}`, 'true');
check('maskHas 不命中第 9 周', `${maskHas('1111111101111111', 9)}`, 'false');

// ---------- 2. 第 6 周排课 ----------
console.log('【第 6 周（2026-10-12 ~ 10-18）排课】');
check('2026-10-13 属于第 6 周', `${weekOfDate(sem, parseDate('2026-10-13'))}`, '6');
check('2026-10-12 属于第 6 周', `${weekOfDate(sem, parseDate('2026-10-12'))}`, '6');
check('2026-09-07 属于第 1 周', `${weekOfDate(sem, parseDate('2026-09-07'))}`, '1');

const week6: CourseSession[] = computeWeekSessions(sem, courses, rules, [], times, 6);
const actualGrid: string = week6
  .map((s: CourseSession): string => `${s.weekday}-${s.startSection}-${s.course.shortName}`)
  .join(' | ');
const expectedGrid: string = [
  '1-5-课丙', '1-7-课丁',
  '2-1-课甲', '2-3-课乙', '2-5-课己',
  '3-3-课丙', '3-5-课戊', '3-7-课庚', '3-10-课甲习题',
  '4-1-课乙', '4-3-课甲', '4-10-课乙习题',
  '5-3-课戊', '5-5-课程辛', '5-7-课壬'
].join(' | ');
check('15 节课的位置与顺序', actualGrid, expectedGrid);
check('课时数', `${week6.length}`, '15');

const gs: CourseSession = sessionOf('课甲', 2);
check('课甲 周二节的起止', `${minToHHmm(gs.startMin)}-${minToHHmm(gs.endMin)}`, '08:00-09:50');
const gd: CourseSession = sessionOf('课乙', 4);
check('课乙 周四节的起止', `${minToHHmm(gd.startMin)}-${minToHHmm(gd.endMin)}`, '08:00-09:50');
const quiz: CourseSession = sessionOf('课甲习题', 3);
check('课甲习题课在周三第 10 节', `${quiz.startSection}`, '10');

// ---------- 3. 模板渲染（对照截图里的作业命名） ----------
console.log('【模板渲染】');
check('%D作业（10/13 布置）', renderTitle('%D作业', gs, 6, 1), '10.13作业');
check('%C 全名', renderTitle('%C', gs, 6, 1), '课程甲');
check('%c 简称', renderTitle('%c', gs, 6, 1), '课甲');
check('%W 周次', renderTitle('第%W周', gs, 6, 1), '第6周');
check('%N 序号', renderTitle('%c第%N次作业', gs, 6, 3), '课甲第3次作业');
check('%R 教室', renderTitle('%R', gs, 6, 1), '教学楼407');
check('%d 完整日期', renderTitle('%d', gs, 6, 1), '2026-10-13');
check('未知变量原样保留', renderTitle('%D作业%X', gs, 6, 1), '10.13作业%X');

// ---------- 4. ddl 规则（与截图实证对照） ----------
console.log('【ddl 规则 — 对照 2026-10-13 截图】');
function tpl(short: string): SeedTemplate {
  return seedOf(short).templates[0];
}
const gsTpl: SeedTemplate = tpl('课甲');
check('课甲（截图 ddl 10/14 23:59）',
  computeDdl(sem, courses, rules, [], times, gs, gsTpl.ddlRule, gsTpl.ddlParam), '2026-10-14 23:59');
const gdTpl: SeedTemplate = tpl('课乙');
const gdThu: CourseSession = sessionOf('课乙', 4);
check('课乙（截图 ddl 10/15 23:59）',
  computeDdl(sem, courses, rules, [], times, gdThu, gdTpl.ddlRule, gdTpl.ddlParam), '2026-10-15 23:59');
const xgTpl: SeedTemplate = tpl('课丁');
const xgMon: CourseSession = sessionOf('课丁', 1);
check('课丁（截图 ddl 10/18 23:59，本周日）',
  computeDdl(sem, courses, rules, [], times, xgMon, xgTpl.ddlRule, xgTpl.ddlParam), '2026-10-18 23:59');
const xwTpl: SeedTemplate = tpl('课丙');
const xwWed: CourseSession = sessionOf('课丙', 3);
check('课丙（截图 ddl 10/19 23:59，下周一）',
  computeDdl(sem, courses, rules, [], times, xwWed, xwTpl.ddlRule, xwTpl.ddlParam), '2026-10-19 23:59');

console.log('【ddl 规则 — 其余类型】');
check('same_day', computeDdl(sem, courses, rules, [], times, gs, 'same_day', ''), '2026-10-13 23:59');
check('days:3', computeDdl(sem, courses, rules, [], times, gs, 'days', '3'), '2026-10-16 23:59');
check('week_end（周二课 → 本周日）',
  computeDdl(sem, courses, rules, [], times, gs, 'week_end', ''), '2026-10-18 23:59');
check('next_session（课丙周三 → 下周一）',
  computeDdl(sem, courses, rules, [], times, xwWed, 'next_session', ''), '2026-10-19 23:59');
check('next_session（课甲周二 → 周四）',
  computeDdl(sem, courses, rules, [], times, gs, 'next_session', ''), '2026-10-15 23:59');
check('none', computeDdl(sem, courses, rules, [], times, gs, 'none', ''), '');
check('weekday:7（周日）', computeDdl(sem, courses, rules, [], times, gs, 'weekday', '7'), '2026-10-18 23:59');

// ---------- 5. 计划视图的拖拽算术 ----------
console.log('【拖拽吸附与夹紧】');
check('snap(7) 向下取整', `${snap(7)}`, '0');
check('snap(8) 进位到一刻钟', `${snap(8)}`, '15');
check('y=0 对应 06:00', `${AX.yToMinute(0)}`, '360');
check('拖出上边界会被夹住', `${AX.yToMinute(-500)}`, '360');
check('拖出下边界会被夹住', `${AX.yToMinute(99999)}`, `${DAY_END_MIN}`);
check('放一个 90 分钟的块到 06:00', dropRange(AX, 0, 90).join(','), '360,450');
check('底部放不下就整体上移', dropRange(AX, 99999, 90).join(','), `${DAY_END_MIN - 90},${DAY_END_MIN}`);
check('时长为 0 时兜底 60 分钟', dropRange(AX, 0, 0).join(','), '360,420');
// ⚠️ 行为变更（用户要求）：时长不再吸附到 15 的整数倍，自定义填多少就是多少。
// 起点仍吸附，结束时间 = 起点 + 精确时长。
check('80 分钟不再被悄悄改成 75', `${normalizeDuration(80)}`, '80');
check('20 分钟保持 20', `${normalizeDuration(20)}`, '20');
check('少于 15 分钟被抬到 15 分钟下限', `${normalizeDuration(7)}`, '15');
check('时长为 0 兜底 60 分钟', `${normalizeDuration(0)}`, '60');
// dropRange 的第二个参数是 y（vp），不是分钟：y = 目标分钟 - 轴起点
const yAt = (min: number): number => min - AX.startMin;
// ★ 用户要求的核心行为：起点吸附、时长精确（以开始时间为锚）
check('19:05 落下 → 起点吸附到 19:00，但仍占满 20 分钟',
  dropRange(AX, yAt(19 * 60 + 5), 20).join(','), `${19*60},${19*60+20}`);
check('   └ 时长严格是 20 分钟，没有被改成 15 或 30',
  `${dropRange(AX, yAt(19*60+5), 20)[1] - dropRange(AX, yAt(19*60+5), 20)[0]}`, '20');
check('17 分钟这种非整数倍也原样保留',
  `${dropRange(AX, yAt(10*60), 17)[1] - dropRange(AX, yAt(10*60), 17)[0]}`, '17');
check('   └ 10:00 + 17 分钟 = 10:17（终点不在整刻）',
  dropRange(AX, yAt(10*60), 17).join(','), `${10*60},${10*60+17}`);
check('整数倍时长结果与从前一致',
  dropRange(AX, yAt(19 * 60), 45).join(','), `${19*60},${19*60+45}`);
check('   └ 时长精确为 45', `${dropRange(AX, yAt(19*60), 45)[1] - dropRange(AX, yAt(19*60), 45)[0]}`, '45');
check('非整刻起点：19:07 吸附到 19:00 再 +20', 
  dropRange(AX, yAt(19 * 60 + 7), 20).join(','), `${19*60},${19*60+20}`);

console.log('【拖动移位 / 拖底边改时长】');
check('原地不动', moveRange(AX, 600, 690, 0).join(','), '600,690');
check('下移 20vp 吸附到 615', moveRange(AX, 600, 690, 20).join(','), '615,705');
check('上移出上界被夹住、时长不变', moveRange(AX, 360, 420, -100).join(','), '360,420');
check('下移出下界被夹住、时长不变', moveRange(AX, 1380, 1440, 100).join(','), '1380,1440');
check('拖底边 +30 分钟', resizeRange(AX, 600, 690, 30).join(','), '600,720');
check('拖底边最短 15 分钟', resizeRange(AX, 600, 690, -200).join(','), '600,615');
check('拖底边最晚到 24:00', resizeRange(AX, 600, 690, 10000).join(','), `600,${DAY_END_MIN}`);

console.log('【一键找空档的基础函数】');
check('区间不重叠判假', `${overlaps(600, 700, 700, 800)}`, 'false');
check('区间重叠判真', `${overlaps(600, 700, 650, 750)}`, 'true');
check('躲开一门课', `${findFreeSlot(AX, [[360, 600]], [], 60, DAY_START_MIN)}`, '600');
check('躲开午休（12:00-13:00）', `${findFreeSlot(AX, [], [[720, 780]], 60, 700)}`, '780');
check('一天排满则找不到', `${findFreeSlot(AX, [[DAY_START_MIN, DAY_END_MIN]], [], 60, DAY_START_MIN)}`, '-1');
check('从指定时间之后找', `${findFreeSlot(AX, [[360, 600]], [], 30, 900)}`, '900');

// ---------- 6. 找空档 × 真实课表 × 默认休息时段 ----------
console.log('【找空档 × 第 6 周周四的真实课表】');
const thuSessions: CourseSession[] = week6.filter((s: CourseSession): boolean => s.weekday === 4);
const busyThu: number[][] = thuSessions.map((s: CourseSession): number[] => [s.startMin, s.endMin]);
const restAll: number[][] = DEFAULT_REST_WINDOWS.map((w: RestWindow): number[] => [w.startMin, w.endMin]);
// 周四上午 08:00-09:50 课乙、10:10-12:00 课甲，中午是午休 → 最早只能排 13:00
check('周四 90 分钟自习最早排到 13:00（跳过午休）',
  `${findFreeSlot(AX, busyThu, restAll, 90, DAY_START_MIN)}`, '780');
check('若无视休息时段就会排到早上 06:00（睡觉时段也是用户设的）',
  `${findFreeSlot(AX, busyThu, [], 90, DAY_START_MIN)}`, '360');
check('周四晚课 18:40-19:30 结束后 → 19:30',
  `${findFreeSlot(AX, busyThu, restAll, 90, 1170)}`, '1170');

// ---------- 7. 单周覆盖：停课 / 换教室 / 调课 / 补课 ----------
console.log('【单周覆盖】');

function courseIdOf(short: string): number {
  for (const c of courses) {
    if (c.shortName === short) {
      return c.id;
    }
  }
  throw new Error(`找不到课程 ${short}`);
}

function ov(courseId: number, date: string, kind: string, newDate: string, ns: number, ne: number,
  loc: string): SessionOverride {
  return {
    id: 1,
    courseId: courseId,
    date: date,
    kind: kind,
    newDate: newDate,
    newStartSection: ns,
    newEndSection: ne,
    newLocation: loc
  };
}

function countOf(list: CourseSession[], short: string, weekday: number): number {
  let n = 0;
  for (const s of list) {
    if (s.course.shortName === short && s.weekday === weekday) {
      n++;
    }
  }
  return n;
}

function pickOf(list: CourseSession[], short: string, weekday: number): CourseSession | undefined {
  for (const s of list) {
    if (s.course.shortName === short && s.weekday === weekday) {
      return s;
    }
  }
  return undefined;
}

function locationOf(list: CourseSession[], short: string, weekday: number): string {
  const s: CourseSession | undefined = pickOf(list, short, weekday);
  return s === undefined ? '(none)' : s.location;
}

function originOf(list: CourseSession[], short: string, weekday: number): string {
  const s: CourseSession | undefined = pickOf(list, short, weekday);
  return s === undefined ? '(none)' : s.originDate;
}

const gsId: number = courseIdOf('课甲');
const xgId: number = courseIdOf('课丁');

const cancelled: CourseSession[] = computeWeekSessions(sem, courses, rules,
  [ov(gsId, '2026-10-13', OverrideKind.Cancel, '', 0, 0, '')], times, 6);
check('停课：课甲 周二那节不见了', `${countOf(cancelled, '课甲', 2)}`, '0');
check('停课：总数 15 → 14', `${cancelled.length}`, '14');

const roomed: CourseSession[] = computeWeekSessions(sem, courses, rules,
  [ov(gsId, '2026-10-13', OverrideKind.Room, '', 0, 0, '理教101')], times, 6);
check('换教室：地点变了', locationOf(roomed, '课甲', 2), '理教101');
check('换教室：节次没动', `${pickOf(roomed, '课甲', 2)?.startSection}`, '1');

const moved: CourseSession[] = computeWeekSessions(sem, courses, rules,
  [ov(gsId, '2026-10-13', OverrideKind.Move, '2026-10-17', 5, 6, '')], times, 6);
check('调课：周二那节没了', `${countOf(moved, '课甲', 2)}`, '0');
check('调课：出现在周六第 5-6 节', `${countOf(moved, '课甲', 6)}`, '1');
check('调课：originDate 仍记着原定日期', originOf(moved, '课甲', 6), '2026-10-13');
check('调课：总数不变 15', `${moved.length}`, '15');

const extended: CourseSession[] = computeWeekSessions(sem, courses, rules,
  [ov(xgId, '2026-10-17', OverrideKind.Extra, '2026-10-17', 3, 4, '')], times, 6);
check('补课：总数 15 → 16', `${extended.length}`, '16');
check('补课：课丁多了一节在周六', `${countOf(extended, '课丁', 6)}`, '1');
check('补课：没写地点就回退到课程默认地点', locationOf(extended, '课丁', 6), '教学楼101');

const both: CourseSession[] = computeWeekSessions(sem, courses, rules,
  [ov(gsId, '2026-10-13', OverrideKind.Move, '2026-10-17', 5, 6, ''),
    ov(xgId, '2026-10-17', OverrideKind.Extra, '2026-10-17', 3, 4, '')], times, 6);
check('调课 + 补课同时生效：16 节', `${both.length}`, '16');

// ---------- 7b. 补课 / 调课 + 换教室（用户 2026-10-15 报的 bug）----------
console.log('【补课 + 换教室：只算一条、地点要生效】');

const extraWithRoom: CourseSession[] = computeWeekSessions(sem, courses, rules,
  [ov(xgId, '2026-10-17', OverrideKind.Extra, '2026-10-17', 3, 4, ''),
    ov(xgId, '2026-10-17', OverrideKind.Room, '', 0, 0, '理教202')], times, 6);
check('补课 + 单独一条换教室：地点用换教室那条', locationOf(extraWithRoom, '课丁', 6), '理教202');
check('补课那节的 isExtra = true', `${pickOf(extraWithRoom, '课丁', 6)?.isExtra}`, 'true');
check('补课自己写了地点就优先用它', locationOf(computeWeekSessions(sem, courses, rules,
  [ov(xgId, '2026-10-17', OverrideKind.Extra, '2026-10-17', 3, 4, '教学楼101')], times, 6),
  '课丁', 6), '教学楼101');
check('规则课 isExtra = false', `${pickOf(week6, '课甲', 2)?.isExtra}`, 'false');

const mergeInput: SessionOverride[] = [
  ov(xgId, '2026-10-17', OverrideKind.Extra, '2026-10-17', 3, 4, ''),
  ov(xgId, '2026-10-17', OverrideKind.Room, '', 0, 0, '理教202')
];
mergeInput[0].id = 11;
mergeInput[1].id = 12;
const merged = mergeRoomOverrides(mergeInput);
check('合并后只剩一条（"补课详情不应显示两条"）', `${merged.list.length}`, '1');
check('   └ 被删的是那条 room', `${merged.deleteIds.length === 1 && merged.deleteIds[0] === 12}`, 'true');
check('   └ 地点写进了补课那条', merged.list[0].newLocation, '理教202');
check('   └ 补课的节次没丢', `${merged.list[0].newStartSection}-${merged.list[0].newEndSection}`, '3-4');
check('再合并一次是幂等的', `${mergeRoomOverrides(merged.list).deleteIds.length}`, '0');

const moveRoom: SessionOverride[] = [
  ov(gsId, '2026-10-13', OverrideKind.Move, '2026-10-17', 5, 6, ''),
  ov(gsId, '2026-10-13', OverrideKind.Room, '', 0, 0, '三教101')
];
moveRoom[0].id = 21;
moveRoom[1].id = 22;
const mergeMove = mergeRoomOverrides(moveRoom);
check('调课 + 换教室也合成一条', `${mergeMove.list.length}`, '1');
check('   └ 地点写进了调课那条', mergeMove.list[0].newLocation, '三教101');
check('   └ 新日期没丢', mergeMove.list[0].newDate, '2026-10-17');

const loneRoom: SessionOverride[] = [ov(gsId, '2026-10-13', OverrideKind.Room, '', 0, 0, '理教101')];
check('孤立的换教室保持原样', `${mergeRoomOverrides(loneRoom).list.length}`, '1');
check('   └ 没有要删的', `${mergeRoomOverrides(loneRoom).deleteIds.length}`, '0');

// ---------- 8. 每日简报正文 ----------
console.log('【每日简报正文】');

function todo(title: string, ddl: string): Todo {
  return {
    id: 1,
    title: title,
    courseId: 0,
    endAt: '',
    category: 'homework',
    priority: 1,
    ddl: ddl,
    estimateMin: 60,
    status: 'active',
    source: 'manual',
    generationKey: '',
    note: '',
    submitChannel: '',
    repeatRule: '',
    photos: '',
    createdAt: 0,
    confirmedAt: 0,
    doneAt: 0
  };
}

const thuBrief: CourseSession[] = week6.filter((s: CourseSession): boolean => s.weekday === 4);
check('周四（3 节课）',
  buildBriefing('2026-10-15', thuBrief, []),
  '3 节课：08:00 课乙 教学楼309；10:10 课甲 教学楼407；18:40 课乙习题 教学楼406');
check('没课的那天', buildBriefing('2026-10-17', [], []), '今天没有课。');
check('加上当天截止',
  buildBriefing('2026-10-15', thuBrief, [todo('课甲作业', '2026-10-15 23:59')]),
  '3 节课：08:00 课乙 教学楼309；10:10 课甲 教学楼407；18:40 课乙习题 教学楼406 ｜ 今天截止：课甲作业 23:59');
check('别的日期的 ddl 不进简报',
  buildBriefing('2026-10-15', thuBrief, [todo('课乙作业', '2026-10-16 23:59')]),
  '3 节课：08:00 课乙 教学楼309；10:10 课甲 教学楼407；18:40 课乙习题 教学楼406');
check('没有截止时间的待办不进简报',
  buildBriefing('2026-10-15', thuBrief, [todo('随手记', '')]),
  '3 节课：08:00 课乙 教学楼309；10:10 课甲 教学楼407；18:40 课乙习题 教学楼406');
check('没课但有截止',
  buildBriefing('2026-10-17', [], [todo('课丁作业', '2026-10-17 23:59')]),
  '今天没有课。 ｜ 今天截止：课丁作业 23:59');

// ---------- 9. 备份格式往返 ----------
console.log('【备份格式往返】');
check('空文本被拒', `${parseBackup('') === undefined}`, 'true');
check('非法 JSON 被拒', `${parseBackup('{oops') === undefined}`, 'true');
check('别的 App 的备份被拒',
  `${parseBackup('{"app":"Other","version":1}') === undefined}`, 'true');
check('过新的版本被拒',
  `${parseBackup('{"app":"ClassOUT","version":99}') === undefined}`, 'true');
check('本版本被接受',
  `${parseBackup('{"app":"ClassOUT","version":1}') !== undefined}`, 'true');

const emptyB: BackupBundle = emptyBundle('2026-10-13');
const emptyBack: BackupBundle | undefined = parseBackup(serializeBackup(emptyB));
check('空备份可往返', `${emptyBack === undefined ? -1 : countBackup(emptyBack).courses}`, '0');

const fullB: BackupBundle = emptyBundle('2026-10-13');
fullB.semesters.push(sem);
for (const c of courses) {
  fullB.courses.push(c);
}
for (const r of rules) {
  fullB.rules.push(r);
}
fullB.todos.push(todo('课甲作业', '2026-10-15 23:59'));
const fullBack: BackupBundle | undefined = parseBackup(serializeBackup(fullB));
check('课程数往返一致', `${fullBack === undefined ? -1 : fullBack.courses.length}`,
  `${courses.length}`);
check('时段数往返一致', `${fullBack === undefined ? -1 : fullBack.rules.length}`,
  `${rules.length}`);
check('字段内容往返一致',
  fullBack === undefined ? '(none)' : fullBack.todos[0].title, '课甲作业');
check('学期字段往返一致',
  fullBack === undefined ? '(none)' : fullBack.semesters[0].startDate, '2026-09-07');
check('摘要文本',
  fullBack === undefined ? '' : backupSummary(fullBack),
  '学期 1 · 课程 11 · 时段 15 · 节次 0 · 生成模板 0 · 待办 1 · 计划块 0 · 课时 0 · 单周覆盖 0 · 休息时段 0');

// ---------- 10. 考试倒计时 ----------
console.log('【考试倒计时】');
const examBase: Date = parseDate('2026-10-13');
check('还有 7 天', countdownText(parseDate('2026-10-20'), examBase), '还有 7 天');
check('还有 2 天', countdownText(parseDate('2026-10-15'), examBase), '还有 2 天');
check('明天', countdownText(parseDate('2026-10-14'), examBase), '明天');
check('就是今天', countdownText(parseDate('2026-10-13'), examBase), '就是今天');
check('已结束', countdownText(parseDate('2026-10-11'), examBase), '已结束 2 天');

// ---------- 11. 「所有块完成 → 待办自动完成」 ----------
console.log('【块完成判定（跨天）】');

function blk(id: number, todoId: number, date: string, done: boolean): PlanBlock {
  return {
    id: id,
    todoId: todoId,
    lessonId: 0,
    date: date,
    startMin: 600,
    endMin: 660,
    done: done
  };
}

check('只有一个块且已完成 → 完成',
  `${allBlocksDone([blk(1, 5, '2026-10-13', true)], 5)}`, 'true');
check('跨天拆分：今天完成、明天没完成 → 不算完成',
  `${allBlocksDone([blk(1, 5, '2026-10-13', true), blk(2, 5, '2026-10-14', false)], 5)}`, 'false');
check('跨天拆分：两块都完成 → 完成',
  `${allBlocksDone([blk(1, 5, '2026-10-13', true), blk(2, 5, '2026-10-14', true)], 5)}`, 'true');
check('块取消打勾 → 回到未完成',
  `${allBlocksDone([blk(1, 5, '2026-10-13', true), blk(2, 5, '2026-10-14', false)], 5)}`, 'false');
check('没有任何块 → 不判定为完成',
  `${allBlocksDone([], 5)}`, 'false');
check('只统计目标待办的块',
  `${allBlocksDone([blk(1, 7, '2026-10-13', true)], 5)}`, 'false');

// ---------- 待安排托盘：当天已排的待办必须从托盘消失 ----------
// 回归自用户实测：拖进网格后托盘里还在，能反复拖出重复块。

function td(id: number, title: string, status: string): Todo {
  return {
    id: id,
    title: title,
    courseId: 0,
    endAt: '',
    category: '',
    priority: 0,
    ddl: '',
    estimateMin: 90,
    status: status,
    source: '',
    generationKey: '',
    note: '',
    submitChannel: '',
    repeatRule: '',
    photos: '',
    createdAt: 0,
    confirmedAt: 0,
    doneAt: 0
  };
}

function titles(list: Todo[]): string {
  return list.map((t: Todo): string => t.title).join(',');
}

// 当天网格里已有的块（blk() 造的块 date 由参数给，这里只造当天的）
const dayBlocks: PlanBlock[] = [blk(1, 5, '2026-10-13', false)];
const pool3: Todo[] = [td(5, '已排的', 'active'), td(6, '没排的', 'active'),
  td(7, '做完的', 'done'), td(8, '归档的', 'archived')];

check('active 且当天没排过 → 留在托盘',
  titles(selectPoolTodos(pool3, [])), '已排的,没排的');
check('当天已排过 → 从托盘移出（防重复拖拽）',
  titles(selectPoolTodos(pool3, dayBlocks)), '没排的');
check('done / archived 不进托盘',
  titles(selectPoolTodos([td(7, '做完的', 'done'), td(8, '归档的', 'archived')], [])), '');
check('块属于别的待办 → 不影响本待办',
  titles(selectPoolTodos([td(5, 'A', 'active')], [blk(1, 99, '2026-10-13', false)])), 'A');
check('空待办列表 → 空托盘',
  titles(selectPoolTodos([], dayBlocks)), '');

  // ---- 防重复落块 + "已排"角标（用户实测：拖到侧列后托盘里还在 → 又拖一次 → 重复块、
  //      预计时间越滚越长）----
  const multiDay: PlanBlock[] = [
    blk(1, 5, '2026-10-14', false),
    blk(2, 5, '2026-10-15', false),
    blk(3, 6, '2026-10-15', false)
  ];
  // 同一天已经排过 → 不许再排一块
  check('10/14 已排过 5 号', String(hasBlockOnDate(multiDay, 5, '2026-10-14')), 'true');
  check('10/15 也排过', String(hasBlockOnDate(multiDay, 5, '2026-10-15')), 'true');
  check('10/16 没排过 → 可以排', String(hasBlockOnDate(multiDay, 5, '2026-10-16')), 'false');
  check('别的待办不算', String(hasBlockOnDate(multiDay, 7, '2026-10-14')), 'false');
  // 注意：只挡"同一天"。跨天拆块必须仍然允许（HANDOFF §5 的设计约束），
  // 所以这里显式断言"排过 10/14 不代表不能在 10/16 再排一块"。
  check('跨天拆块仍允许（只挡同一天）',
    String(hasBlockOnDate(multiDay, 5, '2026-10-14') && !hasBlockOnDate(multiDay, 5, '2026-10-16')),
    'true');

  // "已排"角标：升序去重，只看该待办自己的块
  check('已排两天', scheduledDays(multiDay, 5).join(','), '2026-10-14,2026-10-15');
  check('已排一天', scheduledDays(multiDay, 6).join(','), '2026-10-15');
  check('没排过=空', String(scheduledDays(multiDay, 9).length), '0');
  check('空块集=空', String(scheduledDays([], 5).length), '0');

// 关键：`selectPoolTodos` 只按「传入的块」过滤，**和日期无关**。
// 2026-10-14 用户改的规则：调用方传**全部日期**的块 ——「无论放到哪一天，待安排栏里的
// 对应项都该消失」。下面显式钉住这条：块排在别的天，也照样把待办从托盘里滤掉。
check('块排在别的天（传全部块）→ 托盘里也没有它',
  titles(selectPoolTodos([td(5, '排过别天的', 'active')], [blk(1, 5, '2026-10-20', false)])), '');
check('块排在那天（传全部块）→ 同理',
  titles(selectPoolTodos([td(5, '排过这天的', 'active')], [blk(1, 5, '2026-10-14', false)])), '');
// 传空块集时它当然还在托盘里 —— 这条是给"数据没加载出来"这种情况兜底的语义
check('传空块集 → 仍在托盘（过滤只看传入的块）',
  titles(selectPoolTodos([td(5, '已排的', 'active')], [])), '已排的');

// ---------- 对半分（块属性窗的「对半分」）----------
console.log('【对半分：两块都是 5 的倍数、和严格等于原时长】');
check('90 → 45+45', halveMinutes(90).join('+'), '45+45');
check('95 → 45+50（相近的两个 5 的倍数）', halveMinutes(95).join('+'), '45+50');
check('100 → 50+50', halveMinutes(100).join('+'), '50+50');
check('105 → 50+55', halveMinutes(105).join('+'), '50+55');
check('15 → 5+10', halveMinutes(15).join('+'), '5+10');
check('10 → 5+5', halveMinutes(10).join('+'), '5+5');
check('5 → 拆不开（返回空）', String(halveMinutes(5).length), '0');
check('0 → 拆不开', String(halveMinutes(0).length), '0');
// 和必须严格等于原时长：这一条防的是"各自四舍五入"那种实现（会让预计时长凭空变）
check('和严格等于原时长（90/95/105 各查一遍）',
  `${halveMinutes(90)[0] + halveMinutes(90)[1]},${halveMinutes(95)[0] + halveMinutes(95)[1]},${halveMinutes(105)[0] + halveMinutes(105)[1]}`,
  '90,95,105');
check('两块都 ≥5 分钟且落在 5 的刻度上',
  `${halveMinutes(95)[0] % 5},${halveMinutes(95)[1] % 5},${halveMinutes(15)[0] >= 5}`,
  '0,0,true');
check('两块相差不超过 5（"平分"的实质）',
  String(Math.abs(halveMinutes(95)[0] - halveMinutes(95)[1]) <= 5), 'true');

// ---------- 时间轴不变式（回归自「底部 24:00 被裁掉」的真 bug）----------
console.log('【时间轴：刻度行不超出网格，最多差最后半段】');

/**
 * 不变式：
 *   ① 前 n−1 行刻度的满行高**严格小于**网格高度（否则多画了一整行）；
 *   ② 网格高度**不超过** n 行刻度（末行可以不足 60 分钟，但不能超出）；
 *   ③ 高度是 30 的倍数（起止吸附到整半小时）；
 *   ④ 第一个刻度就是起点。
 *
 * ⚠️ 2026-10-15 起允许半小时边界，所以不能再要求"恰好铺满"——
 * 07:30–24:00 的最后一格只有 30 分钟，07:00–22:30 同理。把"末行余量 ∈ (0,60]"
 * 钉死，免得以后又把尾段算丢（旧 bug 就是底部被裁）。
 */
function invariantHolds(axis: TimeAxis): boolean {
  const n: number = axis.marks.length;
  const full: number = (n - 1) * 60;
  return n > 0
    && axis.height() > full
    && axis.height() <= n * 60
    && axis.height() % 30 === 0
    && axis.marks[0] === axis.startMin;
}

function spanOf(axis: TimeAxis): string {
  return `${axis.startMin}-${axis.endMin}`;
}

// 这一条就是旧实现的 bug：06:00–24:00 生成 19 个刻度 ×60 = 1140，容器只有 1080
check('06:00–24:00（旧默认窗）不再多画一行', `${invariantHolds(new TimeAxis({ startMin: 360, endMin: 1440 }))}`, 'true');
check('   └ 刻度数正好 18 个', `${new TimeAxis({ startMin: 360, endMin: 1440 }).marks.length}`, '18');
check('07:00–24:00（新默认窗）不变式成立', `${invariantHolds(new TimeAxis(DEFAULT_WINDOW))}`, 'true');
check('   └ 刻度数 17 个', `${new TimeAxis(DEFAULT_WINDOW).marks.length}`, '17');
check('   └ 高度 1020vp', `${new TimeAxis(DEFAULT_WINDOW).height()}`, '1020');
check('8 小时整窗不变式成立', `${invariantHolds(new TimeAxis({ startMin: 480, endMin: 960 }))}`, 'true');
check('起点不在整点（07:30）**保留**半小时', `${invariantHolds(new TimeAxis({ startMin: 450, endMin: 1440 }))}`, 'true');
check('   └ 07:30 仍是 07:30', `${new TimeAxis({ startMin: 450, endMin: 1440 }).startMin}`, '450');
check('末段半小时（07:00–22:30）**保留**', `${new TimeAxis({ startMin: 420, endMin: 1350 }).endMin}`, '1350');
check('   └ 不变式成立（末行只有 30 分钟）', `${invariantHolds(new TimeAxis({ startMin: 420, endMin: 1350 }))}`, 'true');
check('   └ 末行正好 30 分钟',
  `${new TimeAxis({ startMin: 420, endMin: 1350 }).height() - (new TimeAxis({ startMin: 420, endMin: 1350 }).marks.length - 1) * 60}`,
  '30');
check('起点和终点都是半点（07:30–22:00）不变式成立',
  `${invariantHolds(new TimeAxis({ startMin: 450, endMin: 1320 }))}`, 'true');
check('最小 1 小时窗不变式成立', `${invariantHolds(new TimeAxis({ startMin: 420, endMin: 480 }))}`, 'true');

console.log('【时间窗规范化（整半小时刻度）】');
check('起点 428 先吸附到半小时 → 420',
  spanOf(new TimeAxis({ startMin: 428, endMin: 1440 })), '420-1440');
check('半小时吸附常量为 30', `${WINDOW_SNAP_MIN}`, '30');
check('   └ 435 吸附成 450', `${new TimeAxis({ startMin: 435, endMin: 1440 }).startMin}`, '450');
check('end 超过 24:00 被夹回', `${normalizeWindow({ startMin: 420, endMin: 1500 }).endMin}`, `${WINDOW_MAX_END}`);
check('start 低于 0 被夹回', `${normalizeWindow({ startMin: -100, endMin: 1440 }).startMin}`, '0');
check('窗太窄时撑到最小跨度', `${normalizeWindow({ startMin: 600, endMin: 610 }).endMin - normalizeWindow({ startMin: 600, endMin: 610 }).startMin}`, `${WINDOW_MIN_SPAN}`);
check('整体越界也能得到合法窗',
  `${normalizeWindow({ startMin: 1400, endMin: 1400 }).endMin - normalizeWindow({ startMin: 1400, endMin: 1400 }).startMin}`, `${WINDOW_MIN_SPAN}`);

console.log('【时间窗的存取（设置页 ↔ 计划页）】');
check('往返：07:30–22:30', formatWindow({ startMin: 450, endMin: 1350 }), '450,1350');
check('解析：450,1350 → 07:30–22:30',
  `${parseWindow('450,1350').startMin}-${parseWindow('450,1350').endMin}`, '450-1350');
check('解析：空串 → 默认窗',
  `${parseWindow('').startMin}-${parseWindow('').endMin}`,
  `${DEFAULT_WINDOW.startMin}-${DEFAULT_WINDOW.endMin}`);
check('解析：半截字符串 → 默认窗',
  `${parseWindow('450').startMin}-${parseWindow('450').endMin}`,
  `${DEFAULT_WINDOW.startMin}-${DEFAULT_WINDOW.endMin}`);
check('解析：垃圾值 → 默认窗',
  `${parseWindow('x,y').startMin}-${parseWindow('x,y').endMin}`,
  `${DEFAULT_WINDOW.startMin}-${DEFAULT_WINDOW.endMin}`);
check('解析：脏值会被规范化（30,10 → 0,60）', formatWindow(parseWindow('30,10')), '0,60');

console.log('【内容驱动时间窗】');
// 周三真实内容：08:00 第一节开课、19:30 课甲习题课下课
// （注意：是节次的 start/end，不是节次编号。19:30 = 1170）
const wedContent: number[] = [480, 1170];
check('周三内容 08:00–19:30、上下各留 60 分 → 07:00–20:30',
  spanOf(new TimeAxis(windowForContent(wedContent, 60, 420, 1440))), '420-1230');
check('   └ 比满窗（07:00–24:00）短 3.5 小时',
  `${new TimeAxis(DEFAULT_WINDOW).height() - new TimeAxis(windowForContent(wedContent, 60, 420, 1440)).height()}`,
  '210');
check('周一两节 13:00–17:00 → 12:00–18:00',
  spanOf(new TimeAxis(windowForContent([780, 1020], 60, 420, 1440))), '720-1080');
check('没有内容时退回默认窗',
  spanOf(new TimeAxis(windowForContent([], 60, 420, 1440))), '420-1440');
check('内容整体早于下限 → 起点被夹到 07:00（不是原内容时间）',
  `${windowForContent([300], 60, 420, 1440).startMin}`, '420');
check('单点内容也能得到合法窗且不变式成立',
  `${invariantHolds(new TimeAxis(windowForContent([600], 60, 420, 1440)))}`, 'true');
check('所有内容驱动窗都满足不变式',
  `${invariantHolds(new TimeAxis(windowForContent(wedContent, 60, 420, 1440))) && invariantHolds(new TimeAxis(windowForContent([780, 1020], 60, 420, 1440))) && invariantHolds(new TimeAxis(windowForContent([], 60, 420, 1440)))}`,
  'true');

// ---------- 待安排格排序 ----------
console.log('【待安排排序：有截止的在前】');

function td2(id: number, title: string, ddl: string): Todo {
  const t: Todo = td(id, title, 'active');
  t.ddl = ddl;
  return t;
}

check('无截止的排最后',
  titles(sortPoolTodos([td2(1, '无截止', ''), td2(2, '有截止', '2026-10-14 23:59')])),
  '有截止,无截止');
check('两个都有截止 → 按时间升序',
  titles(sortPoolTodos([td2(1, '晚', '2026-10-15 23:59'), td2(2, '早', '2026-10-14 23:59')])),
  '早,晚');
check('截止相同时按 id 升序（顺序稳定）',
  titles(sortPoolTodos([td2(9, 'B', '2026-10-14 23:59'), td2(3, 'A', '2026-10-14 23:59')])),
  'A,B');
check('全无截止 → 按 id 升序',
  titles(sortPoolTodos([td2(7, 'X', ''), td2(2, 'Y', '')])), 'Y,X');
check('不修改传入数组（纯函数）',
  `${sortPoolTodos([td2(1, '无', ''), td2(2, '有', '2026-10-14 23:59')])[0].title}|${[td2(1, '无', ''), td2(2, '有', '2026-10-14 23:59')][0].title}`,
  '有|无');

// ---------- 块的排版分档（紧凑 vs 常规）----------
// ★ 这里**直接 import 生产代码的常量与公式**（domain/PlanLayout）。
//   以前这一节把 LayoutSpec 的档位和两个公式**又抄了一遍**，注释还写着
//   "这些数字必须和 PlanDayView 里的一致" —— 抄一遍的断言发现不了漂移
//   （这正是本轮那个拖拽符号 bug 的同类错误）。现在两边共用一份。
console.log('【块排版分档】');

/** 块按真实时长算的高度 = 时长 − 2（和 PlanDayView.blockTimedH 一致） */
const timedH = (min: number): number => min - 2;
const TH: number = compactThreshold();
const MINH: number = compactMinH();

check('当前档位：15 分钟块走紧凑', `${timedH(15) < TH}`, 'true');
check('当前档位：20 分钟块走紧凑', `${timedH(20) < TH}`, 'true');
check('当前档位：34 分钟块走紧凑（临界下方）', `${timedH(34) < TH}`, 'true');
check('当前档位：36 分钟块走常规（临界上方）', `${timedH(36) >= TH}`, 'true');
check('当前档位：60 分钟块走常规', `${timedH(60) >= TH}`, 'true');
check('当前档位：紧凑块撑高装得下一行紧凑字', `${MINH >= Math.ceil(LAYOUT.compact * 1.4)}`, 'true');
check('当前档位：15 分钟块撑高不超过真实时长 +4vp', `${MINH - timedH(15) <= 4}`, 'true');
check('当前档位：紧凑字号小于正文字号', `${LAYOUT.compact < LAYOUT.title}`, 'true');
// 钉住具体数字：改字号必须显式改这一行（否则说明你顺手改坏了档位）
check('排版分档的具体数字（title/sub/compact/阈值/撑高）',
  `${LAYOUT.title}/${LAYOUT.sub}/${LAYOUT.compact}/${TH}/${MINH}`, '14/11/10/34/14');

// ---------- 选中 / 长按 状态机（2026-10-14 替换掉旧的"长按武装 + 把手"）----------
// 用户定的模型：
//   单击块 = 选中（黑框）；已选中的同一条再单击 = 开编辑窗
//   单击另一条 = 直接改选；单击空白 = 取消选中
//   长按**已选中**的块 = 振动 + 进入拖拽（两步，不能省）
//   长按未选中的块 = 什么都不做（保证"想滚动时间轴"的人不会误拖）
//   底边「⋯」把手已删除 → 改时长只走双指缩放与编辑窗（旧的手把守卫断言随之作废）
// ★ 断言调用的是**生产代码里的同一个函数**，不是在这里重写一遍判据。
console.log('【选中 / 长按 状态机】');

check('未选中时单击 → 选中', `${tapAction(0, 7)}`, TAP_SELECT);
check('单击另一条 → 改选它', `${tapAction(3, 7)}`, TAP_SELECT);
check('单击已选中的同一条 → 开编辑窗', `${tapAction(7, 7)}`, TAP_OPEN);

check('长按未选中的块 → 不放行（想滚动的人不会误拖）', `${canBeginDrag(0, 7)}`, 'false');
check('长按另一条已选中的块 → 也不放行', `${canBeginDrag(3, 7)}`, 'false');
check('长按已选中的这个块 → 放行', `${canBeginDrag(7, 7)}`, 'true');
check('blockId 为 0（无效块）→ 永不放行', `${canBeginDrag(0, 0)}`, 'false');

// ---------- 列几何（三日视图） ----------
// 时间轴占 46vp，剩下的宽度按列数均分。全部是 vp（Area / 事件坐标都是 vp）。
console.log('【列几何：三日视图】');

check('时间轴宽度', `${AXIS_W}`, '46');
check('单日视图的列数', `${COLS_DAY}`, '1');
check('三日视图的列数', `${COLS_THREE}`, '3');
check('内容区宽 = 视口 − 时间轴', `${contentWidth(406)}`, '360');
check('视口比时间轴还窄 → 夹到 0，不给负数', `${contentWidth(40)}`, '0');
check('恰等于时间轴宽 → 0', `${contentWidth(46)}`, '0');
check('单日：列宽 = 全部内容区', `${columnWidth(406, 1)}`, '360');
check('三日：列宽 = 内容区 / 3', `${columnWidth(406, 3)}`, '120');
check('列数非法 → 列宽 0', `${columnWidth(406, 0)}`, '0');
check('第 0 列左边缘 = 时间轴右边', `${columnX(406, 3, 0)}`, '46');
check('第 1 列左边缘', `${columnX(406, 3, 1)}`, '166');
check('第 2 列左边缘', `${columnX(406, 3, 2)}`, '286');

check('命中：落在时间轴上 → -1（不改天）', `${columnAtX(406, 3, 20)}`, '-1');
check('命中：x 为负（拖到网格左侧外）→ -1', `${columnAtX(406, 3, -50)}`, '-1');
check('命中：时间轴右边界 → 第 0 列', `${columnAtX(406, 3, 46)}`, '0');
check('命中：第 0 列中间', `${columnAtX(406, 3, 100)}`, '0');
check('命中：第 0/1 列分界 → 第 1 列', `${columnAtX(406, 3, 166)}`, '1');
check('命中：第 1 列中间', `${columnAtX(406, 3, 220)}`, '1');
check('命中：第 2 列中间', `${columnAtX(406, 3, 350)}`, '2');
check('命中：右边界内一点点（405）→ 第 2 列', `${columnAtX(406, 3, 405)}`, '2');
// 列的区间是**左闭右开**：x == 内容区宽 算"落在外面" → -1（不改天，比误判成第 3 列安全）
check('命中：网格右边缘是开区间（x == 宽）→ -1', `${columnAtX(406, 3, 406)}`, '-1');
check('命中：超出网格右边 → -1', `${columnAtX(406, 3, 460)}`, '-1');
check('命中：单日视图里任何网格内位置都是第 0 列', `${columnAtX(406, 1, 300)}`, '0');
check('命中：列宽为 0（还没量到宽度）→ -1', `${columnAtX(46, 3, 100)}`, '-1');
check('落点：命中不到就回退到当前列', `${dropColumnOrFallback(406, 3, 10, 1)}`, '1');
check('落点：命中到就用命中的列', `${dropColumnOrFallback(406, 3, 350, 1)}`, '2');

check('三天：中间那列 = 当前查看日',
  `${dayDates('2026-10-14', 3).join('|')}`, '2026-10-13|2026-10-14|2026-10-15');
check('三天：跨月也算对',
  `${dayDates('2026-11-01', 3).join('|')}`, '2026-10-31|2026-11-01|2026-11-02');
check('单日：只有当前查看日', `${dayDates('2026-10-14', 1).join('|')}`, '2026-10-14');
check('列数非法 → 空数组', `${dayDates('2026-10-14', 0).length}`, '0');
check('中间列下标：三日 = 1', `${centerIndex(3)}`, '1');
check('中间列下标：单日 = 0', `${centerIndex(1)}`, '0');
check('列头文字：10/14 是周三', `${columnHeaderText('2026-10-14')}`, '10/14 周三');

// ---------- 拖动位移的滚动补偿 ----------
// 场景：用户长按块后拖动，同时网格因边缘自动滚动而滚动。
//
// 推导（块是网格内容里的绝对定位元素）：
//   块在窗口里的位置 = (视口顶边 − 滚动量) + (原 y + dragOffsetY)
//   要钉在手指下（= 按下点 + 手指位移），于是
//       dragOffsetY = 手指位移 ＋ 滚动量
//
// ★★ 这里曾经写成「手指位移 − 滚动量」，符号是反的，正是用户最后报的
//    「拖到屏幕上下边缘时待办不再跟手跑」。
//    旧断言没抓到，是因为它们把同一套错误模型又写了一遍
//    （"块在窗口中的位置 = 位移 ＋ 滚动量"）——
//    **把实现重述一遍的断言，发现不了建模错误。**
//    所以下面除了数值，还专门断言"补偿方向"和"少补/多补都会漂"。
console.log('【拖动位移：滚动补偿】');

// 块在窗口中的位置（相对按下点）= 位移 − 滚动量（内容被滚走多少，屏幕上就少多少）
function blockInWindow(touchDelta: number, scroll: number): number {
  return dragOffsetWithScroll(touchDelta, scroll) - scroll;
}

check('网格没滚 → 位移就等于手指位移',
  `${dragOffsetWithScroll(100, 0)}`, '100');
check('网格向下滚 50、手指不动 → 块要往下推 50 才能留在原位（补的是 +，不是 −）',
  `${dragOffsetWithScroll(0, 50)}`, '50');
check('网格向上滚 50、手指不动 → 块往上收 50',
  `${dragOffsetWithScroll(0, -50)}`, '-50');
check('手指下移 200、同时网格下滚 50 → 位移 250',
  `${dragOffsetWithScroll(200, 50)}`, '250');
check('手指上移 200、同时网格上滚 50 → 位移 -250',
  `${dragOffsetWithScroll(-200, -50)}`, '-250');

// ★ 用户实测报的 bug：手指停住、网格还在自动滚。
//   逐帧模拟"手指不动 + 网格每帧滚 16"（方向取上、下两种），
//   验证块在窗口中的位置全程不变、且始终等于手指位移。
{
  let upPinned: boolean = true;
  let downPinned: boolean = true;
  const touchDelta: number = -194.791667;   // 手指按住不动（日志里的真实值）
  for (let s2 = 320; s2 >= 176; s2 -= 16) {      // 网格往上滚（露出更早的时间）
    if (Math.abs(blockInWindow(touchDelta, s2 - 320) - touchDelta) > 1e-9) {
      upPinned = false;
    }
  }
  for (let s2 = 0; s2 <= 144; s2 += 16) {        // 网格往下滚（露出更晚的时间）
    if (Math.abs(blockInWindow(touchDelta, s2) - touchDelta) > 1e-9) {
      downPinned = false;
    }
  }
  check('手指停住、网格往上滚 144（每帧 16）→ 块全程钉在手指处', `${upPinned}`, 'true');
  check('手指停住、网格往下滚 144（每帧 16）→ 块全程钉在手指处', `${downPinned}`, 'true');
}

// 不变式：无论网格怎么滚，"块在窗口中的位置"必须只由手指决定。
for (const scroll of [0, 30, -30, 90, -90]) {
  const touch: number = 120;
  check(`网格滚 ${scroll} → 块在窗口中的位置仍等于手指位移 ${touch}`,
    `${blockInWindow(touch, scroll)}`, `${touch}`);
  // ★ 这一条专门钉"符号写反"这个 bug：把减法写回加法的实现，
  //   在同样的滚动量下块会漂 2×滚动量。方向对不上就报错。
  const wrongOffset: number = dragOffsetWithScroll(touch, -scroll);   // 模拟符号反了的实现
  const drift: number = (wrongOffset - scroll) - (blockInWindow(touch, scroll));
  check(`  └ 网格滚 ${scroll}：符号写反会漂 2 倍滚动量（漂移量绝对值）`,
    `${Math.abs(drift)}`, `${2 * Math.abs(scroll)}`);
}

// ---------- 边缘自动滚动的触发判定 ----------
// 视口 400..1400（高 1000），触发区 60：
//   0..60 为顶部区 → 上滚；1340..1400 为底部区 → 下滚；中间不滚
console.log('【边缘自动滚动：触发判定】');

const VT: number = 400;
const VB: number = 1400;
const ZONE: number = 60;

check('触摸点在正中 → 不滚', `${edgeScrollDirection(900, VT, VB, ZONE)}`, '0');
check('刚进顶部区（距上边 59）→ 向上滚', `${edgeScrollDirection(459, VT, VB, ZONE)}`, '-1');
check('恰好在顶部区边界外（距上边 60）→ 不滚', `${edgeScrollDirection(460, VT, VB, ZONE)}`, '0');
check('超过上边界（负值）→ 仍向上滚', `${edgeScrollDirection(300, VT, VB, ZONE)}`, '-1');
check('刚进底部区（距下边 59）→ 向下滚', `${edgeScrollDirection(1341, VT, VB, ZONE)}`, '1');
check('恰好在底部区边界外（距下边 60）→ 不滚', `${edgeScrollDirection(1340, VT, VB, ZONE)}`, '0');
check('超过下边界 → 仍向下滚', `${edgeScrollDirection(1500, VT, VB, ZONE)}`, '1');
check('视口高度为 0（还没量到）→ 不滚', `${edgeScrollDirection(900, 400, 400, ZONE)}`, '0');
check('视口比两个触发区还矮时取更近的一边（靠上→上滚）',
  `${edgeScrollDirection(405, 400, 500, ZONE)}`, '-1');
check('视口比两个触发区还矮时取更近的一边（靠下→下滚）',
  `${edgeScrollDirection(495, 400, 500, ZONE)}`, '1');

// ---------- 边缘自动滚动：深度与逐帧步长 ----------
// 视口 400..1400，触发区 60。深度 0 = 刚跨进触发边界，60 = 贴到/越过屏幕边。
console.log('【边缘自动滚动：深度与逐帧步长】');

check('深度：中间区域 → 0', `${edgeScrollDepth(900, VT, VB, ZONE)}`, '0');
check('深度：刚进顶部区（距上边 59）→ 1', `${edgeScrollDepth(459, VT, VB, ZONE)}`, '1');
check('深度：顶部区半深（距上边 30）→ 30', `${edgeScrollDepth(430, VT, VB, ZONE)}`, '30');
check('深度：正好在上边缘 → 60', `${edgeScrollDepth(400, VT, VB, ZONE)}`, '60');
check('深度：越过上边缘 → 夹在 60', `${edgeScrollDepth(300, VT, VB, ZONE)}`, '60');
check('深度：刚进底部区（距下边 59）→ 1', `${edgeScrollDepth(1341, VT, VB, ZONE)}`, '1');
check('深度：底部区半深（距下边 30）→ 30', `${edgeScrollDepth(1370, VT, VB, ZONE)}`, '30');
check('深度：正好在下边缘 → 60', `${edgeScrollDepth(1400, VT, VB, ZONE)}`, '60');
check('深度：越过下边缘 → 夹在 60', `${edgeScrollDepth(1500, VT, VB, ZONE)}`, '60');
check('深度：视口高度为 0 → 0', `${edgeScrollDepth(900, 400, 400, ZONE)}`, '0');

check('步长：深度 0 也至少走 1vp（否则"定时器在跑但画面不动"）',
  `${edgeScrollStep(0, ZONE, 6)}`, '1');
check('步长：刚进区（深度 1）→ 1vp，几乎不动', `${edgeScrollStep(1, ZONE, 6)}`, '1');
check('步长：深度 10 → 1vp', `${edgeScrollStep(10, ZONE, 6)}`, '1');
check('步长：深度 20 → 2vp', `${edgeScrollStep(20, ZONE, 6)}`, '2');
check('步长：深度 30 → 3vp（线性加速的中點）', `${edgeScrollStep(30, ZONE, 6)}`, '3');
check('步长：深度 60（贴边）→ 上限 6vp', `${edgeScrollStep(60, ZONE, 6)}`, '6');
check('步长：深度超过触发区 → 仍夹在上限', `${edgeScrollStep(200, ZONE, 6)}`, '6');
check('步长：触发区为 0 → 不滚', `${edgeScrollStep(30, 0, 6)}`, '0');
check('步长：上限为 0 → 不滚', `${edgeScrollStep(30, ZONE, 0)}`, '0');
check('步长：速度随深度单调不减（10 → 20 → 40 → 60）',
  `${edgeScrollStep(10, ZONE, 6)}-${edgeScrollStep(20, ZONE, 6)}-${edgeScrollStep(40, ZONE, 6)}-${edgeScrollStep(60, ZONE, 6)}`,
  '1-2-4-6');

// ---------- 块的时间排序（编辑窗「其他块一览」用） ----------
console.log('【块的时间排序】');

const sbC: PlanBlock = { id: 3, todoId: 7, lessonId: 0, date: '2026-10-15',
  startMin: 540, endMin: 600, done: false };
const sbA: PlanBlock = { id: 1, todoId: 7, lessonId: 0, date: '2026-10-14',
  startMin: 600, endMin: 660, done: false };
const sbB: PlanBlock = { id: 2, todoId: 7, lessonId: 0, date: '2026-10-14',
  startMin: 480, endMin: 540, done: false };
check('排序：先按日期、再按开始时间',
  `${sortBlocksByTime([sbC, sbA, sbB]).map((b: PlanBlock) => b.id).join(',')}`, '2,1,3');
check('排序：不改原数组', `${[sbC, sbA, sbB].map((b: PlanBlock) => b.id).join(',')}`, '3,1,2');
check('排序：同日期同开始时间按 id 稳定',
  `${sortBlocksByTime([
    { id: 9, todoId: 7, lessonId: 0, date: '2026-10-14', startMin: 600, endMin: 660, done: false },
    { id: 4, todoId: 7, lessonId: 0, date: '2026-10-14', startMin: 600, endMin: 660, done: false }
  ]).map((b: PlanBlock) => b.id).join(',')}`, '4,9');

// ---------- 数据合法性：待办时长（15 分钟起、5 分钟分度） ----------
// 规则由用户 2026-10-14 拍定：时长至少 15 分钟，且必须是 5 的倍数；
// 旧数据里的非法值（20 以下的、非 5 倍数的）静默搬到这里定义的目标值。
console.log('【数据合法性：待办时长】');

check('5 的倍数判定：20', `${isStepMultiple(20, 5)}`, 'true');
check('5 的倍数判定：23', `${isStepMultiple(23, 5)}`, 'false');
check('0 是任何正数的倍数', `${isStepMultiple(0, 5)}`, 'true');
check('step <= 0 一律不成立', `${isStepMultiple(20, 0)}`, 'false');

check('归一化：20 本来就合法，原样保留', `${normalizeEstimate(20, false)}`, '20');
check('归一化：23 → 25', `${normalizeEstimate(23, false)}`, '25');
check('归一化：22 → 20', `${normalizeEstimate(22, false)}`, '20');
check('归一化：18 → 20', `${normalizeEstimate(18, false)}`, '20');
check('归一化：17 → 15', `${normalizeEstimate(17, false)}`, '15');
check('归一化：12 → 夹到下限 15', `${normalizeEstimate(12, false)}`, '15');
check('归一化：7 → 夹到下限 15', `${normalizeEstimate(7, false)}`, '15');
check('归一化：0 → 视为没填，取默认 60', `${normalizeEstimate(0, false)}`, '60');
check('归一化：NaN → 取默认 60', `${normalizeEstimate(Number.NaN, false)}`, '60');
check('归一化：603 → 夹到上限 600', `${normalizeEstimate(603, false)}`, '600');
check('归一化：598 → 600', `${normalizeEstimate(598, false)}`, '600');
check('归一化：597 → 595', `${normalizeEstimate(597, false)}`, '595');
check('归一化：15 是下限，保留', `${normalizeEstimate(15, false)}`, '15');
check('归一化：600 是上限，保留', `${normalizeEstimate(600, false)}`, '600');
check('归一化：考试类恒为 0（0 是唯一豁免）', `${normalizeEstimate(90, true)}`, '0');
check('归一化：考试类 + NaN 也是 0', `${normalizeEstimate(Number.NaN, true)}`, '0');

check('校验：15 合法', `${validateEstimate(15, false).ok}`, 'true');
check('校验：600 合法', `${validateEstimate(600, false).ok}`, 'true');
check('校验：20 合法（是 5 的倍数）', `${validateEstimate(20, false).ok}`, 'true');
check('校验：14 不合法（低于下限）', `${validateEstimate(14, false).ok}`, 'false');
check('校验：23 不合法（不是 5 的倍数）', `${validateEstimate(23, false).ok}`, 'false');
check('校验：601 不合法（超过上限）', `${validateEstimate(601, false).ok}`, 'false');
check('校验：0 不合法（非考试类）', `${validateEstimate(0, false).ok}`, 'false');
check('校验提示：低于下限', `${validateEstimate(14, false).message}`, '时长至少 15 分钟');
check('校验提示：超过上限', `${validateEstimate(601, false).message}`, '时长最多 600 分钟');
check('校验提示：分度不对', `${validateEstimate(23, false).message}`, '时长必须是 5 分钟的整数倍');
check('校验：考试类永远合法（0 分钟）', `${validateEstimate(0, true).ok}`, 'true');

// 迁移与手动输入必须分开：600 是手动输入的上限，
// 但「多天拆分合计」是推导值，超过 600 是合法的，启动迁移不能把它夹掉。
check('迁移：不设 600 上限（5 天 × 2.5h = 750 原样保留）', `${migrateEstimate(750, false)}`, '750');
check('迁移：超过上限也只对齐到 5 分钟', `${migrateEstimate(603, false)}`, '605');
check('迁移：23 → 25', `${migrateEstimate(23, false)}`, '25');
check('迁移：7 → 15', `${migrateEstimate(7, false)}`, '15');
check('迁移：0 → 60', `${migrateEstimate(0, false)}`, '60');
check('迁移：考试类恒为 0', `${migrateEstimate(750, true)}`, '0');
check('对比：手动输入仍然夹到 600', `${normalizeEstimate(750, false)}`, '600');

// ---------- 数据合法性：生成模板（%变量与截止参数） ----------
console.log('【数据合法性：生成模板】');

check('模板：%D作业 合法', `${validateTemplateTitle('%D作业').ok}`, 'true');
check('模板：八个变量全用上合法',
  `${validateTemplateTitle('%C %c %D %d %W %T %N %R').ok}`, 'true');
check('模板：空串不合法', `${validateTemplateTitle('   ').ok}`, 'false');
check('模板：空串提示', `${validateTemplateTitle('   ').message}`, '模板不能为空');
check('模板：%M 不是支持的变量', `${validateTemplateTitle('%M作业').ok}`, 'false');
check('模板：%M 的提示会列出它并给出可用清单',
  `${validateTemplateTitle('%M作业').message}`, '%M 不是支持的变量。可用：%C %c %D %d %W %T %N %R');
check('模板：未知变量会去重（不是两遍）',
  `${validateTemplateTitle('%Mx%M').message}`, '%M 不是支持的变量。可用：%C %c %D %d %W %T %N %R');
check('模板：末尾孤零零一个 % 也算错', `${validateTemplateTitle('作业%').ok}`, 'false');
check('模板：%% 转义不支持（渲染层没有转义语法）', `${validateTemplateTitle('100%%').ok}`, 'false');
check('模板：大小写敏感，%c 合法而 %C 也合法（两个都在表里）',
  `${validateTemplateTitle('%c%C').ok}`, 'true');
check('模板：%m 小写不是变量', `${validateTemplateTitle('%m').ok}`, 'false');
check('模板：61 个字符太长',
  `${validateTemplateTitle('x'.repeat(61)).ok}`, 'false');
check('模板：60 个字符刚好合法',
  `${validateTemplateTitle('x'.repeat(60)).ok}`, 'true');
check('模板：%D 后面跟中文不影响识别', `${validateTemplateTitle('%D作业%c').ok}`, 'true');

check('截止参数：days 需要 1–365', `${validateTemplateDdl('days', '3').ok}`, 'true');
check('截止参数：days 0 不合法', `${validateTemplateDdl('days', '0').ok}`, 'false');
check('截止参数：days 366 不合法', `${validateTemplateDdl('days', '366').ok}`, 'false');
check('截止参数：days 空不合法', `${validateTemplateDdl('days', '').ok}`, 'false');
check('截止参数：weekday 需要 1–7', `${validateTemplateDdl('weekday', '7').ok}`, 'true');
check('截止参数：weekday 8 不合法', `${validateTemplateDdl('weekday', '8').ok}`, 'false');
check('截止参数：next_session 不带参数也合法',
  `${validateTemplateDdl('next_session', '').ok}`, 'true');
check('截止参数：none 不带参数也合法', `${validateTemplateDdl('none', '').ok}`, 'true');

// ---------- 数据合法性：块时长与双指缩放 ----------
// 时间窗 07:00–24:00（420..1440）。
console.log('【数据合法性：块时长与双指缩放】');

check('结束时间对齐到 5 分钟：15:03 → 15:05', `${resizeEndTo(780, 903, 1440)}`, '905');
check('结束时间对齐到 5 分钟：15:02 → 15:00', `${resizeEndTo(780, 902, 1440)}`, '900');
check('结束时间至少比开始晚 15 分钟', `${resizeEndTo(780, 785, 1440)}`, '795');
check('结束时间不超过窗口末尾', `${resizeEndTo(780, 2000, 1440)}`, '1440');
check('起点离末尾不足 15 分钟时窗口上限优先', `${resizeEndTo(1430, 1500, 1440)}`, '1440');

check('双指放大 1.5 倍：12:00–13:00 → 13:30', `${pinchEnd(720, 780, 1.5, 1440)}`, '810');
check('双指缩小到 0.5 倍：12:00–13:00 → 12:30', `${pinchEnd(720, 780, 0.5, 1440)}`, '750');
check('缩得再小也不低于 15 分钟', `${pinchEnd(720, 780, 0.01, 1440)}`, '735');
check('放得再大也不超过窗口末尾', `${pinchEnd(720, 780, 100, 1440)}`, '1440');
check('倍率非法（0）时退回基准', `${pinchEnd(720, 780, 0, 1440)}`, '780');
check('倍率非法（NaN）时退回基准', `${pinchEnd(720, 780, Number.NaN, 1440)}`, '780');
check('缩放结果永远落在 5 分钟分度上（1.3 倍：60 → 78 → 80）',
  `${pinchEnd(720, 780, 1.3, 1440)}`, '800');

check('缩放提示：变长', `${pinchDeltaLabel(15)}`, '+15 min');
check('缩放提示：变短', `${pinchDeltaLabel(-10)}`, '-10 min');
check('缩放提示：没变', `${pinchDeltaLabel(0)}`, '±0 min');

const pbA: PlanBlock = { id: 1, todoId: 7, lessonId: 0, date: '2026-10-14',
  startMin: 600, endMin: 660, done: false };
const pbB: PlanBlock = { id: 2, todoId: 7, lessonId: 0, date: '2026-10-15',
  startMin: 600, endMin: 630, done: false };
const pbC: PlanBlock = { id: 3, todoId: 9, lessonId: 0, date: '2026-10-15',
  startMin: 600, endMin: 630, done: false };
check('回写用合计：跨天拆成 60 + 30 → 90', `${totalBlockMinutes([pbA, pbB, pbC], 7)}`, '90');
check('回写用合计：只算该待办自己的块', `${totalBlockMinutes([pbA, pbB, pbC], 9)}`, '30');
check('回写用合计：一个块都没有 → -1（调用方据此不回写）',
  `${totalBlockMinutes([pbC], 7)}`, '-1');

// ---------- 数据合法性：作息、时段规则、休息时段 ----------
console.log('【数据合法性：作息与时段规则】');

check('节次：北大第 1 节合法', `${validateSectionTime(PKU_SECTION_TIMES[0]).ok}`, 'true');
check('节次：结束等于开始 → 不合法',
  `${validateSectionTime({ section: 1, startMin: 600, endMin: 600, flexible: false }).ok}`, 'false');
check('节次：结束早于开始 → 不合法',
  `${validateSectionTime({ section: 1, startMin: 600, endMin: 500, flexible: false }).ok}`, 'false');
check('节次：越过 24:00 → 不合法',
  `${validateSectionTime({ section: 1, startMin: 600, endMin: 1500, flexible: false }).ok}`, 'false');
check('节次：编号 0 → 不合法',
  `${validateSectionTime({ section: 0, startMin: 600, endMin: 660, flexible: false }).ok}`, 'false');
check('节次表：北大 12 节合法', `${validateSectionTimes(PKU_SECTION_TIMES).ok}`, 'true');
check('节次表：空表不合法', `${validateSectionTimes([]).ok}`, 'false');
check('节次表：编号重复不合法',
  `${validateSectionTimes([
    { section: 1, startMin: 600, endMin: 660, flexible: false },
    { section: 1, startMin: 700, endMin: 760, flexible: false }
  ]).ok}`, 'false');

const okRule: SessionRule = { id: 1, courseId: 1, weekday: 2, startSection: 1, endSection: 2,
  weeksMask: '1111111111111111', location: '', isQuiz: false };
check('时段规则：合法', `${validateSessionRule(okRule, PKU_SECTION_TIMES).ok}`, 'true');
check('时段规则：起止时间由首末节次推出（第 1–2 节 = 08:00–09:50）',
  `${spanOfRule(okRule, PKU_SECTION_TIMES).join('-')}`, '480-590');
check('时段规则：开始晚于结束 → 不合法',
  `${validateSessionRule({ ...okRule, startSection: 3, endSection: 2 }, PKU_SECTION_TIMES).ok}`,
  'false');
check('时段规则：星期 0 → 不合法',
  `${validateSessionRule({ ...okRule, weekday: 0 }, PKU_SECTION_TIMES).ok}`, 'false');
check('时段规则：星期 8 → 不合法',
  `${validateSessionRule({ ...okRule, weekday: 8 }, PKU_SECTION_TIMES).ok}`, 'false');
check('时段规则：引用了作息表里没有的第 13 节 → 不合法',
  `${validateSessionRule({ ...okRule, endSection: 13 }, PKU_SECTION_TIMES).ok}`, 'false');
check('时段规则提示：节次不存在（钉住具体是哪一条校验拦下的）',
  `${validateSessionRule({ ...okRule, endSection: 13 }, PKU_SECTION_TIMES).message}`,
  '作息表里没有第 13 节');
check('时段规则：周次全是 0 → 不合法',
  `${validateSessionRule({ ...okRule, weeksMask: '0000000000000000' }, PKU_SECTION_TIMES).ok}`,
  'false');
check('时段规则：周次是空串 → 不合法',
  `${validateSessionRule({ ...okRule, weeksMask: '' }, PKU_SECTION_TIMES).ok}`, 'false');
check('时段规则提示：开始晚于结束',
  `${validateSessionRule({ ...okRule, startSection: 3, endSection: 2 }, PKU_SECTION_TIMES).message}`,
  '开始节次不能晚于结束节次');

const cfA: SessionRule = { id: 11, courseId: 1, weekday: 2, startSection: 1, endSection: 2,
  weeksMask: '1000000000000000', location: '', isQuiz: false };
const cfB: SessionRule = { id: 12, courseId: 2, weekday: 2, startSection: 2, endSection: 3,
  weeksMask: '1000000000000000', location: '', isQuiz: false };
const cfC: SessionRule = { id: 13, courseId: 3, weekday: 3, startSection: 1, endSection: 2,
  weeksMask: '1000000000000000', location: '', isQuiz: false };
const cfD: SessionRule = { id: 14, courseId: 4, weekday: 2, startSection: 1, endSection: 2,
  weeksMask: '0100000000000000', location: '', isQuiz: false };
check('冲突：同天同周次且时间重叠 → 报 1 处', `${findRuleConflicts([cfA, cfB], PKU_SECTION_TIMES).length}`, '1');
check('冲突：区间取交集（第 2 节 09:00–09:50）',
  `${findRuleConflicts([cfA, cfB], PKU_SECTION_TIMES)[0].overlapStart}-${findRuleConflicts([cfA, cfB], PKU_SECTION_TIMES)[0].overlapEnd}`,
  '540-590');
check('冲突：不同星期 → 不算冲突', `${findRuleConflicts([cfA, cfC], PKU_SECTION_TIMES).length}`, '0');
check('冲突：周次不重叠 → 不算冲突', `${findRuleConflicts([cfA, cfD], PKU_SECTION_TIMES).length}`, '0');
check('冲突：自己和自己不比', `${findRuleConflicts([cfA], PKU_SECTION_TIMES).length}`, '0');

check('休息时段：12:00–13:00 合法',
  `${validateRestWindow({ id: 0, weekday: 0, startMin: 720, endMin: 780, label: '午休' }).ok}`,
  'true');
check('休息时段：默认四条全合法',
  `${DEFAULT_REST_WINDOWS.filter((w: RestWindow) => !validateRestWindow(w).ok).length}`, '0');
check('休息时段：起止相同 → 不合法',
  `${validateRestWindow({ id: 0, weekday: 0, startMin: 720, endMin: 720, label: '' }).ok}`,
  'false');
check('休息时段：结束早于开始 → 不合法',
  `${validateRestWindow({ id: 0, weekday: 0, startMin: 780, endMin: 720, label: '' }).ok}`,
  'false');
check('休息时段：weekday 8 → 不合法',
  `${validateRestWindow({ id: 0, weekday: 8, startMin: 720, endMin: 780, label: '' }).ok}`,
  'false');
check('休息时段提示：结束必须晚于开始',
  `${validateRestWindow({ id: 0, weekday: 0, startMin: 780, endMin: 720, label: '' }).message}`,
  '结束时间必须晚于开始时间');

// 系统时间滚轮只到 23:59，选不到 24:00；「睡觉 23:30–24:00」要靠这条归位（用户 2026-10-15）
check('结束选 00:00、开始 23:30 → 归位成 24:00（1440）',
  `${normalizeRestEnd(0, 23 * 60 + 30)}`, '1440');
check('   └ 归位后能通过校验',
  `${validateRestWindow({ id: 0, weekday: 0, startMin: 23 * 60 + 30, endMin: normalizeRestEnd(0, 23 * 60 + 30), label: '睡觉' }).ok}`,
  'true');
check('开始是 0 时，结束 00:00 不归位（否则会变成 00:00–24:00 的整天空窗）',
  `${normalizeRestEnd(0, 0)}`, '0');
check('普通时刻原样返回', `${normalizeRestEnd(780, 720)}`, '780');

// ---------- 截止时间的"日期+时刻"组装 / 解析（截止时间选择器用）----------
// 真机上的日期/时间选择器给的是 Date，存进库的是 'YYYY-MM-DD HH:mm'。
// 这两个互逆函数就在这条缝上，出错的表现是"挑完时间存进去变成了别的时刻"。
check('formatDateTime：打上时分、补零',
  formatDateTime(new Date(2026, 9, 5, 9, 7)), '2026-10-05 09:07');
check('formatDateTime：午夜 00:00',
  formatDateTime(new Date(2026, 0, 1, 0, 0)), '2026-01-01 00:00');
check('parseDateTime：时分带上了（不是 00:00）',
  formatDateTime(parseDateTime('2026-10-14 14:07')), '2026-10-14 14:07');
check('parseDateTime：分钟不被"5 分钟倍数"那套改动（用户要求 ddl 不受限）',
  formatDateTime(parseDateTime('2026-10-14 14:03')), '2026-10-14 14:03');
check('parseDateTime：空串退回此刻而不是 00:00',
  `${formatDateTime(parseDateTime('')).length}`, '16');
check('parseDateTime→formatDateTime 往返稳定',
  formatDateTime(parseDateTime(formatDateTime(new Date(2026, 11, 31, 23, 58)))),
  '2026-12-31 23:58');

// ---------- 考试的时间范围（③）----------
console.log('【考试：起止时间 → 计划块落在哪一段】');
check('09:00–11:00 → 同一天、120 分钟',
  ((): string => { const r: ExamRange = examRangeOf('2026-10-15 09:00', '2026-10-15 11:00');
    return `${r.date},${r.startMin},${r.endMin},${r.endMin - r.startMin}`; })(),
  '2026-10-15,540,660,120');
check('含非 5 倍数分钟也照算（考试时间不是 5 分钟刻度上的）',
  ((): string => { const r: ExamRange = examRangeOf('2026-10-15 09:07', '2026-10-15 11:03');
    return `${r.startMin},${r.endMin}`; })(),
  '547,663');
check('合法：09:00–11:00', String(validateExamRange('2026-10-15 09:00', '2026-10-15 11:00').ok), 'true');
check('不合法：结束早于开始',
  String(validateExamRange('2026-10-15 11:00', '2026-10-15 09:00').ok), 'false');
check('不合法：起止同刻',
  String(validateExamRange('2026-10-15 09:00', '2026-10-15 09:00').ok), 'false');
check('不合法：跨天（计划块表达不了跨天，提示用户分两天记）',
  String(validateExamRange('2026-10-15 22:00', '2026-10-16 01:00').ok), 'false');
check('不合法：结束没选（空串）',
  String(validateExamRange('2026-10-15 09:00', '').ok), 'false');
check('不合法：只有日期没有时刻',
  String(validateExamRange('2026-10-15', '2026-10-16').ok), 'false');
check('提示语是人话：跨天那条',
  validateExamRange('2026-10-15 22:00', '2026-10-16 01:00').message,
  '考试的开始和结束要在同一天');

// ---------- ⑤ 截止标记：按分钟分组 ----------
console.log('【截止标记：同一分钟合成一组，点开看全部】');

function dt(id: number, title: string, ddl: string, status: string): Todo {
  const t: Todo = td(id, title, status);
  t.ddl = ddl;
  return t;
}

const ddlPool: Todo[] = [
  dt(1, 'A', '2026-10-15 23:59', 'active'),
  dt(2, 'B', '2026-10-15 23:59', 'active'),
  dt(3, 'C', '2026-10-15 12:30', 'active'),
  dt(4, 'D', '2026-10-16 23:59', 'active'),
  dt(5, 'E', '2026-10-15 23:59', 'done'),
  dt(6, 'F', '2026-10-15 02:00', 'active')
];
const dg: DdlGroup[] = ddlGroupsOn(ddlPool, '2026-10-15', 7 * 60);
check('组数：23:59 一组、12:30 一组、02:00 夹到 07:00 一组（另一个日期的不算）',
  `${dg.length}`, '3');
check('组按分钟升序：07:00 → 12:30 → 23:59',
  dg.map((g: DdlGroup): number => g.minute).join(','), '420,750,1439');
check('23:59 那组有 2 条（done 的那条不算）',
  `${dg[2].todos.length}`, '2');
check('组内按 id 升序（顺序稳定，ForEach key 依赖它）',
  dg[2].todos.map((t: Todo): number => t.id).join(','), '1,2');
check('同一分钟的两条不会各占一行（这就是原来"重叠"的根因）',
  `${ddlGroupsOn([dt(9, 'X', '2026-10-15 08:00', 'active'), dt(8, 'Y', '2026-10-15 08:00', 'active')],
    '2026-10-15', 420).length}`, '1');
check('只有日期没有时刻 → 不进标记',
  `${ddlGroupsOn([dt(9, 'X', '2026-10-15', 'active')], '2026-10-15', 420).length}`, '0');
check('空串 ddl → 不进标记',
  `${ddlGroupsOn([dt(9, 'X', '', 'active')], '2026-10-15', 420).length}`, '0');
check('别的日期 → 不进标记（标记只画当前查看日）',
  `${ddlGroupsOn(ddlPool, '2026-10-14', 420).length}`, '0');
check('archived 也不算', `${ddlGroupsOn([dt(9, 'X', '2026-10-15 08:00', 'archived')], '2026-10-15', 420).length}`, '0');
check('晚于时间轴终点 → 夹到终点（时间窗可改，不夹会画到网格外）',
  `${ddlGroupsOn([dt(9, 'X', '2026-10-15 23:59', 'active')], '2026-10-15', 420, 1320)[0].minute}`, '1320');
check('   └ 早于起点仍夹到起点',
  `${ddlGroupsOn([dt(9, 'X', '2026-10-15 02:00', 'active')], '2026-10-15', 420, 1320)[0].minute}`, '420');
check('ddlMinuteOf：23:59 → 1439', `${ddlMinuteOf('2026-10-15 23:59')}`, '1439');
check('ddlMinuteOf：00:07 → 7（非 5 倍数也照算）', `${ddlMinuteOf('2026-10-15 00:07')}`, '7');
check('ddlMinuteOf：没有时刻 → -1', `${ddlMinuteOf('2026-10-15')}`, '-1');

// ---------- 背景图：选区域 / 调位置（用户 2026-10-15）----------
console.log('【背景几何：cover 铺满 + 归一化位置】');

const g1: WallpaperGeometry = wallpaperGeometry(1000, 1000, 360, 800, 1, 0, 0);
check('1:1 的照片填竖屏：按高铺满，宽出 800（360 屏）', `${g1.w},${g1.h}`, '800,800');
check('横向有余量 220、纵向没有（1:1 填竖屏只能左右挪）',
  `${g1.maxDx},${g1.maxDy}`, '220,0');
check('fx=0 → 居中不偏', `${g1.dx},${g1.dy}`, '0,0');
check('fx=1 → 挪到最右（+220）', `${wallpaperGeometry(1000, 1000, 360, 800, 1, 1, 0).dx}`, '220');
check('fx=-1 → 挪到最左（-220）', `${wallpaperGeometry(1000, 1000, 360, 800, 1, -1, 0).dx}`, '-220');
check('fx 超界（2）被夹到 1', `${wallpaperGeometry(1000, 1000, 360, 800, 1, 2, 0).dx}`, '220');
check('zoom=2 → 图变 1600、横向余量 620、纵向开始有余量 400',
  ((): string => { const g: WallpaperGeometry = wallpaperGeometry(1000, 1000, 360, 800, 2, 0, 0);
    return `${g.w},${g.maxDx},${g.maxDy}`; })(),
  '1600,620,400');
check('zoom 小于 1 被夹到 1（绝不露出底色）',
  `${wallpaperGeometry(1000, 1000, 360, 800, 0.2, 0, 0).w}`, '800');
check('zoom 超过上限被夹到 4',
  `${wallpaperGeometry(1000, 1000, 360, 800, 99, 0, 0).w}`, `${800 * WALLPAPER_MAX_ZOOM}`);
check('横图填竖屏：按宽铺满', `${wallpaperGeometry(2000, 1000, 360, 800, 1, 0, 0).w}`, '1600');
check('图片坏掉（0×0）→ 全 0，不抛异常',
  ((): string => { const g: WallpaperGeometry = wallpaperGeometry(0, 0, 360, 800, 1, 0, 0);
    return `${g.w},${g.h},${g.maxDx},${g.maxDy}`; })(),
  '0,0,0,0');
check('还没量到尺寸（box 0）→ 全 0', `${wallpaperGeometry(1000, 1000, 0, 0, 1, 0, 0).w}`, '0');
check('几何是纯函数：同样输入两次结果一样',
  `${JSON.stringify(wallpaperGeometry(1000, 1000, 360, 800, 1.5, 0.3, -0.6))}`,
  `${JSON.stringify(wallpaperGeometry(1000, 1000, 360, 800, 1.5, 0.3, -0.6))}`);

// 存储格式：归一化（换屏幕/横竖屏都不会让构图跑偏）
check('focus 往返：0.25,-0.5,2', formatWallpaperFocus(0.25, -0.5, 2), '0.25,-0.5,2');
check('解析坏数据 → 居中不缩放', parseWallpaperFocus('乱写').join(','), '0,0,1');
check('解析空串 → 居中不缩放', parseWallpaperFocus('').join(','), '0,0,1');
check('解析时越界的值被夹紧', parseWallpaperFocus('9,-9,99').join(','), '1,-1,4');
check('解析后再格式化是幂等的',
  formatWallpaperFocus(parseWallpaperFocus('0.5,0.5,1.5')[0], parseWallpaperFocus('0.5,0.5,1.5')[1],
    parseWallpaperFocus('0.5,0.5,1.5')[2]),
  '0.5,0.5,1.5');
check('clampFocus：NaN 落到下限', clampFocus(Number.NaN, 0, 1).join(','), '-1,0,1');

// ---------- 汇总 ----------
console.log('');
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  throw new Error(`${fail} 项断言失败`);
}
