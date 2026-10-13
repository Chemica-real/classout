import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Db } from './Db';
import { PlanBlock, Todo, TodoTemplate, VirtualLesson } from '../model/Types';

/** 待办 / 模板 / 计划块的读写 */
export class TodoRepo {

  // ---------- 生成模板 ----------

  static async insertTemplate(context: common.Context, t: TodoTemplate): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'course_id': t.courseId,
      'sort_order': t.sortOrder,
      'enabled': t.enabled ? 1 : 0,
      'title_template': t.titleTemplate,
      'ddl_rule': t.ddlRule,
      'ddl_param': t.ddlParam,
      'estimate_min': t.estimateMin,
      'category': t.category,
      'submit_channel': t.submitChannel,
      'note': t.note
    };
    return await store.insert('todo_template', bucket);
  }

  static async listTemplatesByCourse(context: common.Context,
    courseId: number): Promise<TodoTemplate[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM todo_template WHERE course_id = ? ORDER BY sort_order, id', [courseId]);
    const list: TodoTemplate[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readTemplate(rs));
    }
    rs.close();
    return list;
  }

  static async listTemplates(context: common.Context,
    semesterId: number): Promise<TodoTemplate[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      `SELECT t.* FROM todo_template t JOIN course c ON c.id = t.course_id
       WHERE c.semester_id = ? ORDER BY t.course_id, t.sort_order, t.id`, [semesterId]);
    const list: TodoTemplate[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readTemplate(rs));
    }
    rs.close();
    return list;
  }

  private static readTemplate(rs: relationalStore.ResultSet): TodoTemplate {
    return {
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
    };
  }

  static async updateTemplate(context: common.Context, t: TodoTemplate): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      `UPDATE todo_template SET sort_order = ?, enabled = ?, title_template = ?, ddl_rule = ?,
       ddl_param = ?, estimate_min = ?, category = ?, submit_channel = ?, note = ? WHERE id = ?`,
      [t.sortOrder, t.enabled ? 1 : 0, t.titleTemplate, t.ddlRule, t.ddlParam, t.estimateMin,
        t.category, t.submitChannel, t.note, t.id]);
  }

  static async deleteTemplate(context: common.Context, id: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM todo_template WHERE id = ?', [id]);
  }

  // ---------- 待办 ----------

  static async insertTodo(context: common.Context, t: Todo): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'title': t.title,
      'course_id': t.courseId,
      'category': t.category,
      'priority': t.priority,
      'ddl': t.ddl,
      'estimate_min': t.estimateMin,
      'status': t.status,
      'source': t.source,
      'generation_key': t.generationKey,
      'note': t.note,
      'submit_channel': t.submitChannel,
      'repeat_rule': t.repeatRule,
      'photos': t.photos,
      'created_at': t.createdAt,
      'confirmed_at': t.confirmedAt,
      'done_at': t.doneAt
    };
    return await store.insert('todo', bucket);
  }

  static async listTodos(context: common.Context, statusClause: string,
    args: relationalStore.ValueType[]): Promise<Todo[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      `SELECT * FROM todo WHERE ${statusClause} ORDER BY
       CASE WHEN ddl = '' THEN 1 ELSE 0 END, ddl, priority DESC, id DESC`, args);
    const list: Todo[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readTodo(rs));
    }
    rs.close();
    return list;
  }

  static async getTodo(context: common.Context, id: number): Promise<Todo | undefined> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT * FROM todo WHERE id = ?', [id]);
    let result: Todo | undefined = undefined;
    if (rs.goToFirstRow()) {
      result = TodoRepo.readTodo(rs);
    }
    rs.close();
    return result;
  }

  private static readTodo(rs: relationalStore.ResultSet): Todo {
    return {
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
    };
  }

  static async updateTodo(context: common.Context, t: Todo): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      `UPDATE todo SET title = ?, course_id = ?, category = ?, priority = ?, ddl = ?,
       estimate_min = ?, status = ?, note = ?, submit_channel = ?, repeat_rule = ?,
       photos = ?, confirmed_at = ?, done_at = ? WHERE id = ?`,
      [t.title, t.courseId, t.category, t.priority, t.ddl, t.estimateMin, t.status, t.note,
        t.submitChannel, t.repeatRule, t.photos, t.confirmedAt, t.doneAt, t.id]);
  }

  static async setTodoStatus(context: common.Context, id: number, status: string,
    doneAt: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('UPDATE todo SET status = ?, done_at = ? WHERE id = ?',
      [status, doneAt, id]);
  }

  /** 某门课已经生成过多少条模板待办（%N 自增用） */
  static async countTemplateTodos(context: common.Context, courseId: number): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT COUNT(*) AS n FROM todo WHERE course_id = ? AND source = ?',
      [courseId, 'template']);
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('n'));
    }
    rs.close();
    return n;
  }

  /** 已存在同 generationKey 的待办？去重用 */
  static async hasGenerationKey(context: common.Context, key: string): Promise<boolean> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT 1 FROM todo WHERE generation_key = ? LIMIT 1', [key]);
    const hit: boolean = rs.goToFirstRow();
    rs.close();
    return hit;
  }

  /** 用户删掉的自动待办：记住不再生成（含在待办表里的，也含黑名单） */
  static async blacklist(context: common.Context, key: string, ts: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      'INSERT OR REPLACE INTO todo_blacklist (generation_key, deleted_at) VALUES (?, ?)',
      [key, ts]);
  }

  static async isBlacklisted(context: common.Context, key: string): Promise<boolean> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT 1 FROM todo_blacklist WHERE generation_key = ? LIMIT 1',
      [key]);
    const hit: boolean = rs.goToFirstRow();
    rs.close();
    return hit;
  }

  static async deleteTodo(context: common.Context, id: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM plan_block WHERE todo_id = ?', [id]);
    await store.executeSql('DELETE FROM todo WHERE id = ?', [id]);
  }

  // ---------- 虚拟课程的课时 ----------

  static async insertLesson(context: common.Context, courseId: number, seq: number,
    title: string): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'course_id': courseId,
      'seq': seq,
      'title': title,
      'done': 0,
      'done_at': 0
    };
    return await store.insert('virtual_lesson', bucket);
  }

  static async listLessonsByCourse(context: common.Context,
    courseId: number): Promise<VirtualLesson[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM virtual_lesson WHERE course_id = ? ORDER BY seq', [courseId]);
    const list: VirtualLesson[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readLesson(rs));
    }
    rs.close();
    return list;
  }

  /** 所有虚拟课程的课时（计划视图的待安排池要用） */
  static async listLessonsOfVirtualCourses(context: common.Context,
    semesterId: number): Promise<VirtualLesson[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      `SELECT l.* FROM virtual_lesson l JOIN course c ON c.id = l.course_id
       WHERE c.semester_id = ? AND c.is_virtual = 1 ORDER BY l.course_id, l.seq`, [semesterId]);
    const list: VirtualLesson[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readLesson(rs));
    }
    rs.close();
    return list;
  }

  private static readLesson(rs: relationalStore.ResultSet): VirtualLesson {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      courseId: rs.getLong(rs.getColumnIndex('course_id')),
      seq: rs.getLong(rs.getColumnIndex('seq')),
      title: rs.getString(rs.getColumnIndex('title')),
      done: rs.getLong(rs.getColumnIndex('done')) === 1,
      doneAt: rs.getLong(rs.getColumnIndex('done_at'))
    };
  }

  static async setLessonDone(context: common.Context, id: number, done: boolean,
    ts: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('UPDATE virtual_lesson SET done = ?, done_at = ? WHERE id = ?',
      [done ? 1 : 0, ts, id]);
  }

  static async getLesson(context: common.Context, id: number): Promise<VirtualLesson | undefined> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT * FROM virtual_lesson WHERE id = ?', [id]);
    let result: VirtualLesson | undefined = undefined;
    if (rs.goToFirstRow()) {
      result = TodoRepo.readLesson(rs);
    }
    rs.close();
    return result;
  }

  static async deleteLessonsByCourse(context: common.Context, courseId: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM virtual_lesson WHERE course_id = ?', [courseId]);
  }

  /**
   * 把某门虚拟课程的课时数量调整到 count：
   * 少了就补，多了就删掉「没做过」的那些（做过的留着，不然历史就丢了）。
   */
  static async syncLessonCount(context: common.Context, courseId: number,
    count: number): Promise<void> {
    const existing: VirtualLesson[] = await TodoRepo.listLessonsByCourse(context, courseId);
    if (existing.length < count) {
      for (let seq = existing.length + 1; seq <= count; seq++) {
        await TodoRepo.insertLesson(context, courseId, seq, '');
      }
      return;
    }
    if (existing.length > count) {
      const store: relationalStore.RdbStore = await Db.get(context);
      for (const l of existing) {
        if (l.seq > count && !l.done) {
          await store.executeSql('DELETE FROM virtual_lesson WHERE id = ?', [l.id]);
        }
      }
    }
  }

  // ---------- 计划块 ----------

  static async insertBlock(context: common.Context, b: PlanBlock): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const bucket: relationalStore.ValuesBucket = {
      'todo_id': b.todoId,
      'lesson_id': b.lessonId,
      'date': b.date,
      'start_min': b.startMin,
      'end_min': b.endMin,
      'done': b.done ? 1 : 0
    };
    return await store.insert('plan_block', bucket);
  }

  static async listBlocksOn(context: common.Context, date: string): Promise<PlanBlock[]> {    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM plan_block WHERE date = ? ORDER BY start_min', [date]);
    const list: PlanBlock[] = [];
    while (rs.goToNextRow()) {
      list.push({
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
    return list;
  }

  /**
   * 某个待办的所有时间块（跨全部日期）。
   * 「所有块完成 → 待办自动完成」必须用它，只看当天会把跨天拆分的待办误判成完成。
   */
  static async listBlocksByTodo(context: common.Context, todoId: number): Promise<PlanBlock[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM plan_block WHERE todo_id = ? ORDER BY date, start_min', [todoId]);
    const list: PlanBlock[] = [];
    while (rs.goToNextRow()) {
      list.push({
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
    return list;
  }

  static async updateBlock(context: common.Context, b: PlanBlock): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      'UPDATE plan_block SET date = ?, start_min = ?, end_min = ?, done = ? WHERE id = ?',
      [b.date, b.startMin, b.endMin, b.done ? 1 : 0, b.id]);
  }

  static async deleteBlock(context: common.Context, id: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM plan_block WHERE id = ?', [id]);
  }
}
