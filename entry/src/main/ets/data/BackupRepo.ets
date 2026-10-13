import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from './Db';
import { Course, PlanBlock, RestWindow, Semester, SessionOverride, SessionRule, Todo,
  TodoTemplate, VirtualLesson } from '../model/Types';
import { BackupBundle, SectionTimeRow, emptyBundle, serializeBackup } from '../domain/Backup';
import { formatDate, today } from '../util/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

const BACKUP_FILE: string = 'classout-backup.json';

/**
 * 全量备份 / 恢复 / 诊断。
 *
 * 为什么值得做：这是唯一纯离线的 App，数据只在自己手机里，
 * 一出问题（尤其是装机初期）没有备份就只能重录。
 * 备份文件写在应用沙箱的 filesDir 下，可以用 hdc 拉到电脑：
 *   hdc file recv /data/app/el2/100/base/com.chemica.classout/haps/entry/files/classout-backup.json ./
 */
export class BackupRepo {

  static backupFilePath(context: common.Context): string {
    return `${context.filesDir}/${BACKUP_FILE}`;
  }

  // ---------- 导出 ----------

  static async exportAll(context: common.Context): Promise<BackupBundle> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bundle: BackupBundle = emptyBundle(formatDate(today()));

    // 学期
    let rs = await store.querySql('SELECT * FROM semester ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.semesters.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        startDate: rs.getString(rs.getColumnIndex('start_date')),
        totalWeeks: rs.getLong(rs.getColumnIndex('total_weeks')),
        firstDayOfWeek: rs.getLong(rs.getColumnIndex('first_day_of_week')),
        showWeekend: rs.getLong(rs.getColumnIndex('show_weekend')) === 1
      });
    }
    rs.close();

    // 节次时间
    rs = await store.querySql('SELECT * FROM section_time ORDER BY semester_id, section');
    while (rs.goToNextRow()) {
      bundle.sectionTimes.push({
        semesterId: rs.getLong(rs.getColumnIndex('semester_id')),
        section: rs.getLong(rs.getColumnIndex('section')),
        startMin: rs.getLong(rs.getColumnIndex('start_min')),
        endMin: rs.getLong(rs.getColumnIndex('end_min')),
        flexible: rs.getLong(rs.getColumnIndex('flexible')) === 1
      });
    }
    rs.close();

    // 课程
    rs = await store.querySql('SELECT * FROM course ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.courses.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        semesterId: rs.getLong(rs.getColumnIndex('semester_id')),
        name: rs.getString(rs.getColumnIndex('name')),
        shortName: rs.getString(rs.getColumnIndex('short_name')),
        teacher: rs.getString(rs.getColumnIndex('teacher')),
        location: rs.getString(rs.getColumnIndex('location')),
        colorIndex: rs.getLong(rs.getColumnIndex('color_index')),
        autoTodoEnabled: rs.getLong(rs.getColumnIndex('auto_todo_enabled')) === 1,
        isVirtual: rs.getLong(rs.getColumnIndex('is_virtual')) === 1,
        note: rs.getString(rs.getColumnIndex('note'))
      });
    }
    rs.close();

    // 时段规则
    rs = await store.querySql('SELECT * FROM session_rule ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.rules.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        courseId: rs.getLong(rs.getColumnIndex('course_id')),
        weekday: rs.getLong(rs.getColumnIndex('weekday')),
        startSection: rs.getLong(rs.getColumnIndex('start_section')),
        endSection: rs.getLong(rs.getColumnIndex('end_section')),
        weeksMask: rs.getString(rs.getColumnIndex('weeks_mask')),
        location: rs.getString(rs.getColumnIndex('location')),
        isQuiz: rs.getLong(rs.getColumnIndex('is_quiz')) === 1
      });
    }
    rs.close();

    // 单周覆盖
    rs = await store.querySql('SELECT * FROM session_override ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.overrides.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        courseId: rs.getLong(rs.getColumnIndex('course_id')),
        date: rs.getString(rs.getColumnIndex('date')),
        kind: rs.getString(rs.getColumnIndex('kind')),
        newDate: rs.getString(rs.getColumnIndex('new_date')),
        newStartSection: rs.getLong(rs.getColumnIndex('new_start_section')),
        newEndSection: rs.getLong(rs.getColumnIndex('new_end_section')),
        newLocation: rs.getString(rs.getColumnIndex('new_location'))
      });
    }
    rs.close();

    // 生成模板
    rs = await store.querySql('SELECT * FROM todo_template ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.templates.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        courseId: rs.getLong(rs.getColumnIndex('course_id')),
        sortOrder: rs.getLong(rs.getColumnIndex('sort_order')),
        enabled: rs.getLong(rs.getColumnIndex('enabled')) === 1,
        titleTemplate: rs.getString(rs.getColumnIndex('title_template')),
        ddlRule: rs.getString(rs.getColumnIndex('ddl_rule')),
        ddlParam: rs.getString(rs.getColumnIndex('ddl_param')),
        estimateMin: rs.getLong(rs.getColumnIndex('estimate_min')),
        category: rs.getString(rs.getColumnIndex('category')),
        submitChannel: rs.getString(rs.getColumnIndex('submit_channel')),
        note: rs.getString(rs.getColumnIndex('note'))
      });
    }
    rs.close();

    // 待办
    rs = await store.querySql('SELECT * FROM todo ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.todos.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        title: rs.getString(rs.getColumnIndex('title')),
        courseId: rs.getLong(rs.getColumnIndex('course_id')),
        category: rs.getString(rs.getColumnIndex('category')),
        priority: rs.getLong(rs.getColumnIndex('priority')),
        ddl: rs.getString(rs.getColumnIndex('ddl')),
        estimateMin: rs.getLong(rs.getColumnIndex('estimate_min')),
        status: rs.getString(rs.getColumnIndex('status')),
        source: rs.getString(rs.getColumnIndex('source')),
        generationKey: rs.getString(rs.getColumnIndex('generation_key')),
        note: rs.getString(rs.getColumnIndex('note')),
        submitChannel: rs.getString(rs.getColumnIndex('submit_channel')),
        repeatRule: rs.getString(rs.getColumnIndex('repeat_rule')),
        photos: rs.getString(rs.getColumnIndex('photos')),
        createdAt: rs.getLong(rs.getColumnIndex('created_at')),
        confirmedAt: rs.getLong(rs.getColumnIndex('confirmed_at')),
        doneAt: rs.getLong(rs.getColumnIndex('done_at'))
      });
    }
    rs.close();

    // 虚拟课时
    rs = await store.querySql('SELECT * FROM virtual_lesson ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.lessons.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        courseId: rs.getLong(rs.getColumnIndex('course_id')),
        seq: rs.getLong(rs.getColumnIndex('seq')),
        title: rs.getString(rs.getColumnIndex('title')),
        done: rs.getLong(rs.getColumnIndex('done')) === 1,
        doneAt: rs.getLong(rs.getColumnIndex('done_at'))
      });
    }
    rs.close();

    // 计划块
    rs = await store.querySql('SELECT * FROM plan_block ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.blocks.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        todoId: rs.getLong(rs.getColumnIndex('todo_id')),
        lessonId: rs.getLong(rs.getColumnIndex('lesson_id')),
        date: rs.getString(rs.getColumnIndex('date')),
        startMin: rs.getLong(rs.getColumnIndex('start_min')),
        endMin: rs.getLong(rs.getColumnIndex('end_min')),
        done: rs.getLong(rs.getColumnIndex('done')) === 1
      });
    }
    rs.close();

    // 休息时段
    rs = await store.querySql('SELECT * FROM rest_window ORDER BY id');
    while (rs.goToNextRow()) {
      bundle.restWindows.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        weekday: rs.getLong(rs.getColumnIndex('weekday')),
        startMin: rs.getLong(rs.getColumnIndex('start_min')),
        endMin: rs.getLong(rs.getColumnIndex('end_min')),
        label: rs.getString(rs.getColumnIndex('label'))
      });
    }
    rs.close();

    return bundle;
  }

  /** 导出并写入沙箱文件，返回写入的字节数 */
  static async exportToFile(context: common.Context): Promise<number> {
    const bundle: BackupBundle = await BackupRepo.exportAll(context);
    const text: string = serializeBackup(bundle);
    const path: string = BackupRepo.backupFilePath(context);
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const written: number = fileIo.writeSync(file.fd, text);
    fileIo.closeSync(file);
    hilog.info(DOMAIN, TAG, 'backup written: %{public}d bytes', written);
    return written;
  }

  static async readBackupText(context: common.Context): Promise<string> {
    const path: string = BackupRepo.backupFilePath(context);
    if (!fileIo.accessSync(path)) {
      return '';
    }
    return fileIo.readTextSync(path);
  }

  // ---------- 导入 ----------

  /** 用备份覆盖当前数据（先清空）。黑名单不在备份里，恢复后已删的自动待办可能再生成一次。 */
  static async importAll(context: common.Context, b: BackupBundle): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM plan_block');
    await store.executeSql('DELETE FROM virtual_lesson');
    await store.executeSql('DELETE FROM todo');
    await store.executeSql('DELETE FROM todo_blacklist');
    await store.executeSql('DELETE FROM todo_template');
    await store.executeSql('DELETE FROM session_override');
    await store.executeSql('DELETE FROM session_rule');
    await store.executeSql('DELETE FROM course');
    await store.executeSql('DELETE FROM section_time');
    await store.executeSql('DELETE FROM rest_window');
    await store.executeSql('DELETE FROM semester');

    for (const s of b.semesters) {
      await store.executeSql(
        `INSERT INTO semester (id, name, start_date, total_weeks, first_day_of_week, show_weekend)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [s.id, s.name, s.startDate, s.totalWeeks, s.firstDayOfWeek, s.showWeekend ? 1 : 0]);
    }
    for (const t of b.sectionTimes as SectionTimeRow[]) {
      await store.executeSql(
        `INSERT INTO section_time (semester_id, section, start_min, end_min, flexible)
         VALUES (?, ?, ?, ?, ?)`,
        [t.semesterId, t.section, t.startMin, t.endMin, t.flexible ? 1 : 0]);
    }
    for (const c of b.courses as Course[]) {
      await store.executeSql(
        `INSERT INTO course (id, semester_id, name, short_name, teacher, location, color_index,
         auto_todo_enabled, is_virtual, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [c.id, c.semesterId, c.name, c.shortName, c.teacher, c.location, c.colorIndex,
          c.autoTodoEnabled ? 1 : 0, c.isVirtual ? 1 : 0, c.note]);
    }
    for (const r of b.rules as SessionRule[]) {
      await store.executeSql(
        `INSERT INTO session_rule (id, course_id, weekday, start_section, end_section, weeks_mask,
         location, is_quiz) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [r.id, r.courseId, r.weekday, r.startSection, r.endSection, r.weeksMask, r.location,
          r.isQuiz ? 1 : 0]);
    }
    for (const o of b.overrides as SessionOverride[]) {
      await store.executeSql(
        `INSERT INTO session_override (id, course_id, date, kind, new_date, new_start_section,
         new_end_section, new_location) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [o.id, o.courseId, o.date, o.kind, o.newDate, o.newStartSection, o.newEndSection,
          o.newLocation]);
    }
    for (const t of b.templates as TodoTemplate[]) {
      await store.executeSql(
        `INSERT INTO todo_template (id, course_id, sort_order, enabled, title_template, ddl_rule,
         ddl_param, estimate_min, category, submit_channel, note)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [t.id, t.courseId, t.sortOrder, t.enabled ? 1 : 0, t.titleTemplate, t.ddlRule, t.ddlParam,
          t.estimateMin, t.category, t.submitChannel, t.note]);
    }
    for (const t of b.todos as Todo[]) {
      await store.executeSql(
        `INSERT INTO todo (id, title, course_id, category, priority, ddl, estimate_min, status,
         source, generation_key, note, submit_channel, repeat_rule, photos, created_at,
         confirmed_at, done_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [t.id, t.title, t.courseId, t.category, t.priority, t.ddl, t.estimateMin, t.status,
          t.source, t.generationKey, t.note, t.submitChannel, t.repeatRule, t.photos,
          t.createdAt, t.confirmedAt, t.doneAt]);
    }
    for (const l of b.lessons as VirtualLesson[]) {
      await store.executeSql(
        `INSERT INTO virtual_lesson (id, course_id, seq, title, done, done_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [l.id, l.courseId, l.seq, l.title, l.done ? 1 : 0, l.doneAt]);
    }
    for (const p of b.blocks as PlanBlock[]) {
      await store.executeSql(
        `INSERT INTO plan_block (id, todo_id, lesson_id, date, start_min, end_min, done)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [p.id, p.todoId, p.lessonId, p.date, p.startMin, p.endMin, p.done ? 1 : 0]);
    }
    for (const w of b.restWindows as RestWindow[]) {
      await store.executeSql(
        `INSERT INTO rest_window (id, weekday, start_min, end_min, label) VALUES (?, ?, ?, ?, ?)`,
        [w.id, w.weekday, w.startMin, w.endMin, w.label]);
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'backup imported');
  }

  // ---------- 诊断 ----------

  /** 各表条数，出问题时截图给开发者就能定位 */
  static async diagnostics(context: common.Context): Promise<string> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const tables: string[] = ['semester', 'section_time', 'course', 'session_rule',
      'session_override', 'todo_template', 'todo', 'todo_blacklist', 'virtual_lesson',
      'plan_block', 'rest_window'];
    const lines: string[] = [];
    for (const t of tables) {
      const rs = await store.querySql(`SELECT COUNT(*) AS n FROM ${t}`);
      let n: number = 0;
      if (rs.goToFirstRow()) {
        n = rs.getLong(rs.getColumnIndex('n'));
      }
      rs.close();
      lines.push(`${t}: ${n}`);
    }
    const report: string = await Db.getKv(context, 'last_run_report');
    if (report.length > 0) {
      lines.push('');
      lines.push('--- 上次启动报告 ---');
      lines.push(report);
    }
    return lines.join('\n');
  }
}
