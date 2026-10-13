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
import { computeWeekSessions, weekOfDate } from './Timetable';
import { maskAll, maskFromText, maskToText, maskHas } from './WeekMask';
import { countdownText, minToHHmm, parseDate } from './DateUtil';
import { computeDdl, renderTitle } from './TodoGenerator';
import { TimeAxis, DEFAULT_WINDOW, WINDOW_MAX_END, allBlocksDone, dragOffsetWithScroll,
  dropRange, edgeScrollDirection, findFreeSlot, moveRange, normalizeDuration, normalizeWindow,
  overlaps, resizeRange,
  selectPoolTodos, snap, sortPoolTodos, windowForContent } from './PlanMath';

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

// ---------- 8. 每日简报正文 ----------
console.log('【每日简报正文】');

function todo(title: string, ddl: string): Todo {
  return {
    id: 1,
    title: title,
    courseId: 0,
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

// 关键：托盘只按「传入的块」过滤。调用方传当天的块，所以换一天待办会重新出现，
// 「拆成多块分散在不同天」不受影响（TESTING.md 第 15 步）。
check('换到明天（传空块集）→ 待办重新出现在托盘',
  titles(selectPoolTodos([td(5, '已排的', 'active')], [])), '已排的');

// ---------- 时间轴不变式（回归自「底部 24:00 被裁掉」的真 bug）----------
console.log('【时间轴：刻度数 × 60 == 网格高度】');

/** 不变式：网格高度必须恰好等于所有刻度行高之和 */
function invariantHolds(axis: TimeAxis): boolean {
  return axis.marks.length * 60 === axis.height();
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
check('起点不在整点（07:30）会被对齐到整点', `${invariantHolds(new TimeAxis({ startMin: 450, endMin: 1440 }))}`, 'true');
check('   └ 07:30 对齐成 07:00', `${new TimeAxis({ startMin: 450, endMin: 1440 }).startMin}`, '420');
check('末段半小时（07:00–22:30）对齐成 23:00', `${new TimeAxis({ startMin: 420, endMin: 1350 }).endMin}`, '1380');
check('   └ 不变式成立', `${invariantHolds(new TimeAxis({ startMin: 420, endMin: 1350 }))}`, 'true');
check('最小 1 小时窗不变式成立', `${invariantHolds(new TimeAxis({ startMin: 420, endMin: 480 }))}`, 'true');

console.log('【时间窗规范化】');
check('起点先吸附到一刻钟，再对齐到整点（428 → 435 → 420）',
  spanOf(new TimeAxis({ startMin: 428, endMin: 1440 })), '420-1440');
check('   └ 吸附本身是 435', `${snap(428)}`, '435');
check('end 超过 24:00 被夹回', `${normalizeWindow({ startMin: 420, endMin: 1500 }).endMin}`, `${WINDOW_MAX_END}`);
check('start 低于 0 被夹回', `${normalizeWindow({ startMin: -100, endMin: 1440 }).startMin}`, '0');
check('窗太窄时撑到最小跨度', `${normalizeWindow({ startMin: 600, endMin: 610 }).endMin - normalizeWindow({ startMin: 600, endMin: 610 }).startMin}`, '60');
check('整体越界也能得到合法窗',
  `${normalizeWindow({ startMin: 1400, endMin: 1400 }).endMin - normalizeWindow({ startMin: 1400, endMin: 1400 }).startMin}`, '60');

console.log('【内容驱动时间窗】');
// 周三真实内容：08:00 第一节开课、19:30 课甲习题课下课
// （注意：是节次的 start/end，不是节次编号。19:30 = 1170）
const wedContent: number[] = [480, 1170];
check('周三内容 08:00–19:30、上下各留 60 分 → 07:00–21:00',
  spanOf(new TimeAxis(windowForContent(wedContent, 60, 420, 1440))), '420-1260');
check('   └ 比满窗（07:00–24:00）短 3 小时',
  `${new TimeAxis(DEFAULT_WINDOW).height() - new TimeAxis(windowForContent(wedContent, 60, 420, 1440)).height()}`,
  '180');
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
// 这些数字必须和 PlanDayView 里的 LayoutSpec / compactThreshold / compactMinH 一致。
// 它们只在真机上肉眼验证过，这里钉住公式，防止以后改字号时把分档改坏。
console.log('【块排版分档】');

interface Tiers { title: number; sub: number; compact: number; }
const TIERS: Tiers[] = [
  { title: 12, sub: 9, compact: 10 },
  { title: 13, sub: 10, compact: 10 },
  { title: 14, sub: 11, compact: 10 },
  { title: 15, sub: 12, compact: 11 },
];

const compactThresholdOf = (t: Tiers): number =>
  Math.ceil(t.title * 1.35) + Math.ceil(t.sub * 1.35);
const compactMinHOf = (t: Tiers): number => Math.ceil(t.compact * 1.4);
/** 块按真实时长算的高度 = 时长 - 2（和 PlanDayView.blockTimedH 一致） */
const timedH = (min: number): number => min - 2;

for (const t of TIERS) {
  const th = compactThresholdOf(t);
  const tag = `${t.title}/${t.sub}(紧凑${t.compact})`;
  check(`${tag}：15 分钟块走紧凑`, `${timedH(15) < th}`, 'true');
  check(`${tag}：20 分钟块走紧凑`, `${timedH(20) < th}`, 'true');
  check(`${tag}：60 分钟块走常规`, `${timedH(60) >= th}`, 'true');
  check(`${tag}：紧凑块被撑到至少 ${compactMinHOf(t)}vp（否则字会被切）`,
    `${compactMinHOf(t) >= Math.ceil(t.compact * 1.4)}`, 'true');
  // 撑高必须 <= 真实时长 + 一个可接受的小量，否则会明显盖住后面
  check(`${tag}：撑高不超过真实时长 +4vp`, `${compactMinHOf(t) - timedH(15) <= 4}`, 'true');
  // 紧凑字号必须小于正文字号（这正是"例外放小"的意思）
  check(`${tag}：紧凑字号 < 正文字号`, `${t.compact < t.title}`, 'true');
}
// 15 分钟块撑高后必须装得下一行字，否则回到"文字被裁"的老 bug
check('15 分钟块撑高后 >= 紧凑字号行高',
  `${compactMinHOf(TIERS[2]) >= Math.ceil(TIERS[2].compact * 1.4)}`, 'true');

// ---------- 「长按才可拖」的守卫判据 ----------
// 交互模型（用户要求）：
//   默认上下滑动 = 滚动时间轴
//   长按块       = 振动 + 进入"已激活"，才允许拖动移位
//   长按底边把手 = 振动 + 才允许改时长（**仅当块够高、真的画了把手**）
// 后一条的守卫很重要：紧凑块不画把手，而把手手势挂在块内层、块手势挂外层，
// 两者会同时收到长按 —— 少了守卫会振两下并同时武装两种模式（真机实测踩到过）。
console.log('【长按才可拖：把手守卫】');

for (const t of TIERS) {
  const th = compactThresholdOf(t);
  const tag = `${t.title}/${t.sub}`;
  // 常规块：画了把手 → 允许武装 resize
  check(`${tag}：60 分钟块画把手 → 允许武装改时长`, `${timedH(60) >= th}`, 'true');
  // 紧凑块：不画把手 → 必须拒绝武装 resize（否则一次长按振两下）
  check(`${tag}：15 分钟块无把手 → 拒绝武装改时长`, `${timedH(15) >= th}`, 'false');
  check(`${tag}：20 分钟块无把手 → 拒绝武装改时长`, `${timedH(20) >= th}`, 'false');
}
// 移动模式的守卫：只有 armedMoveId 命中才允许开始拖（这是"默认滚动不误拖"的核心）
function canBeginMove(armedId: number, blockId: number): boolean {
  return armedId === blockId;
}
check('没长按过 → 不给拖', `${canBeginMove(0, 7)}`, 'false');
check('长按了另一个块 → 也不给拖', `${canBeginMove(3, 7)}`, 'false');
check('长按了这个块 → 给拖', `${canBeginMove(7, 7)}`, 'true');

// ---------- 拖动位移的滚动补偿（回归自"块比屏幕走得快"）----------
// 场景：用户长按块后拖动，同时网格因边缘自动滚动而滚动。
// 块要钉在手指下，块相对网格的位移必须是「手指位移 - 网格滚动量」。
console.log('【拖动位移：滚动补偿】');

check('网格没滚 → 位移就等于手指位移',
  `${dragOffsetWithScroll(100, 0)}`, '100');
check('网格向下滚 50、手指不动 → 块要向上挪 50 才留在原位',
  `${dragOffsetWithScroll(0, 50)}`, '-50');
check('网格向上滚 50、手指不动 → 块向下挪 50',
  `${dragOffsetWithScroll(0, -50)}`, '50');
// ★ 这条是那个 bug 的回归断言：
//   自动滚动每滚 N，块只应补偿 N 一次。补偿两次就会变成 -2N，块比屏幕多走 N。
check('补偿只做一次（做两次会变成 -2N，块就比屏幕快了）',
  `${dragOffsetWithScroll(0, 50)}`, '-50');
check('手指下移 200、同时网格下滚 50 → 净位移 150',
  `${dragOffsetWithScroll(200, 50)}`, '150');
check('手指上移 200、同时网格上滚 50 → 净位移 -150',
  `${dragOffsetWithScroll(-200, -50)}`, '-150');
// ★ 用户实测报的那个 bug：手指停住、网格还在自动滚。
//   旧实现只在 Move 里重算位移，而手指停住就没有 Move 事件 →
//   位移停留在旧值、块跟着网格漂走，松手时还把这个漂掉的值落库（时间跳到 2.4h 之前）。
//   这里逐帧模拟"手指不动 + 网格每帧滚 16"，验证块在窗口中的位置全程不变。
{
  const touchDelta: number = -194.791667;   // 手指按住不动（日志里的真实值）
  const scrollBase: number = 320;
  let allPinned: boolean = true;
  for (let s2 = scrollBase; s2 >= 176; s2 -= 16) {
    const offset: number = dragOffsetWithScroll(touchDelta, s2 - scrollBase);
    const blockInWindow: number = offset + (s2 - scrollBase);
    if (blockInWindow !== touchDelta) {
      allPinned = false;
    }
  }
  check('手指停住、网格从 320 滚到 176（每帧 16）→ 块全程钉在手指处',
    `${allPinned}`, 'true');
  check('   └ 滚到 176 时算出的位移（应把滚动量补回来）',
    `${dragOffsetWithScroll(touchDelta, 176 - scrollBase)}`, `${touchDelta + (scrollBase - 176)}`);
}

// 不变式：无论网格怎么滚，"块在窗口中的位置"必须只由手指决定
for (const scroll of [0, 30, -30, 90, -90]) {
  const touch: number = 120;
  const blockInWindow: number = dragOffsetWithScroll(touch, scroll) + scroll;
  check(`网格滚 ${scroll} 时，块在窗口中的位置仍等于手指位移 ${touch}`,
    `${blockInWindow}`, `${touch}`);
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

// ---------- 汇总 ----------
console.log('');
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  throw new Error(`${fail} 项断言失败`);
}
