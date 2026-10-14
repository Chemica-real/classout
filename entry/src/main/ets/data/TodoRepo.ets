import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Db } from './Db';
import { PlanBlock, Todo, TodoCategory, TodoStatus, TodoTemplate, VirtualLesson } from '../model/Types';
import { ExamRange, Validation, examRangeOf, isExamCategory, migrateEstimate, normalizeEstimate, validateExamRange } from '../domain/Validate';

/** 待办时长的迁移项（见 normalizeAllEstimates） */
interface EstimateFix {
  id: number;
  estimateMin: number;
}

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
      'estimate_min': normalizeEstimate(t.estimateMin, false),
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
      [t.sortOrder, t.enabled ? 1 : 0, t.titleTemplate, t.ddlRule, t.ddlParam,
        normalizeEstimate(t.estimateMin, false),
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
      'end_at': t.endAt,
      'estimate_min': normalizeEstimate(t.estimateMin, isExamCategory(t.category)),
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

  /**
   * 已完成的待办：**按完成时刻倒序**（最近完成的在最上面）。
   *
   * ⚠️ 单独开一条，不复用 `listTodos`：那条是按 ddl 排的（托盘要用），
   * 放到"已完成"列表里就变成按截止日期排、跟完成先后无关，看着很乱。
   */
  static async listDoneTodos(context: common.Context): Promise<Todo[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      `SELECT * FROM todo WHERE status = '${TodoStatus.Done}' ORDER BY done_at DESC, id DESC`);
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
      endAt: rs.getString(rs.getColumnIndex('end_at')),
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
      `UPDATE todo SET title = ?, course_id = ?, category = ?, priority = ?, ddl = ?, end_at = ?,
       estimate_min = ?, status = ?, note = ?, submit_channel = ?, repeat_rule = ?,
       photos = ?, confirmed_at = ?, done_at = ? WHERE id = ?`,
      [t.title, t.courseId, t.category, t.priority, t.ddl, t.endAt,
        normalizeEstimate(t.estimateMin, isExamCategory(t.category)), t.status, t.note,
        t.submitChannel, t.repeatRule, t.photos, t.confirmedAt, t.doneAt, t.id]);
  }

  /**
   * 一次性迁移：把旧的非法时长静默搬到合法值（对齐到最近的 5 分钟、夹进 [15,600]）。
   *
   * 用户 2026-10-14 拍定「时长必须是 5 的倍数」时，明确选了「旧的不合法值静默搬到最近的 5」。
   * 考试类待办的 estimate_min 恒为 0，是唯一的豁免（见 Validate.normalizeEstimate）。
   *
   * 返回被改动的条数 —— 调用方把它写进启动报告，用户能看见「动过我的数据」这件事，
   * 而不是某天发现 20 分钟变成 25 分钟却不知道谁干的。
   */
  static async normalizeAllEstimates(context: common.Context): Promise<number> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT id, category, estimate_min FROM todo');
    const fixes: EstimateFix[] = [];
    while (rs.goToNextRow()) {
      const id: number = rs.getLong(rs.getColumnIndex('id'));
      const category: string = rs.getString(rs.getColumnIndex('category'));
      const raw: number = rs.getLong(rs.getColumnIndex('estimate_min'));
      const want: number = migrateEstimate(raw, category === TodoCategory.Exam);
      if (want !== raw) {
        fixes.push({ id: id, estimateMin: want });
      }
    }
    rs.close();
    for (const f of fixes) {
      await store.executeSql('UPDATE todo SET estimate_min = ? WHERE id = ?', [f.estimateMin, f.id]);
    }
    return fixes.length;
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

  /** 从结果集读一行块（listBlocksOn / listBlocksByTodo / getBlock 共用） */
  private static readBlock(rs: relationalStore.ResultSet): PlanBlock {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      todoId: rs.getLong(rs.getColumnIndex('todo_id')),
      lessonId: rs.getLong(rs.getColumnIndex('lesson_id')),
      date: rs.getString(rs.getColumnIndex('date')),
      startMin: rs.getLong(rs.getColumnIndex('start_min')),
      endMin: rs.getLong(rs.getColumnIndex('end_min')),
      done: rs.getLong(rs.getColumnIndex('done')) === 1
    };
  }

  static async listBlocksOn(context: common.Context, date: string): Promise<PlanBlock[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql(
      'SELECT * FROM plan_block WHERE date = ? ORDER BY start_min', [date]);
    const list: PlanBlock[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readBlock(rs));
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
      list.push(TodoRepo.readBlock(rs));
    }
    rs.close();
    return list;
  }

  /**
   * 全部计划块（不分日期）。
   *
   * 用途：判断"这个待办/这一讲**已经排过没有**" —— 用户 2026-10-14 定的规则是
   * **排到任何一天都算排过**，托盘里就该消失。所以过滤不能只看当天
   * （原来只看当天，于是拖到别的天之后它还在托盘里，用户以为没排上、又拖一次）。
   */
  static async listAllBlocks(context: common.Context): Promise<PlanBlock[]> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT * FROM plan_block ORDER BY date, start_min');
    const list: PlanBlock[] = [];
    while (rs.goToNextRow()) {
      list.push(TodoRepo.readBlock(rs));
    }
    rs.close();
    return list;
  }

  /**
   * 让「考试」的计划块与它的起止时间一致。
   *
   * 用户 2026-10-14：「考试应该不同于作业等，他有固定的时间范围，自动放入计划视图的相应时间段」，
   * 并且拍定**与已有的块重叠也照排**（考试时间是硬约束，不该去挪别人的计划）。
   *
   * 口径：**一场考试只有一个块，由这里全权维护** —— 先删掉它的旧块，再按新范围插一块。
   * 这样"改了考试时间"不会留下残块；用户把块拖走之后再存一次考试，它会回到时间范围上
   *（考试时间才是真相，拖动不该改写它）。
   *
   * 时间范围不合法时**只删不建**（等用户把时间填对再存），不抛错、不半途留下旧块。
   */
  static async syncExamBlock(context: common.Context, t: Todo): Promise<void> {
    if (!isExamCategory(t.category) || t.id <= 0) {
      return;
    }
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM plan_block WHERE todo_id = ?', [t.id]);
    const verdict: Validation = validateExamRange(t.ddl, t.endAt);
    if (!verdict.ok) {
      return;
    }
    const r: ExamRange = examRangeOf(t.ddl, t.endAt);
    const bucket: relationalStore.ValuesBucket = {
      'todo_id': t.id,
      'lesson_id': 0,
      'date': r.date,
      'start_min': r.startMin,
      'end_min': r.endMin,
      'done': 0
    };
    await store.insert('plan_block', bucket);
  }

  static async updateBlock(context: common.Context, b: PlanBlock): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql(
      'UPDATE plan_block SET date = ?, start_min = ?, end_min = ?, done = ? WHERE id = ?',
      [b.date, b.startMin, b.endMin, b.done ? 1 : 0, b.id]);
  }

  static async getBlock(context: common.Context, id: number): Promise<PlanBlock | undefined> {
    const store: relationalStore.RdbStore = await Db.get(context);
    const rs = await store.querySql('SELECT * FROM plan_block WHERE id = ?', [id]);
    let result: PlanBlock | undefined = undefined;
    if (rs.goToFirstRow()) {
      result = TodoRepo.readBlock(rs);
    }
    rs.close();
    return result;
  }

  /**
   * 直接写入待办时长。
   *
   * 专供「块时长回写」用，**刻意绕开 TodoRepo.updateTodo 里的 normalizeEstimate**：
   * 手动输入受 15–600 的上限约束，而多天拆分的**合计**是推导出来的、不是用户填的，
   * 把它悄悄夹到 600 会让「这个待办到底要多久」失真。
   * 合计本身一定落在 5 分钟刻度上（块起止都是 5 的倍数）。
   */
  static async setTodoEstimate(context: common.Context, id: number,
    estimateMin: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('UPDATE todo SET estimate_min = ? WHERE id = ?', [estimateMin, id]);
  }

  static async deleteBlock(context: common.Context, id: number): Promise<void> {
    const store: relationalStore.RdbStore = await Db.get(context);
    await store.executeSql('DELETE FROM plan_block WHERE id = ?', [id]);
  }
}
