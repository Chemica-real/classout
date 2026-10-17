#!/usr/bin/env node
/**
 * 从**鸿蒙端实现**生成 language-neutral 的规则 fixture（三端共用的"标准答案"）。
 *
 * 为什么是"生成"而不是手写：这些规则已经有 524 条断言 + 真机验证过，
 * 直接把它的输出冻成 JSON 比手抄可靠（手抄必然打错数字）。
 * 所以 fixture 的定位是 **等价性基准**（"iOS/Android 必须和鸿蒙端算得一样"），
 * 不是"正确性证明"—— 正确性由 ArkTS 那 524 条断言 + 真机负责。
 *
 * 用法（必须先跑一遍 domain-check，它把纯逻辑编译到 .work/dist）：
 *     ./tools/domain-check/run.sh && node tools/fixtures/gen.js
 * 或者一步：./tools/sync-contract.sh
 */
'use strict';
const fs = require('fs');
const path = require('path');

const DIST = path.join(__dirname, '..', 'domain-check', '.work', 'dist');
const OUT = path.join(__dirname, '..', '..', 'shared', 'fixtures');
if (!fs.existsSync(path.join(DIST, 'PlanMath.js'))) {
  console.error('找不到 ' + DIST + '/PlanMath.js —— 先跑 ./tools/domain-check/run.sh');
  process.exit(1);
}
const PM = require(path.join(DIST, 'PlanMath.js'));

const cases = [];
/** module = 该函数所属的源文件（决定写到 shared/fixtures/<module>.json） */
const add = (fn, args, expect, module) =>
  cases.push({ fn, args, expect, module: module || 'plan_math' });

for (const v of [0, 7, 8, 14, 15, 22, 23, 30, 37, 45, 52, 53, 58, 60, 90, -3, -8]) {
  add('snap', [v], PM.snap(v));
}

const windows = [
  { startMin: 7 * 60, endMin: 24 * 60 },
  { startMin: 8 * 60 + 10, endMin: 22 * 60 + 50 },
  { startMin: 23 * 60, endMin: 25 * 60 },
  { startMin: -30, endMin: 120 },
  { startMin: 12 * 60, endMin: 12 * 60 + 20 },
  { startMin: 9 * 60 + 29, endMin: 10 * 60 + 31 }
];
for (const w of windows) {
  add('normalizeWindow', [w], PM.normalizeWindow(w));
  add('alignWindow', [w], PM.alignWindow(w));
  add('formatWindow', [w], PM.formatWindow(w));
}
for (const s of ['07:00-24:00', '07:00–24:00', '8:00 - 22:30', '00:00-23:30', '乱写', '', '23:00-01:00']) {
  add('parseWindow', [s], PM.parseWindow(s));
}

for (const m of [0, 5, 14, 15, 29, 30, 45, 60, 61, 120, 599, 600, 601, 5000, -10]) {
  add('normalizeDuration', [m], PM.normalizeDuration(m));
}
for (const t of [0, 15, 30, 45, 60, 75, 90, 105, 120, 150, 999]) {
  add('halveMinutes', [t], PM.halveMinutes(t));
}

const spans = [[480, 540], [480, 480], [500, 560], [540, 600], [539, 541], [0, 1440]];
for (const a of spans) for (const b of spans) {
  add('overlaps', [a[0], a[1], b[0], b[1]], PM.overlaps(a[0], a[1], b[0], b[1]));
}

for (const d of ['2026-10-18 23:59', '2026-10-18 00:00', '2026-10-18 12:34', '', '2026-10-18']) {
  add('ddlMinuteOf', [d], PM.ddlMinuteOf(d));
}

