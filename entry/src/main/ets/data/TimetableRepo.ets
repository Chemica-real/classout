import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Db } from './Db';
import { Course, OverrideKind, RestWindow, SectionTime, Semester, SessionOverride,
  SessionRule } from '../model/Types';

/** 课表相关表的读写 */
export class TimetableRepo {

  // ---------- 学期 ----------

  /** 当前生效的学期 id（存在 kv 里；没设过就用最早创建的那个） */
  static async getActiveSemesterId(context: common.Context): Promise<number> {
    const raw: string = await Db.getKv(context, 'active_semester');
    if (raw.length === 0) {
      return 0;
    }
    const id: number = parseInt(raw, 10);
    return isNaN(id) ? 0 : id;
  }

  static async setActiveSemesterId(context: common.Context, id: number): Promise<void> {
    await Db.setKv(context, 'active_semester', `${id}`);
  }

  static async listSemesters(context: common.Context): Promise<Semester[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT * FROM semester ORDER BY id');
    const list: Semester[] = [];
    while (rs.goToNextRow()) {
      list.push(TimetableRepo.readSemester(rs));
    }
    rs.close();
    return list;
  }

  private static readSemester(rs: relationalStore.ResultSet): Semester {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      name: rs.getString(rs.getColumnIndex('name')),
      startDate: rs.getString(rs.getColumnIndex('start_date')),
      totalWeeks: rs.getLong(rs.getColumnIndex('total_weeks')),
      firstDayOfWeek: rs.getLong(rs.getColumnIndex('first_day_of_week')),
      showWeekend: rs.getLong(rs.getColumnIndex('show_weekend')) === 1
    };
  }

  /** 当前学期（优先 kv 里指定的那个） */
  static async getSemester(context: common.Context): Promise<Semester | undefined> {
    const list: Semester[] = await TimetableRepo.listSemesters(context);
    if (list.length === 0) {
      return undefined;
    }
    const activeId: number = await TimetableRepo.getActiveSemesterId(context);
    if (activeId > 0) {
      for (const s of list) {
        if (s.id === activeId) {
          return s;
        }
      }
    }
    return list[0];
  }

  static async createSemester(context: common.Context, name: string, startDate: string,
    totalWeeks: number): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'name': name,
      'start_date': startDate,
      'total_weeks': totalWeeks,
      'first_day_of_week': 1,
      'show_weekend': 1
    };
    return await store.insert('semester', bucket);
  }

  static async updateSemester(context: common.Context, s: Semester): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      'UPDATE semester SET name = ?, start_date = ?, total_weeks = ?, first_day_of_week = ?, show_weekend = ? WHERE id = ?',
      [s.name, s.startDate, s.totalWeeks, s.firstDayOfWeek, s.showWeekend ? 1 : 0, s.id]);
  }

  // ---------- 节次时间 ----------

  static async listSectionTimes(context: common.Context, semesterId: number): Promise<SectionTime[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM section_time WHERE semester_id = ? ORDER BY section', [semesterId]);
    const list: SectionTime[] = [];
    while (rs.goToNextRow()) {
      list.push({
        section: rs.getLong(rs.getColumnIndex('section')),
        startMin: rs.getLong(rs.getColumnIndex('start_min')),
        endMin: rs.getLong(rs.getColumnIndex('end_min')),
        flexible: rs.getLong(rs.getColumnIndex('flexible')) === 1
      });
    }
    rs.close();
    return list;
  }

  static async upsertSectionTime(context: common.Context, semesterId: number,
    st: SectionTime): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      'INSERT OR REPLACE INTO section_time (semester_id, section, start_min, end_min, flexible) VALUES (?, ?, ?, ?, ?)',
      [semesterId, st.section, st.startMin, st.endMin, st.flexible ? 1 : 0]);
  }

  static async deleteSectionTime(context: common.Context, semesterId: number,
    section: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM section_time WHERE semester_id = ? AND section = ?',
      [semesterId, section]);
  }

  // ---------- 休息时段（不可排） ----------

  static async listRestWindows(context: common.Context): Promise<RestWindow[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT * FROM rest_window ORDER BY weekday, start_min');
    const list: RestWindow[] = [];
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        weekday: rs.getLong(rs.getColumnIndex('weekday')),
        startMin: rs.getLong(rs.getColumnIndex('start_min')),
        endMin: rs.getLong(rs.getColumnIndex('end_min')),
        label: rs.getString(rs.getColumnIndex('label'))
      });
    }
    rs.close();
    return list;
  }

  static async countRestWindows(context: common.Context): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT COUNT(*) AS n FROM rest_window');
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('n'));
    }
    rs.close();
    return n;
  }

  static async insertRestWindow(context: common.Context, w: RestWindow): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'weekday': w.weekday,
      'start_min': w.startMin,
      'end_min': w.endMin,
      'label': w.label
    };
    return await store.insert('rest_window', bucket);
  }

  static async deleteRestWindow(context: common.Context, id: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM rest_window WHERE id = ?', [id]);
  }

  // ---------- 课程 ----------

  static async listCourses(context: common.Context, semesterId: number): Promise<Course[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM course WHERE semester_id = ? ORDER BY id', [semesterId]);
    const list: Course[] = [];
    while (rs.goToNextRow()) {
      list.push(TimetableRepo.readCourse(rs));
    }
    rs.close();
    return list;
  }

  private static readCourse(rs: relationalStore.ResultSet): Course {
    return {
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
    };
  }

  static async insertCourse(context: common.Context, c: Course): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'semester_id': c.semesterId,
      'name': c.name,
      'short_name': c.shortName,
      'teacher': c.teacher,
      'location': c.location,
      'color_index': c.colorIndex,
      'auto_todo_enabled': c.autoTodoEnabled ? 1 : 0,
      'is_virtual': c.isVirtual ? 1 : 0,
      'note': c.note
    };
    return await store.insert('course', bucket);
  }

  static async updateCourse(context: common.Context, c: Course): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      `UPDATE course SET name = ?, short_name = ?, teacher = ?, location = ?, color_index = ?,
       auto_todo_enabled = ?, is_virtual = ?, note = ? WHERE id = ?`,
      [c.name, c.shortName, c.teacher, c.location, c.colorIndex,
        c.autoTodoEnabled ? 1 : 0, c.isVirtual ? 1 : 0, c.note, c.id]);
  }

  static async deleteCourse(context: common.Context, courseId: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM session_rule WHERE course_id = ?', [courseId]);
    await store.executeSql('DELETE FROM todo_template WHERE course_id = ?', [courseId]);
    await store.executeSql('DELETE FROM session_override WHERE course_id = ?', [courseId]);
    await store.executeSql('DELETE FROM course WHERE id = ?', [courseId]);
  }

  // ---------- 上课规则 ----------

  static async listRules(context: common.Context, semesterId: number): Promise<SessionRule[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      `SELECT r.* FROM session_rule r JOIN course c ON c.id = r.course_id
       WHERE c.semester_id = ? ORDER BY r.weekday, r.start_section`, [semesterId]);
    const list: SessionRule[] = [];
    while (rs.goToNextRow()) {
      list.push(TimetableRepo.readRule(rs));
    }
    rs.close();
    return list;
  }

  /** 某门课的全部时段（复制课表用） */
  static async listRulesOfCourse(context: common.Context, courseId: number): Promise<SessionRule[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM session_rule WHERE course_id = ? ORDER BY weekday, start_section', [courseId]);
    const list: SessionRule[] = [];
    while (rs.goToNextRow()) {
      list.push(TimetableRepo.readRule(rs));
    }
    rs.close();
    return list;
  }

  private static readRule(rs: relationalStore.ResultSet): SessionRule {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      courseId: rs.getLong(rs.getColumnIndex('course_id')),
      weekday: rs.getLong(rs.getColumnIndex('weekday')),
      startSection: rs.getLong(rs.getColumnIndex('start_section')),
      endSection: rs.getLong(rs.getColumnIndex('end_section')),
      weeksMask: rs.getString(rs.getColumnIndex('weeks_mask')),
      location: rs.getString(rs.getColumnIndex('location')),
      isQuiz: rs.getLong(rs.getColumnIndex('is_quiz')) === 1
    };
  }

  static async insertRule(context: common.Context, r: SessionRule): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'course_id': r.courseId,
      'weekday': r.weekday,
      'start_section': r.startSection,
      'end_section': r.endSection,
      'weeks_mask': r.weeksMask,
      'location': r.location,
      'is_quiz': r.isQuiz ? 1 : 0
    };
    return await store.insert('session_rule', bucket);
  }

  static async updateRule(context: common.Context, r: SessionRule): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      `UPDATE session_rule SET weekday = ?, start_section = ?, end_section = ?, weeks_mask = ?,
       location = ?, is_quiz = ? WHERE id = ?`,
      [r.weekday, r.startSection, r.endSection, r.weeksMask, r.location, r.isQuiz ? 1 : 0, r.id]);
  }

  static async deleteRule(context: common.Context, ruleId: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM session_rule WHERE id = ?', [ruleId]);
  }

  // ---------- 单周覆盖 ----------

  static async listOverridesBetween(context: common.Context, fromDate: string,
    toDate: string): Promise<SessionOverride[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      `SELECT * FROM session_override
       WHERE (date >= ? AND date <= ?) OR (kind = ? AND new_date >= ? AND new_date <= ?)`,
      [fromDate, toDate, OverrideKind.Extra, fromDate, toDate]);
    const list: SessionOverride[] = [];
    while (rs.goToNextRow()) {
      list.push({
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
    return list;
  }

  static async insertOverride(context: common.Context, o: SessionOverride): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'course_id': o.courseId,
      'date': o.date,
      'kind': o.kind,
      'new_date': o.newDate,
      'new_start_section': o.newStartSection,
      'new_end_section': o.newEndSection,
      'new_location': o.newLocation
    };
    return await store.insert('session_override', bucket);
  }

  static async deleteOverride(context: common.Context, id: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM session_override WHERE id = ?', [id]);
  }
}