const todos = [
  { id: 1, title: '作业甲', courseId: 1, category: 'homework', status: 'active', ddl: '2026-10-18 23:59' },
  { id: 2, title: '作业乙', courseId: 1, category: 'homework', status: 'pending', ddl: '2026-10-18 23:59' },
  { id: 3, title: '考试甲', courseId: 2, category: 'exam', status: 'active', ddl: '2026-10-18 09:00', endAt: '2026-10-18 11:00' },
  { id: 4, title: '自学丙', courseId: 0, category: 'self', status: 'active', ddl: '2026-10-19 12:00' },
  { id: 5, title: '无截止', courseId: 0, category: 'none', status: 'active', ddl: '' },
  { id: 6, title: '已完成', courseId: 1, category: 'homework', status: 'done', ddl: '2026-10-18 23:59' },
  { id: 7, title: '已归档', courseId: 1, category: 'homework', status: 'archived', ddl: '2026-10-18 23:59' },
  { id: 8, title: '凌晨截止', courseId: 1, category: 'homework', status: 'active', ddl: '2026-10-18 02:00' },
  { id: 9, title: '只有日期', courseId: 1, category: 'homework', status: 'active', ddl: '2026-10-18' },
  { id: 10, title: '另一条', courseId: 1, category: 'homework', status: 'active', ddl: '2026-10-18 23:59' }
];
for (const date of ['2026-10-18', '2026-10-19', '2026-10-20']) {
  // 期望值收紧成 {minute, todoIds}：比整份 todo 对象稳定，也不会把字段顺序带进对比
  const compact = (gs) => gs.map((g) => ({ minute: g.minute, todoIds: g.todos.map((t) => t.id) }));
  add('ddlGroupsOn', [todos, date, 7 * 60, 24 * 60], compact(PM.ddlGroupsOn(todos, date, 7 * 60, 24 * 60)));
  // 时间窗被改窄：凌晨的夹到轴起点，23:59 的夹到轴终点
  add('ddlGroupsOn', [todos, date, 9 * 60, 22 * 60], compact(PM.ddlGroupsOn(todos, date, 9 * 60, 22 * 60)));
}

const blocks = [
  { id: 1, todoId: 1, date: '2026-10-18', startMin: 480, endMin: 540, done: 0 },
  { id: 2, todoId: 4, date: '2026-10-19', startMin: 600, endMin: 660, done: 0 }
];
add('scheduledDays', [blocks, 1], PM.scheduledDays(blocks, 1));
add('hasBlockOnDate', [blocks, 1, '2026-10-18'], PM.hasBlockOnDate(blocks, 1, '2026-10-18'));
add('hasBlockOnDate', [blocks, 1, '2026-10-19'], PM.hasBlockOnDate(blocks, 1, '2026-10-19'));

// ---- 待安排托盘 ----
const poolTodos = [
  { id: 3, title: '有截止晚报', courseId: 0, category: 'self', status: 'active', ddl: '2026-10-20 12:00' },
  { id: 1, title: '有截止早报', courseId: 0, category: 'self', status: 'active', ddl: '2026-10-18 09:00' },
  { id: 2, title: '无截止乙', courseId: 0, category: 'self', status: 'active', ddl: '' },
  { id: 4, title: '无截止甲', courseId: 0, category: 'self', status: 'active', ddl: '' },
  { id: 5, title: '待确认', courseId: 0, category: 'self', status: 'pending', ddl: '2026-10-17 09:00' },
  { id: 6, title: '已完成', courseId: 0, category: 'self', status: 'done', ddl: '2026-10-17 09:00' }
];
add('sortPoolTodos', [poolTodos], PM.sortPoolTodos(poolTodos).map((t) => t.id));
add('sortPoolTodos', [todos], PM.sortPoolTodos(todos).map((t) => t.id));
add('selectPoolTodos', [poolTodos, blocks], PM.selectPoolTodos(poolTodos, blocks).map((t) => t.id));
add('selectPoolTodos', [todos, blocks], PM.selectPoolTodos(todos, blocks).map((t) => t.id));

// ================= SyncCadence =================
const SC = require(path.join(DIST, 'SyncCadence.js'));
for (const raw of [0, -5, 1, 5, 10, 180, 181, 10.4, 7.6, 1000, 2.5]) {
  add('normalizeSyncInterval', [raw], SC.normalizeSyncInterval(raw), 'sync_cadence');
}
for (const a of [0, -1, 1, 5, 10, 14, 15, 30, 59, 60, 120, 300]) {
  for (const n of [5, 10, 15]) add('isSyncBoundary', [a, n], SC.isSyncBoundary(a, n), 'sync_cadence');
}
for (const ms of [0, 1000, 299999, 300000, 300001, 600000, 3600000, -5]) {
  for (const n of [5, 10]) add('shouldRestartAfterIdle', [ms, n], SC.shouldRestartAfterIdle(ms, n), 'sync_cadence');
}

// ================= Validate =================
const VD = require(path.join(DIST, 'Validate.js'));
for (const v of [-5, 0, 3, 5, 7, 10, 15, 20, 45, 600]) {
  for (const st of [5, 15, 0, -5]) add('isStepMultiple', [v, st], VD.isStepMultiple(v, st), 'validate');
}
for (const raw of [-1, 0, 1, 7, 14, 15, 18, 20, 23, 57, 60, 61, 599, 600, 601, 750, 5000]) {
  for (const ex of [false, true]) {
    add('normalizeEstimate', [raw, ex], VD.normalizeEstimate(raw, ex), 'validate');
    add('migrateEstimate', [raw, ex], VD.migrateEstimate(raw, ex), 'validate');
    add('validateEstimate', [raw, ex], VD.validateEstimate(raw, ex), 'validate');
  }
}
for (const c of ['homework', 'self', 'exam', 'none', 'other', '']) add('isExamCategory', [c], VD.isExamCategory(c), 'validate');
for (const t of [[480, 540, 1440], [480, 470, 1440], [480, 480, 1440], [480, 1430, 1440], [480, 1500, 1440], [1425, 1440, 1440]]) {
  add('resizeEndTo', [t[0], t[1], t[2]], VD.resizeEndTo(t[0], t[1], t[2]), 'validate');
}
for (const t of [[480, 540, 2, 1440], [480, 540, 0.5, 1440], [480, 540, 1, 1440], [480, 1440, 2, 1440], [480, 540, 0, 1440], [480, 540, -1, 1440]]) {
  add('pinchEnd', [t[0], t[1], t[2], t[3]], VD.pinchEnd(t[0], t[1], t[2], t[3]), 'validate');
}
for (const d of [-30, -5, 0, 5, 30]) add('pinchDeltaLabel', [d], VD.pinchDeltaLabel(d), 'validate');
{
  // ⚠️ 必须带 startMin/endMin：漏了会算出 NaN，JSON 里变成 null，等于没测
  const b2 = [
    { id: 1, todoId: 1, date: '2026-10-18', startMin: 480, endMin: 540, done: 0 },
    { id: 2, todoId: 1, date: '2026-10-19', startMin: 600, endMin: 630, done: 1 },
    { id: 3, todoId: 2, date: '2026-10-18', startMin: 900, endMin: 1000, done: 0 }
  ];
  add('totalBlockMinutes', [b2, 1], VD.totalBlockMinutes(b2, 1), 'validate');
  add('totalBlockMinutes', [b2, 2], VD.totalBlockMinutes(b2, 2), 'validate');
  add('totalBlockMinutes', [b2, 9], VD.totalBlockMinutes(b2, 9), 'validate');
}

const SOURCE = {
  plan_math: 'entry/src/main/ets/domain/PlanMath.ets',
  sync_cadence: 'entry/src/main/ets/domain/SyncCadence.ets',
  validate: 'entry/src/main/ets/domain/Validate.ets'
};
fs.mkdirSync(OUT, { recursive: true });
for (const mod of Object.keys(SOURCE)) {
  const group = cases.filter((c) => c.module === mod).map((c) => ({ fn: c.fn, args: c.args, expect: c.expect }));
  if (group.length === 0) continue;
  const fixture = {
    module: mod,
    note: '由 tools/fixtures/gen.js 从鸿蒙端实现生成（等价性基准，不是正确性证明）；iOS/Android 必须逐条一致。',
    generatedFrom: SOURCE[mod],
    cases: group
  };
  const file = path.join(OUT, mod + '.json');
  fs.writeFileSync(file, JSON.stringify(fixture, null, 1) + '\n', 'utf8');
  console.log('  ' + mod + '.json：' + group.length + ' 条');
}
const stale = path.join(OUT, 'plan_math_old.json');
if (fs.existsSync(stale)) fs.unlinkSync(stale);
console.log('合计 ' + cases.length + ' 条');
