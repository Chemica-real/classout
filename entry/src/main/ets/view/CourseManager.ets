import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, CourseSession, PKU_SECTION_TIMES, SectionTime, Semester,
  SessionRule, TodoTemplate, VirtualLesson } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { Seeder } from '../data/Seeder';
import { BackupRepo } from '../data/BackupRepo';
import { BackupBundle, backupSummary, parseBackup } from '../domain/Backup';
import { maskAll, maskFromText, maskToText } from '../model/WeekMask';
import { formatDate, hhmmToMin, minToHHmm, today, WEEKDAY_CN } from '../util/DateUtil';
import { TEMPLATE_VARS, TemplateCheck, Validation, validateSectionTimes, validateSessionRule,
  validateTemplateDdl, validateTemplateTitle } from '../domain/Validate';
import { renderTitle } from '../domain/TodoGenerator';
import { ChipButton } from './ChipButton';
import { BackHandler, backStack } from '../util/BackStack';
import { GLASS_BLUR, GLASS_EDGE_SOFT, GLASS_EDGE_STRONG, GLASS_RADIUS, GLASS_SHADOW_ROW,
  GLASS_SHADOW_SHEET, GLASS_TINT_PANEL, GLASS_TINT_ROW, GLASS_TINT_SHEET } from './Glass';

// 文件内 @Styles（Glass.ets 顶部说明了为什么不能跨文件 export）
// 深色版：模糊只留给页头与弹窗，课程/模板等列表卡是小卡（不模糊）
@Styles
function glassCard() {
  .backgroundColor(GLASS_TINT_ROW)
  .border({ width: 1, color: GLASS_EDGE_SOFT })
  .borderRadius(GLASS_RADIUS)
  .shadow(GLASS_SHADOW_ROW)
}

@Styles
function glassPanel() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_PANEL)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
}

@Styles
function glassSheet() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_SHEET)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
  .borderRadius(GLASS_RADIUS)
  .shadow(GLASS_SHADOW_SHEET)
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

const DD_LABELS: string[] = [
  '下一次同门课当天 23:59',
  '指定星期几 23:59',
  '本周日 23:59',
  '布置当天 23:59',
  'N 天后 23:59',
  '不设截止'
];
const DD_RULES: string[] = ['next_session', 'weekday', 'week_end', 'same_day', 'days', 'none'];

/**
 * 模板变量按钮上的中文标签，**下标必须和 `Validate.TEMPLATE_VARS` 一一对应**。
 * （%D 这种记号用户记不住，写清楚"布置日期"才好点。）
 */
const TEMPLATE_VAR_LABELS: string[] = ['课程全名', '课程简称', '布置日期', '完整日期',
  '周次', '起始节次', '第几次', '教室'];

function blankCourse(semesterId: number): Course {
  return {
    id: 0,
    semesterId: semesterId,
    name: '',
    shortName: '',
    teacher: '',
    location: '',
    colorIndex: 0,
    autoTodoEnabled: true,
    isVirtual: false,
    note: ''
  };
}

function blankRule(weeks: string): SessionRule {
  return {
    id: 0,
    courseId: 0,
    weekday: 1,
    startSection: 1,
    endSection: 2,
    weeksMask: weeks,
    location: '',
    isQuiz: false
  };
}

function blankTemplate(): TodoTemplate {
  return {
    id: 0,
    courseId: 0,
    sortOrder: 0,
    enabled: true,
    titleTemplate: '%D作业',
    ddlRule: 'next_session',
    ddlParam: '',
    estimateMin: 90,
    category: 'homework',
    submitChannel: '',
    note: ''
  };
}

/** 课程 / 时段规则 / 生成模板 的增删改；以及学期设置 */
@Component
export struct CourseManager {
  @Prop semesterId: number;
  close: () => void = (): void => {};

  @State mode: string = 'list';
  @State loading: boolean = true;
  @State semester: Semester | undefined = undefined;
  @State courses: Course[] = [];
  @State rules: SessionRule[] = [];
  @State templates: TodoTemplate[] = [];
  @State editSections: SectionTime[] = [];
  /** 当前编辑课程的课时数（虚拟课程用） */
  @State editLessonCount: number = 0;
  /** 本学期所有虚拟课程的课时 */
  @State allLessons: VirtualLesson[] = [];
  @State diagText: string = '';
  @State backupNote: string = '';
  @State confirmRestore: boolean = false;
  @State backupPath: string = '';

  @State editCourse: Course = blankCourse(0);
  @State editRules: SessionRule[] = [];
  @State editTemplates: TodoTemplate[] = [];

  @State ruleDialog: boolean = false;
  @State ruleDraft: SessionRule = blankRule('1-16');
  @State ruleWeeksText: string = '1-16';

  @State tplDialog: boolean = false;
  @State tplDraft: TodoTemplate = blankTemplate();
  /**
   * 标题输入框里的光标位置（快捷插入按钮要知道插哪儿）。
   * -1 = 用户还没碰过输入框 → 插到末尾。
   */
  @State tplCaret: number = -1;
  /**
   * 标题输入框的控制器。
   * ⚠️ 不能改用声明式的 `.caretPosition(this.tplCaret)`：首帧必须给一个非负值，
   * 于是"还没碰过"的 -1 会被写成 0，插入就变成**永远插到开头**
   *（真机实测：点「课程简称」得到「课丙10.14作业」而不是追加）。
   * 用控制器在插入后主动挪光标，就不会破坏 -1 这个哨兵值。
   */
  private tplInputCtl: TextInputController = new TextInputController();

  @State semName: string = '';
  @State semStart: string = '';
  @State semWeeks: number = 16;
  @State semesters: Semester[] = [];
  @State newSemName: string = '';
  @State newSemStart: string = '';
  @State newSemWeeks: number = 16;
  @State cloneFromCurrent: boolean = true;

  /**
   * 正在等二次确认的删除操作，形如 'course-3' / 'rule-5' / 'tpl-2' / 'rest-7'。
   * '' = 当前没有待确认的删除。
   *
   * ⚠️ 这里曾经是 `confirmDeleteCourseId: number`，而**全文件没有任何一处把它设成非 0**
   * （只有声明、两处读、两处写 0），所以课程列表里那段「确定删除这门课？」的确认行
   * 是永远不可能出现的死代码；真正能点到的删除按钮在课程编辑页，那里根本没有确认。
   * 用户实测「点删除没反应、必须手动返回才发现删掉了」就是这么来的。
   */
  @State pendingDeleteKey: string = '';
  @State confirmClear: boolean = false;
  @State toast: string = '';

  /** 系统返回的处理器（注册到 util/BackStack） */
  private backHandler: BackHandler | undefined = undefined;

  aboutToAppear(): void {
    this.backHandler = (): boolean => this.handleBack();
    backStack.register(this.backHandler);
    this.load();
  }

  aboutToDisappear(): void {
    if (this.backHandler !== undefined) {
      backStack.unregister(this.backHandler);
      this.backHandler = undefined;
    }
  }

  /**
   * 管理课程的返回顺序（从最上面那层往下）：
   * 弹窗 → 二次确认 → 子页 → 关闭整个管理器。
   * 它永远是"最后注册"的（浮层后挂载），所以 Index 一定先问到它。
   */
  private handleBack(): boolean {
    if (this.ruleDialog) {
      this.ruleDialog = false;
      return true;
    }
    if (this.tplDialog) {
      this.tplDialog = false;
      return true;
    }
    if (this.confirmClear) {
      this.confirmClear = false;
      return true;
    }
    if (this.confirmRestore) {
      this.confirmRestore = false;
      return true;
    }
    if (this.pendingDeleteKey.length > 0) {
      this.pendingDeleteKey = '';
      return true;
    }
    if (this.mode !== 'list') {
      this.mode = 'list';
      return true;
    }
    this.close();
    return true;
  }

  private context(): common.UIAbilityContext {
    // 先用 EntryAbility 存好的那份；只有极端情况才回退到已废弃的 getContext()
    const stored: common.UIAbilityContext | undefined = storedAbilityContext();
    if (stored !== undefined) {
      return stored;
    }
    return getContext(this) as common.UIAbilityContext;
  }

  private load(): void {
    this.reload().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'course manager load failed: %{public}s', JSON.stringify(e));
      this.loading = false;
    });
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const sem: Semester | undefined = await TimetableRepo.getSemester(ctx);
    this.semester = sem;
    const sid: number = sem === undefined ? this.semesterId : sem.id;
    if (sem !== undefined) {
      this.semName = sem.name;
      this.semStart = sem.startDate;
      this.semWeeks = sem.totalWeeks;
    }
    this.courses = await TimetableRepo.listCourses(ctx, sid);
    this.rules = await TimetableRepo.listRules(ctx, sid);
    this.templates = await TodoRepo.listTemplates(ctx, sid);
    this.semesters = await TimetableRepo.listSemesters(ctx);
    this.editSections = await TimetableRepo.listSectionTimes(ctx, sid);
    this.allLessons = await TodoRepo.listLessonsOfVirtualCourses(ctx, sid);
    this.loading = false;
  }

  private lessonsOf(courseId: number): VirtualLesson[] {
    const out: VirtualLesson[] = [];
    for (const l of this.allLessons) {
      if (l.courseId === courseId) {
        out.push(l);
      }
    }
    return out;
  }

  private doneLessonsOf(courseId: number): number {
    let n: number = 0;
    for (const l of this.allLessons) {
      if (l.courseId === courseId && l.done) {
        n++;
      }
    }
    return n;
  }

  private refresh(): void {
    this.reload().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'course manager reload failed: %{public}s', JSON.stringify(e));
    });
  }

  private rulesOf(courseId: number): SessionRule[] {
    const out: SessionRule[] = [];
    for (const r of this.rules) {
      if (r.courseId === courseId) {
        out.push(r);
      }
    }
    return out;
  }

  private templatesOf(courseId: number): TodoTemplate[] {
    const out: TodoTemplate[] = [];
    for (const t of this.templates) {
      if (t.courseId === courseId) {
        out.push(t);
      }
    }
    return out;
  }

  private ruleText(r: SessionRule): string {
    const sec: string = r.startSection === r.endSection
      ? `${r.startSection}`
      : `${r.startSection}-${r.endSection}`;
    const quiz: string = r.isQuiz ? ' 习题课' : '';
    return `周${WEEKDAY_CN[r.weekday - 1]} ${sec} 节 · ${maskToText(r.weeksMask)}${quiz}`;
  }

  private tplText(t: TodoTemplate): string {
    const idx: number = DD_RULES.indexOf(t.ddlRule);
    const label: string = idx >= 0 ? DD_LABELS[idx] : t.ddlRule;
    let param: string = '';
    if (t.ddlRule === 'weekday' && t.ddlParam.length > 0) {
      const w: number = parseInt(t.ddlParam, 10);
      param = `（周${WEEKDAY_CN[w - 1]}）`;
    } else if (t.ddlRule === 'days' && t.ddlParam.length > 0) {
      param = `（${t.ddlParam} 天）`;
    }
    return `${t.titleTemplate} · 截止：${label}${param} · 预计 ${t.estimateMin} 分钟`;
  }

  // ---------------- 课程 ----------------

  private openCourse(c: Course): void {
    this.editCourse = {
      id: c.id,
      semesterId: c.semesterId,
      name: c.name,
      shortName: c.shortName,
      teacher: c.teacher,
      location: c.location,
      colorIndex: c.colorIndex,
      autoTodoEnabled: c.autoTodoEnabled,
      isVirtual: c.isVirtual,
      note: c.note
    };
    this.editRules = this.rulesOf(c.id);
    this.editTemplates = this.templatesOf(c.id);
    this.editLessonCount = this.lessonsOf(c.id).length;
    this.mode = 'course';
  }

  private openNewCourse(): void {
    this.editCourse = blankCourse(this.semesterId);
    this.editRules = [];
    this.editTemplates = [];
    this.editLessonCount = 0;
    this.mode = 'course';
  }

  private saveCourse(): void {
    this.doSaveCourse().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save course failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSaveCourse(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const name: string = this.editCourse.name.trim();
    if (name.length === 0) {
      this.toast = '课程名不能为空';
      return;
    }
    this.editCourse.name = name;
    if (this.editCourse.id === 0) {
      const id: number = await TimetableRepo.insertCourse(ctx, this.editCourse);
      this.editCourse.id = id;
    } else {
      await TimetableRepo.updateCourse(ctx, this.editCourse);
    }
    if (this.editCourse.isVirtual) {
      await TodoRepo.syncLessonCount(ctx, this.editCourse.id, this.editLessonCount);
    }
    this.toast = this.editCourse.isVirtual
      ? `已保存（虚拟课程，${this.editLessonCount} 讲）`
      : '已保存';
    await this.reload();
    this.mode = 'list';
  }

  private deleteCourse(c: Course): void {
    this.doDeleteCourse(c).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'delete course failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 删除课程。删完**必须回到课程列表**，否则屏幕上还是那张课程编辑表单
   * （`mode` 仍是 'course'，`editCourse` 还是被删掉的那份数据），
   * 看起来就是"点了没反应"，用户只能手动返回才发现已经删了。
   */
  private async doDeleteCourse(c: Course): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TimetableRepo.deleteCourse(ctx, c.id);
    this.pendingDeleteKey = '';
    this.toast = `已删除「${c.shortName.length > 0 ? c.shortName : c.name}」`;
    this.mode = 'list';
    await this.reload();
  }

  // ---------------- 时段规则 ----------------

  private openRule(r: SessionRule | undefined): void {
    if (r === undefined) {
      this.ruleDraft = blankRule(maskAll(this.semester === undefined ? 16 : this.semester.totalWeeks));
      this.ruleDraft.courseId = this.editCourse.id;
      this.ruleWeeksText = '1-16';
    } else {
      this.ruleDraft = r;
      this.ruleWeeksText = maskToText(r.weeksMask);
    }
    this.ruleDialog = true;
  }

  private saveRule(): void {
    this.doSaveRule().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save rule failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSaveRule(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const total: number = this.semester === undefined ? 16 : this.semester.totalWeeks;
    this.ruleDraft.weeksMask = maskFromText(this.ruleWeeksText, total);
    this.ruleDraft.courseId = this.editCourse.id;
    // 「课程始末时间正确性」的落点：节次必须存在、开始不晚于结束、时间落在一天之内
    const verdict: Validation = validateSessionRule(this.ruleDraft, this.editSections);
    if (!verdict.ok) {
      this.toast = verdict.message;
      return;
    }
    if (this.ruleDraft.id === 0) {
      await TimetableRepo.insertRule(ctx, this.ruleDraft);
    } else {
      await TimetableRepo.updateRule(ctx, this.ruleDraft);
    }
    this.ruleDialog = false;
    this.editRules = await TimetableRepo.listRules(ctx, this.editCourse.semesterId);
    this.editRules = this.filterRules(this.editRules, this.editCourse.id);
    this.toast = '时段已保存';
    await this.reload();
  }

  private filterRules(all: SessionRule[], courseId: number): SessionRule[] {
    const out: SessionRule[] = [];
    for (const r of all) {
      if (r.courseId === courseId) {
        out.push(r);
      }
    }
    return out;
  }

  private deleteRule(r: SessionRule): void {
    this.doDeleteRule(r).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'delete rule failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doDeleteRule(r: SessionRule): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TimetableRepo.deleteRule(ctx, r.id);
    this.pendingDeleteKey = '';
    this.toast = '已删除该时段';
    this.editRules = this.filterRules(await TimetableRepo.listRules(ctx, this.editCourse.semesterId),
      this.editCourse.id);
    await this.reload();
  }

  // ---------------- 生成模板 ----------------

  private openTemplate(t: TodoTemplate | undefined): void {
    if (t === undefined) {
      this.tplDraft = blankTemplate();
      this.tplDraft.courseId = this.editCourse.id;
    } else {
      this.tplDraft = t;
    }
    this.tplDialog = true;
  }

  private saveTemplate(): void {
    this.doSaveTemplate().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save template failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSaveTemplate(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    this.tplDraft.courseId = this.editCourse.id;
    // 输入合法性检验（纯函数 + 离线断言）：空、超长、以及不支持的 %变量
    const titleCheck: TemplateCheck = validateTemplateTitle(this.tplDraft.titleTemplate);
    if (!titleCheck.ok) {
      this.toast = titleCheck.message;
      return;
    }
    // 截止规则的参数也要查：days 要 1–365、weekday 要 1–7
    const ddlCheck: Validation = validateTemplateDdl(this.tplDraft.ddlRule, this.tplDraft.ddlParam);
    if (!ddlCheck.ok) {
      this.toast = ddlCheck.message;
      return;
    }
    if (this.tplDraft.id === 0) {
      await TodoRepo.insertTemplate(ctx, this.tplDraft);
    } else {
      await TodoRepo.updateTemplate(ctx, this.tplDraft);
    }
    this.tplDialog = false;
    this.editTemplates = await TodoRepo.listTemplatesByCourse(ctx, this.editCourse.id);
    this.toast = '模板已保存（下次下课时生效）';
    await this.reload();
  }

  /** 变量按钮上的中文标签 */
  private templateVarLabel(v: string): string {
    const i: number = TEMPLATE_VARS.indexOf(v);
    return i < 0 ? `%${v}` : TEMPLATE_VAR_LABELS[i];
  }

  /**
   * 把变量插到**光标处**（用户还没定位过光标就插到末尾），并把光标移到变量之后，
   * 这样可以连着点几个按钮拼出「%D%c作业」这种。
   */
  private insertTemplateVar(v: string): void {
    const token: string = `%${v}`;
    const cur: string = this.tplDraft.titleTemplate;
    const pos: number = this.tplCaret < 0 ? cur.length : Math.min(this.tplCaret, cur.length);
    this.tplDraft.titleTemplate = cur.substring(0, pos) + token + cur.substring(pos);
    this.tplCaret = pos + token.length;
    // 把可见光标也挪到变量之后，方便接着点下一个按钮
    //（输入框没聚焦时这是空操作，不影响）
    this.tplInputCtl.caretPosition(this.tplCaret);
  }

  /** 当前模板的校验结果（预览行与保存前都用它，只有一处判据） */
  private templateCheck(): TemplateCheck {
    return validateTemplateTitle(this.tplDraft.titleTemplate);
  }

  /**
   * 实时预览：拿**这门课自己的名字** + 一个样例日期渲染一遍。
   *
   * 为什么值得做：`%D`/`%W` 这些记号是抽象的，用户真正想知道的是
   * "下课时生成的那条待办到底叫什么"。
   */
  private templatePreviewText(): string {
    const check: TemplateCheck = this.templateCheck();
    if (!check.ok) {
      return check.message;
    }
    const name: string = this.editCourse.name.length > 0 ? this.editCourse.name : '课程全名';
    const short: string = this.editCourse.shortName.length > 0 ? this.editCourse.shortName : name;
    const sampleCourse: Course = {
      id: this.editCourse.id,
      semesterId: this.editCourse.semesterId,
      name: name,
      shortName: short,
      teacher: '',
      location: this.editCourse.location,
      colorIndex: this.editCourse.colorIndex,
      autoTodoEnabled: true,
      isVirtual: false,
      note: ''
    };
    const sampleRule: SessionRule = {
      id: 0,
      courseId: this.editCourse.id,
      weekday: 1,
      startSection: 3,
      endSection: 4,
      weeksMask: '1',
      location: '',
      isQuiz: false
    };
    const todayDate: string = formatDate(today());
    const sample: CourseSession = {
      course: sampleCourse,
      rule: sampleRule,
      date: todayDate,
      originDate: todayDate,
      weekday: 1,
      startSection: 3,
      endSection: 4,
      startMin: 600,
      endMin: 690,
      location: this.editCourse.location.length > 0 ? this.editCourse.location : '教学楼101',
      isQuiz: false,
      fromOverride: false
    };
    // week=6 / n=2 只是样例值，让 %W / %N 也有东西可看
    return `预览：${renderTitle(this.tplDraft.titleTemplate, sample, 6, 2)}`;
  }

  private deleteTemplate(t: TodoTemplate): void {
    this.doDeleteTemplate(t).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'delete template failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doDeleteTemplate(t: TodoTemplate): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TodoRepo.deleteTemplate(ctx, t.id);
    this.pendingDeleteKey = '';
    this.toast = '已删除该模板';
    this.editTemplates = await TodoRepo.listTemplatesByCourse(ctx, this.editCourse.id);
    await this.reload();
  }

  // ---------------- 学期 ----------------

  private saveSemester(): void {
    this.doSaveSemester().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save semester failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSaveSemester(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const sem: Semester | undefined = this.semester;
    if (sem === undefined) {
      return;
    }
    if (this.semStart.length !== 10 || this.semStart.charAt(4) !== '-') {
      this.toast = '开学日期格式应为 YYYY-MM-DD（第一教学周的周一）';
      return;
    }
    sem.name = this.semName;
    sem.startDate = this.semStart;
    sem.totalWeeks = this.semWeeks;
    await TimetableRepo.updateSemester(ctx, sem);
    this.toast = '学期设置已保存';
    this.mode = 'list';
    await this.reload();
  }

  private reseed(): void {
    this.doReseed().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'reseed failed: %{public}s', JSON.stringify(e));
    });
  }

  private isActiveSem(s: Semester): boolean {
    const cur: Semester | undefined = this.semester;
    return cur !== undefined && cur.id === s.id;
  }

  // ---------------- 节次时间 ----------------

  /** 在末尾加一节（默认比上一节晚 70 分钟开始） */
  private addSection(): void {
    const list: SectionTime[] = this.editSections;
    let nextSection: number = 1;
    let startMin: number = 8 * 60;
    for (const st of list) {
      if (st.section >= nextSection) {
        nextSection = st.section + 1;
      }
      if (st.endMin + 10 > startMin) {
        startMin = st.endMin + 10;
      }
    }
    const fresh: SectionTime = {
      section: nextSection,
      startMin: startMin,
      endMin: startMin + 50,
      flexible: false
    };
    this.editSections = list.concat([fresh]);
  }

  private removeSection(idx: number): void {
    const copy: SectionTime[] = [];
    for (let i = 0; i < this.editSections.length; i++) {
      if (i !== idx) {
        copy.push(this.editSections[i]);
      }
    }
    this.editSections = copy;
  }

  private saveSections(): void {
    this.doSaveSections().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save sections failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSaveSections(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const sem: Semester | undefined = this.semester;
    if (sem === undefined) {
      return;
    }
    // ⚠️ 这里原来会**静默**把 `endMin <= startMin` 的节次改成 `start + 50`。
    // 悄悄改用户填的数字是这个项目被用户抓到过的 bug，改成明确报错、拒绝保存。
    const verdict: Validation = validateSectionTimes(this.editSections);
    if (!verdict.ok) {
      this.toast = verdict.message;
      return;
    }
    const existing: SectionTime[] = await TimetableRepo.listSectionTimes(ctx, sem.id);
    const keep: Set<number> = new Set<number>();
    for (const st of this.editSections) {
      keep.add(st.section);
    }
    for (const st of existing) {
      if (!keep.has(st.section)) {
        await TimetableRepo.deleteSectionTime(ctx, sem.id, st.section);
      }
    }
    for (const st of this.editSections) {
      await TimetableRepo.upsertSectionTime(ctx, sem.id, st);
    }
    this.toast = '节次时间已保存';
    this.mode = 'list';
    await this.reload();
  }

  /** 从别的学期复制课表到当前学期（「复制上学期」） */
  private copyFrom(fromId: number): void {
    this.doCopyFrom(fromId).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'copy semester failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doCopyFrom(fromId: number): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const toId: number = this.semester === undefined ? this.semesterId : this.semester.id;
    const n: number = await Seeder.cloneCourses(ctx, fromId, toId);
    this.toast = n === 0 ? '没有可复制的课（可能已存在同名课程）' : `已复制 ${n} 门课到当前学期`;
    await this.reload();
  }

  private createSemester(): void {
    this.doCreateSemester().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'create semester failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doCreateSemester(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const name: string = this.newSemName.trim().length > 0 ? this.newSemName.trim() : '新学期';
    if (this.newSemStart.length !== 10 || this.newSemStart.charAt(4) !== '-') {
      this.toast = '开学日期格式应为 YYYY-MM-DD（第一教学周的周一）';
      return;
    }
    const previousId: number = this.semester === undefined ? 0 : this.semester.id;
    const newId: number = await TimetableRepo.createSemester(ctx, name, this.newSemStart, this.newSemWeeks);
    for (const st of PKU_SECTION_TIMES) {
      await TimetableRepo.upsertSectionTime(ctx, newId, st);
    }
    let copied: number = 0;
    if (this.cloneFromCurrent && previousId > 0) {
      copied = await Seeder.cloneCourses(ctx, previousId, newId);
    }
    await TimetableRepo.setActiveSemesterId(ctx, newId);
    this.newSemName = '';
    this.newSemStart = '';
    this.toast = `已新建「${name}」并切换${copied > 0 ? `，复制了 ${copied} 门课` : ''}`;
    this.mode = 'list';
    await this.reload();
  }

  private async doReseed(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const sem: Semester | undefined = this.semester;
    if (sem === undefined) {
      return;
    }
    await Seeder.clearCourses(ctx, sem.id);
    await Seeder.seedCourses(ctx, sem.id);
    this.confirmClear = false;
    this.toast = '已重置为截图转录的课表';
    await this.reload();
  }

  // ---------------- UI ----------------

  @Builder
  FieldLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#94A0B5')
      .width('100%')
      .margin({ top: 12, bottom: 4 })
  }

  /**
   * 删除前的二次确认行。
   *
   * `key` 与 `pendingDeleteKey` 比对决定是否显示 —— 由调用方用 `if (...)` 包住，
   * 所以这里不需要响应式（@Builder 的参数按值固化，见 HANDOFF §6.4；
   * 节点是随 `if` 新建/销毁的，不存在"参数变了内部不重渲"的问题）。
   */
  @Builder
  DeleteConfirmRow(message: string, key: string, onConfirm: () => void) {
    Row() {
      Text(message)
        .fontSize(11)
        .fontColor('#FF8A8A')
        .layoutWeight(1)
      Text('取消')
        .fontSize(12)
        .fontColor('#A9B5C9')
        .padding({ left: 10, right: 10 })
        .onClick((): void => {
          this.pendingDeleteKey = '';
        })
      Text('删除')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#D64545')
        .borderRadius(8)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .onClick(onConfirm)
    }
    .width('100%')
    .margin({ top: 8 })
  }

  /** 二次确认用的键 */
  private deleteKey(kind: string, id: number): string {
    return `${kind}-${id}`;
  }

  @Builder
  TopBar(title: string, backLabel: string, onBack: () => void) {
    Row() {
      Text(backLabel)
        .fontSize(15)
        .fontColor('#7FA8FF')
        .onClick(onBack)
      Blank()
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F2F5FA')
      Blank()
      Text('    ')
        .fontSize(15)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .glassPanel()
  }

  @Builder
  ListView() {
    Column() {
      this.TopBar('课程与学期', '关闭', (): void => this.close())

      Scroll() {
        Column() {
          if (this.toast.length > 0) {
            Text(this.toast)
              .fontSize(12)
              .fontColor('#7FA8FF')
              .width('100%')
              .padding({ top: 6, bottom: 6 })
          }

          Row() {
            Text('学期')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text(this.semester === undefined
              ? ''
              : `${this.semester.name} · ${this.semester.startDate} 起 · ${this.semester.totalWeeks} 周`)
              .fontSize(12)
              .fontColor('#94A0B5')
          }
          .width('100%')
          .padding(12)
          .glassCard()
          .borderRadius(10)
          .margin({ bottom: 8 })
          .onClick((): void => {
            this.mode = 'semester';
          })

          Row() {
            Text('上课节次时间')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text(`${this.editSections.length} 节 · 可随意改`)
              .fontSize(12)
              .fontColor('#94A0B5')
          }
          .width('100%')
          .padding(12)
          .glassCard()
          .borderRadius(10)
          .margin({ bottom: 8 })
          .onClick((): void => {
            this.mode = 'sections';
          })

          Row() {
            Text('备份与恢复')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text('导出 JSON / 整份恢复 / 诊断')
              .fontSize(12)
              .fontColor('#94A0B5')
          }
          .width('100%')
          .padding(12)
          .glassCard()
          .borderRadius(10)
          .margin({ bottom: 8 })
          .onClick((): void => this.openBackup())

          Row() {
            Text(`课程（${this.courses.length}）`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text('+ 新增课程')
              .fontSize(13)
              .fontColor('#7FA8FF')
              .onClick((): void => this.openNewCourse())
          }
          .width('100%')
          .margin({ top: 8, bottom: 8 })

          if (this.courses.length === 0) {
            Text('还没有课程。点右上角新增，或先把截图转录的课表载进来。')
              .fontSize(12)
              .fontColor('#8B97AC')
              .width('100%')
              .margin({ bottom: 10 })
          }

          ForEach(this.courses, (c: Course) => {
            Column() {
              Row() {
                Text(c.shortName.length > 0 ? c.shortName : c.name)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#F2F5FA')
                  .backgroundColor(COURSE_COLORS[c.colorIndex % COURSE_COLORS.length])
                  .borderRadius(4)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                Text(c.name)
                  .fontSize(13)
                  .fontColor('#C3CDDE')
                  .margin({ left: 8 })
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (!c.autoTodoEnabled) {
                  Text('不自动生成')
                    .fontSize(10)
                    .fontColor('#8B97AC')
                }
              }
              .width('100%')

              ForEach(this.rulesOf(c.id), (r: SessionRule) => {
                Text(this.ruleText(r))
                  .fontSize(11)
                  .fontColor('#9BA7BD')
                  .width('100%')
                  .margin({ top: 4 })
              }, (r: SessionRule) =>
                `lr-${r.id}-${r.weekday}-${r.startSection}-${r.endSection}-${r.weeksMask}-${r.location}-${r.isQuiz}`)

              ForEach(this.templatesOf(c.id), (t: TodoTemplate) => {
                Text(`⚙ ${this.tplText(t)}`)
                  .fontSize(11)
                  .fontColor('#7BD69A')
                  .width('100%')
                  .margin({ top: 4 })
              }, (t: TodoTemplate) =>
                `lt-${t.id}-${t.titleTemplate}-${t.ddlRule}-${t.ddlParam}-${t.estimateMin}-${t.enabled}`)

              if (c.isVirtual) {
                Text(`虚拟课程 · ${this.lessonsOf(c.id).length} 讲，已完成 ${this.doneLessonsOf(c.id)}`)
                  .fontSize(11)
                  .fontColor('#E0A94E')
                  .width('100%')
                  .margin({ top: 4 })
              }

              // 这里原本有一段「确定删除这门课？」的确认行，但它依赖的
              // confirmDeleteCourseId 全文件没有任何一处被设成非 0 —— 永远不可能显示。
              // 死代码已删除；真正可达的删除入口在课程编辑页（见 CourseView 的删除按钮）。
            }
            .width('100%')
            .padding(12)
            .glassCard()
            .borderRadius(10)
            .margin({ bottom: 8 })
            .onClick((): void => this.openCourse(c))
          }, (c: Course) =>
            // ⚠️ key 必须带上**这一行真正渲染的字段**：只写 id 的话，
            // 改完课程回到列表会按 key 复用旧节点、看到的是旧名字（§12.4 第 4 条）
            `lc-${c.id}-${c.name}-${c.shortName}-${c.colorIndex}-${c.autoTodoEnabled}-${c.isVirtual}-${this.rulesOf(c.id).length}-${this.templatesOf(c.id).length}`)

          if (this.courses.length > 0) {
            if (this.confirmClear) {
              Row() {
                Text('确定清空全部课程并从截图转录重载？手改的内容会丢。')
                  .fontSize(11)
                  .fontColor('#FF8A8A')
                  .layoutWeight(1)
                Text('取消')
                  .fontSize(12)
                  .fontColor('#A9B5C9')
                  .padding({ left: 8, right: 8 })
                  .onClick((): void => {
                    this.confirmClear = false;
                  })
                Text('确定重载')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#D64545')
                  .borderRadius(8)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .onClick((): void => this.reseed())
              }
              .width('100%')
              .margin({ top: 8 })
            } else {
              Text('重置为截图转录的课表')
                .fontSize(12)
                .fontColor('#8B97AC')
                .width('100%')
                .padding({ top: 8 })
                .onClick((): void => {
                  this.confirmClear = true;
                })
            }
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  CourseView() {
    Column() {
      this.TopBar(this.editCourse.id === 0 ? '新增课程' : '编辑课程', '‹ 返回', (): void => {
        this.mode = 'list';
      })

      Scroll() {
        Column() {
          this.FieldLabel('课程名（全称）')
          TextInput({ text: this.editCourse.name, placeholder: '课程甲' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.editCourse.name = v;
            })

          this.FieldLabel('简称（显示在课表格子里）')
          TextInput({ text: this.editCourse.shortName, placeholder: '课甲' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.editCourse.shortName = v;
            })

          this.FieldLabel('教师')
          TextInput({ text: this.editCourse.teacher, placeholder: '老师甲' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.editCourse.teacher = v;
            })

          this.FieldLabel('默认地点')
          TextInput({ text: this.editCourse.location, placeholder: '教学楼407' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.editCourse.location = v;
            })

          this.FieldLabel('颜色')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(COURSE_COLORS, (col: string, idx: number) => {
              Text(' ')
                .width(30)
                .height(30)
                .backgroundColor(col)
                .borderRadius(15)
                .border({
                  width: this.editCourse.colorIndex === idx ? 3 : 1,
                  color: this.editCourse.colorIndex === idx ? '#F2F5FA' : 'rgba(255,255,255,0.12)'
                })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => {
                  this.editCourse.colorIndex = idx;
                })
            }, (col: string, idx: number) =>
              // 选中环是按 idx 判定的：key 里必须带「选中与否」，否则换了颜色不重画
              `col-${idx}-${this.editCourse.colorIndex === idx}`)
          }
          .width('100%')

          Row() {
            Column() {
              Text('下课后自动生成待办')
                .fontSize(14)
                .fontColor('#F2F5FA')
              Text('关掉它就只保留手填的事项（比如你不去上的课）')
                .fontSize(11)
                .fontColor('#94A0B5')
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.editCourse.autoTodoEnabled })
              .onChange((on: boolean): void => {
                this.editCourse.autoTodoEnabled = on;
              })
          }
          .width('100%')
          .margin({ top: 8 })

          Row() {
            Column() {
              Text('虚拟课程（不定时上课）')
                .fontSize(14)
                .fontColor('#F2F5FA')
              Text('比如 CS106L：没有固定上课时间，是一串等着被排进计划的课时')
                .fontSize(11)
                .fontColor('#94A0B5')
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.editCourse.isVirtual })
              .onChange((on: boolean): void => {
                this.editCourse.isVirtual = on;
                if (on && this.editLessonCount === 0) {
                  this.editLessonCount = 14;
                }
              })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.editCourse.isVirtual) {
            Text(`共多少讲（当前 ${this.editLessonCount}）`)
              .fontSize(12)
              .fontColor('#94A0B5')
              .width('100%')
              .margin({ top: 8, bottom: 6 })
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach([4, 6, 8, 10, 12, 14, 16, 20, 24, 32], (n: number) => {
                ChipButton({
                  text: `${n} 讲`,
                  selected: this.editLessonCount === n,
                  onTap: (): void => {
                  this.editLessonCount = n;
                }
                })
              }, (n: number) => `vl-${n}`)
            }
            .width('100%')
            Text('课时排进计划、打勾完成之后，会像真课下课一样按下面的模板生成待办。')
              .fontSize(11)
              .fontColor('#7BD69A')
              .width('100%')
          }

          // 时段规则
          Row() {
            Text(this.editCourse.isVirtual
              ? '上课时段（虚拟课程可留空）'
              : `上课时段（${this.editRules.length}）`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text('+ 添加时段')
              .fontSize(13)
              .fontColor('#7FA8FF')
              .onClick((): void => this.openRule(undefined))
          }
          .width('100%')
          .margin({ top: 18, bottom: 8 })

          if (this.editRules.length === 0) {
            Text('还没有时段。一周上两次就加两条。')
              .fontSize(12)
              .fontColor('#8B97AC')
              .margin({ bottom: 6 })
          }

          ForEach(this.editRules, (r: SessionRule) => {
            Column() {
              Row() {
                Text(this.ruleText(r))
                  .fontSize(12)
                  .fontColor('#C3CDDE')
                  .layoutWeight(1)
                Text('改')
                  .fontSize(12)
                  .fontColor('#7FA8FF')
                  .padding({ left: 10, right: 10 })
                  .onClick((): void => this.openRule(r))
                Text('删')
                  .fontSize(12)
                  .fontColor('#FF8080')
                  .onClick((): void => {
                    this.pendingDeleteKey = this.deleteKey('rule', r.id);
                  })
              }
              .width('100%')
              .padding(10)
              .glassCard()
              .borderRadius(8)

              // 删时段会让这节课直接从课表消失，且没有撤销 —— 拦一道确认
              if (this.pendingDeleteKey === this.deleteKey('rule', r.id)) {
                this.DeleteConfirmRow(`确定删除「${this.ruleText(r)}」？`, this.deleteKey('rule', r.id),
                  (): void => this.deleteRule(r))
              }
            }
            .width('100%')
            .margin({ bottom: 6 })
          }, (r: SessionRule) =>
              `er-${r.id}-${r.weekday}-${r.startSection}-${r.endSection}-${r.weeksMask}-${r.location}-${this.pendingDeleteKey === this.deleteKey('rule', r.id)}`)

          // 生成模板
          Row() {
            Text(`待办生成模板（${this.editTemplates.length}）`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text('+ 添加模板')
              .fontSize(13)
              .fontColor('#7FA8FF')
              .onClick((): void => this.openTemplate(undefined))
          }
          .width('100%')
          .margin({ top: 18, bottom: 8 })

          if (this.editTemplates.length === 0) {
            Text('没有模板 → 这门课下课不会自动生成待办。')
              .fontSize(12)
              .fontColor('#8B97AC')
              .margin({ bottom: 6 })
          }

          ForEach(this.editTemplates, (t: TodoTemplate) => {
            Column() {
              Row() {
                Text(this.tplText(t))
                  .fontSize(12)
                  .fontColor('#7BD69A')
                  .layoutWeight(1)
                Text('改')
                  .fontSize(12)
                  .fontColor('#7FA8FF')
                  .padding({ left: 10, right: 10 })
                  .onClick((): void => this.openTemplate(t))
                Text('删')
                  .fontSize(12)
                  .fontColor('#FF8080')
                  .onClick((): void => {
                    this.pendingDeleteKey = this.deleteKey('tpl', t.id);
                  })
              }
              .width('100%')
              .padding(10)
              .glassCard()
              .borderRadius(8)

              // 删模板会让这门课以后不再自动生成待办 —— 拦一道确认
              if (this.pendingDeleteKey === this.deleteKey('tpl', t.id)) {
                this.DeleteConfirmRow(`确定删除模板「${this.tplText(t)}」？`, this.deleteKey('tpl', t.id),
                  (): void => this.deleteTemplate(t))
              }
            }
            .width('100%')
            .margin({ bottom: 6 })
          }, (t: TodoTemplate) =>
              `et-${t.id}-${t.titleTemplate}-${t.ddlRule}-${t.ddlParam}-${t.estimateMin}-${this.pendingDeleteKey === this.deleteKey('tpl', t.id)}`)

          Row() {
            Button('保存课程')
              .backgroundColor('#2E6BE6')
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .onClick((): void => this.saveCourse())
            if (this.editCourse.id !== 0) {
              Button('删除课程')
                .backgroundColor('rgba(214,69,69,0.18)')
                .fontColor('#FF8A8A')
                .margin({ left: 10 })
                .onClick((): void => {
                  this.pendingDeleteKey = this.deleteKey('course', this.editCourse.id);
                })
            }
          }
          .width('100%')
          .margin({ top: 20 })

          // 删课程会连带删掉它的时段、生成模板和单周覆盖，没有撤销 —— 必须二次确认。
          // 确认后 doDeleteCourse 会切回课程列表，用户立刻能看见它没了（这正是原来缺的那一步）。
          if (this.editCourse.id !== 0
            && this.pendingDeleteKey === this.deleteKey('course', this.editCourse.id)) {
            this.DeleteConfirmRow(
              `确定删除「${this.editCourse.shortName.length > 0 ? this.editCourse.shortName : this.editCourse.name}」及其所有时段、模板？`,
              this.deleteKey('course', this.editCourse.id),
              (): void => this.deleteCourse(this.editCourse))
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  SemesterView() {
    Column() {
      this.TopBar('学期设置', '‹ 返回', (): void => {
        this.mode = 'list';
      })

      Scroll() {
        Column() {
          if (this.toast.length > 0) {
            Text(this.toast)
              .fontSize(12)
              .fontColor('#7FA8FF')
              .width('100%')
              .margin({ bottom: 6 })
          }

          this.FieldLabel('学期名称')
          TextInput({ text: this.semName, placeholder: '大一上' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.semName = v;
            })

          this.FieldLabel('第一教学周周一（YYYY-MM-DD）')
          TextInput({ text: this.semStart, placeholder: '2026-09-07' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.semStart = v;
            })
          Text('北大 2026 秋季：9/7 开学，16 个教学周（到 12/27）')
            .fontSize(11)
            .fontColor('#8B97AC')
            .margin({ top: 4 })

          this.FieldLabel('教学周数')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach([14, 15, 16, 17, 18, 20], (n: number) => {
              ChipButton({
                text: `${n} 周`,
                selected: this.semWeeks === n,
                onTap: (): void => {
                this.semWeeks = n;
              }
              })
            }, (n: number) => `sw-${n}`)
          }
          .width('100%')

          Button('保存学期设置')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .width('100%')
            .margin({ top: 20 })
            .onClick((): void => this.saveSemester())

          Text('所有学期')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
            .margin({ top: 24, bottom: 8 })

          ForEach(this.semesters, (s: Semester) => {
            Row() {
              Column() {
                Text(s.name)
                  .fontSize(14)
                  .fontColor('#F2F5FA')
                Text(`${s.startDate} 起 · ${s.totalWeeks} 周`)
                  .fontSize(11)
                  .fontColor('#94A0B5')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.isActiveSem(s)) {
                Text('当前')
                  .fontSize(11)
                  .fontColor('#7FA8FF')
              } else {
                Text('复制到当前学期')
                  .fontSize(12)
                  .fontColor('#7FA8FF')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor('rgba(46,107,230,0.22)')
                  .borderRadius(8)
                  .onClick((): void => this.copyFrom(s.id))
              }
            }
            .width('100%')
            .padding(10)
            .glassCard()
            .borderRadius(8)
            .margin({ bottom: 6 })
          }, (s: Semester) =>
            `sem-${s.id}-${s.name}-${s.startDate}-${s.totalWeeks}-${s.firstDayOfWeek}-${s.showWeekend}`)

          Text('新建学期（下学期开学时用）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
            .margin({ top: 24, bottom: 4 })

          this.FieldLabel('名称')
          TextInput({ text: this.newSemName, placeholder: '大一下' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.newSemName = v;
            })

          this.FieldLabel('第一教学周周一（YYYY-MM-DD）')
          TextInput({ text: this.newSemStart, placeholder: '2027-02-22' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.newSemStart = v;
            })

          this.FieldLabel('教学周数')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach([14, 15, 16, 17, 18, 20], (n: number) => {
              ChipButton({
                text: `${n} 周`,
                selected: this.newSemWeeks === n,
                onTap: (): void => {
                this.newSemWeeks = n;
              }
              })
            }, (n: number) => `nw-${n}`)
          }
          .width('100%')

          Row() {
            Column() {
              Text('顺便复制当前学期的课表')
                .fontSize(14)
                .fontColor('#F2F5FA')
              Text('新学期的课大多和上学期一样，复制后改改就行')
                .fontSize(11)
                .fontColor('#94A0B5')
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.cloneFromCurrent })
              .onChange((on: boolean): void => {
                this.cloneFromCurrent = on;
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Button('新建并切换到这个学期')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .width('100%')
            .margin({ top: 16 })
            .onClick((): void => this.createSemester())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  // ---------------- 备份与恢复 ----------------

  private openBackup(): void {
    this.backupNote = '';
    this.confirmRestore = false;
    this.mode = 'backup';
    this.refreshDiagnostics();
  }

  private refreshDiagnostics(): void {
    this.doRefreshDiagnostics().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'diagnostics failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doRefreshDiagnostics(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    this.backupPath = BackupRepo.backupFilePath(ctx);
    this.diagText = await BackupRepo.diagnostics(ctx);
  }

  private doExport(): void {
    this.runExport().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'export failed: %{public}s', JSON.stringify(e));
      this.backupNote = `导出失败：${JSON.stringify(e)}`;
    });
  }

  private async runExport(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const bytes: number = await BackupRepo.exportToFile(ctx);
    const bundle: BackupBundle = await BackupRepo.exportAll(ctx);
    this.backupNote = `已写入 ${bytes} 字节\n${backupSummary(bundle)}`;
    await this.refreshDiagnostics();
  }

  private doRestore(): void {
    this.runRestore().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'restore failed: %{public}s', JSON.stringify(e));
      this.backupNote = `恢复失败：${JSON.stringify(e)}`;
    });
  }

  private async runRestore(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const text: string = await BackupRepo.readBackupText(ctx);
    if (text.length === 0) {
      this.backupNote = '还没有备份文件，先点上面的「导出备份」。';
      this.confirmRestore = false;
      return;
    }
    const bundle: BackupBundle | undefined = parseBackup(text);
    if (bundle === undefined) {
      this.backupNote = '备份文件读不懂（不是本 App 的备份，或格式太新）。已放弃恢复，数据没动。';
      this.confirmRestore = false;
      return;
    }
    await BackupRepo.importAll(ctx, bundle);
    this.confirmRestore = false;
    this.backupNote = `已从备份恢复：\n${backupSummary(bundle)}`;
    await this.reload();
    await this.refreshDiagnostics();
  }

  @Builder
  BackupView() {
    Column() {
      this.TopBar('备份与恢复', '‹ 返回', (): void => {
        this.mode = 'list';
      })

      Scroll() {
        Column() {
          Text('数据只在这台手机里。导出会把全部内容写成一个 JSON 文件放在应用沙箱，恢复则用它整份覆盖当前数据。')
            .fontSize(11)
            .fontColor('#94A0B5')
            .width('100%')
            .margin({ bottom: 12 })

          if (this.backupNote.length > 0) {
            Text(this.backupNote)
              .fontSize(12)
              .fontColor('#7FA8FF')
              .width('100%')
              .padding(10)
              .backgroundColor('rgba(46,107,230,0.22)')
              .borderRadius(8)
              .margin({ bottom: 12 })
          }

          Button('导出备份到文件')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .width('100%')
            .onClick((): void => this.doExport())

          Text('备份文件路径')
            .fontSize(12)
            .fontColor('#94A0B5')
            .width('100%')
            .margin({ top: 14, bottom: 4 })
          Text(this.backupPath)
            .fontSize(11)
            .fontColor('#C3CDDE')
            .width('100%')
            .padding(8)
            .backgroundColor('rgba(255,255,255,0.10)')
            .borderRadius(6)

          Text('想把它存到电脑上（或发给我排查问题），在这个项目目录里跑：')
            .fontSize(11)
            .fontColor('#94A0B5')
            .width('100%')
            .margin({ top: 10, bottom: 4 })
          Text(`./hdc.sh file recv ${this.backupPath} ./signing/`)
            .fontSize(10)
            .fontColor('#CBD6E8')
            .width('100%')
            .padding(8)
            .backgroundColor('rgba(255,255,255,0.10)')
            .borderRadius(6)

          if (this.confirmRestore) {
            Text('确定用备份覆盖当前数据？当前内容会被整份替换，且不可撤销。')
              .fontSize(12)
              .fontColor('#FF8A8A')
              .width('100%')
              .padding(10)
              .backgroundColor('rgba(214,69,69,0.18)')
              .borderRadius(8)
              .margin({ top: 16 })
            Row() {
              Button('取消')
                .backgroundColor('rgba(255,255,255,0.14)')
                .fontColor('#C3CDDE')
                .layoutWeight(1)
                .onClick((): void => {
                  this.confirmRestore = false;
                })
              Button('确认恢复')
                .backgroundColor('#D64545')
                .fontColor('#FFFFFF')
                .layoutWeight(1)
                .margin({ left: 10 })
                .onClick((): void => this.doRestore())
            }
            .width('100%')
            .margin({ top: 10 })
          } else {
            Button('从备份恢复')
              .backgroundColor('rgba(178,107,0,0.20)')
              .fontColor('#E8B25C')
              .width('100%')
              .margin({ top: 16 })
              .onClick((): void => {
                this.confirmRestore = true;
              })
          }

          Row() {
            Text('诊断信息')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
            Text('刷新')
              .fontSize(12)
              .fontColor('#7FA8FF')
              .onClick((): void => this.refreshDiagnostics())
          }
          .width('100%')
          .margin({ top: 22, bottom: 6 })

          Text(this.diagText.length > 0 ? this.diagText : '（读取中…）')
            .fontSize(11)
            .fontColor('#C3CDDE')
            .width('100%')
            .padding(10)
            .glassCard()
            .borderRadius(8)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  SectionsView() {
    Column() {
      this.TopBar('上课节次时间', '‹ 返回', (): void => {
        this.mode = 'list';
      })

      Scroll() {
        Column() {
          Text('改这里会立刻影响课表格子的排布。北大校本部一天 12 节，第 9、12 节是机动节次（默认画得矮一点）。')
            .fontSize(11)
            .fontColor('#94A0B5')
            .width('100%')
            .margin({ bottom: 10 })

          Row() {
            Text('节').fontSize(11).fontColor('#94A0B5').width(26)
            Text('开始').fontSize(11).fontColor('#94A0B5').layoutWeight(1)
            Text('结束').fontSize(11).fontColor('#94A0B5').layoutWeight(1)
            Text('机动').fontSize(11).fontColor('#94A0B5').width(48).textAlign(TextAlign.Center)
            Text('  ').width(24)
          }
          .width('100%')
          .margin({ bottom: 4 })

          ForEach(this.editSections, (st: SectionTime, idx: number) => {
            Row() {
              Text(`${st.section}`)
                .fontSize(13)
                .fontColor('#C3CDDE')
                .width(26)
              TextInput({ text: minToHHmm(st.startMin) })
                .fontColor('#F2F5FA')
                .placeholderColor('#8B97AC')
                .caretColor('#7FA8FF')
                .layoutWeight(1)
                .fontSize(13)
                .onChange((v: string): void => {
                  const m: number = hhmmToMin(v);
                  if (v.length === 5 && !isNaN(m)) {
                    this.editSections[idx].startMin = m;
                  }
                })
              TextInput({ text: minToHHmm(st.endMin) })
                .fontColor('#F2F5FA')
                .placeholderColor('#8B97AC')
                .caretColor('#7FA8FF')
                .layoutWeight(1)
                .fontSize(13)
                .margin({ left: 6 })
                .onChange((v: string): void => {
                  const m: number = hhmmToMin(v);
                  if (v.length === 5 && !isNaN(m)) {
                    this.editSections[idx].endMin = m;
                  }
                })
              Toggle({ type: ToggleType.Switch, isOn: st.flexible })
                .width(48)
                .margin({ left: 6 })
                .onChange((on: boolean): void => {
                  this.editSections[idx].flexible = on;
                })
              Text('删')
                .fontSize(12)
                .fontColor('#FF8080')
                .width(24)
                .textAlign(TextAlign.Center)
                .onClick((): void => this.removeSection(idx))
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
          }, (st: SectionTime) =>
              `sec-${st.section}-${st.startMin}-${st.endMin}-${st.flexible}`)

          Row() {
            Button('+ 加一节')
              .backgroundColor('rgba(255,255,255,0.14)')
              .fontColor('#7FA8FF')
              .layoutWeight(1)
              .onClick((): void => this.addSection())
            Button('恢复北大默认 12 节')
              .backgroundColor('rgba(255,255,255,0.14)')
              .fontColor('#C3CDDE')
              .layoutWeight(1)
              .margin({ left: 10 })
              .onClick((): void => {
                this.editSections = PKU_SECTION_TIMES.slice(0);
              })
          }
          .width('100%')
          .margin({ top: 16 })

          Button('保存节次时间')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .width('100%')
            .margin({ top: 12 })
            .onClick((): void => this.saveSections())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  RuleDialog() {
    Column() {
      Column() {
        Text(this.ruleDraft.id === 0 ? '添加上课时段' : '编辑上课时段')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')

        this.FieldLabel('星期')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([1, 2, 3, 4, 5, 6, 7], (wd: number) => {
            ChipButton({
              text: `周${WEEKDAY_CN[wd - 1]}`,
              selected: this.ruleDraft.weekday === wd,
              onTap: (): void => {
              this.ruleDraft.weekday = wd;
            }
            })
          }, (wd: number) => `rw-${wd}`)
        }
        .width('100%')

        this.FieldLabel('开始节次')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], (s: number) => {
            ChipButton({
              text: `${s}`,
              selected: this.ruleDraft.startSection === s,
              onTap: (): void => {
              this.ruleDraft.startSection = s;
              if (this.ruleDraft.endSection < s) {
                this.ruleDraft.endSection = s;
              }
            }
            })
          }, (s: number) => `rs-${s}`)
        }
        .width('100%')

        this.FieldLabel('结束节次')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], (s: number) => {
            ChipButton({
              text: `${s}`,
              selected: this.ruleDraft.endSection === s,
              onTap: (): void => {
              this.ruleDraft.endSection = s < this.ruleDraft.startSection
                ? this.ruleDraft.startSection : s;
            }
            })
          }, (s: number) => `re-${s}`)
        }
        .width('100%')

        this.FieldLabel('周次（支持 1-16 / 1-8,10-16 / 1-16单 / 2-16双）')
        TextInput({ text: this.ruleWeeksText, placeholder: '1-16' })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .onChange((v: string): void => {
            this.ruleWeeksText = v;
          })

        Row() {
          Column() {
            Text('这是习题课')
              .fontSize(14)
              .fontColor('#F2F5FA')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.ruleDraft.isQuiz })
            .onChange((on: boolean): void => {
              this.ruleDraft.isQuiz = on;
            })
        }
        .width('100%')
        .margin({ top: 14 })

        Row() {
          Button('取消')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .layoutWeight(1)
            .onClick((): void => {
              this.ruleDialog = false;
            })
          Button('保存')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.saveRule())
        }
        .width('100%')
        .margin({ top: 18 })
      }
      .width('100%')
      .padding(18)
      .glassSheet()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  TemplateDialog() {
    Column() {
      Column() {
        Text(this.tplDraft.id === 0 ? '添加生成模板' : '编辑生成模板')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')

        this.FieldLabel('标题模板')
        TextInput({ text: this.tplDraft.titleTemplate, placeholder: '%D作业',
          controller: this.tplInputCtl })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          // 只记录用户的光标位置；插入后的光标由 insertTemplateVar 用控制器挪
          .onTextSelectionChange((start: number, end: number): void => {
            this.tplCaret = start;
          })
          .onChange((v: string): void => {
            this.tplDraft.titleTemplate = v;
          })

        // 快捷插入：不用记 %C/%D 这些记号，点一下插到光标处
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(TEMPLATE_VARS, (v: string) => {
            ChipButton({
              text: this.templateVarLabel(v),
              selected: false,
              fontSize: 11,
              onTap: (): void => this.insertTemplateVar(v)
            })
          }, (v: string) => `tv-${v}`)
          ChipButton({
            text: '清空',
            selected: false,
            fontSize: 11,
            onTap: (): void => {
              this.tplDraft.titleTemplate = '';
              this.tplCaret = 0;
            }
          })
        }
        .width('100%')
        .margin({ top: 6 })

        // 实时预览：光看变量说明猜不出最后长什么样
        Text(this.templatePreviewText())
          .fontSize(11)
          .fontColor(this.templateCheck().ok ? '#7BD69A' : '#FF8A8A')
          .width('100%')
          .margin({ top: 6 })

        this.FieldLabel('截止时间规则')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(DD_RULES, (rule: string, idx: number) => {
            ChipButton({
              text: DD_LABELS[idx],
              selected: this.tplDraft.ddlRule === rule,
              onTap: (): void => {
              this.tplDraft.ddlRule = rule;
            }
            })
          }, (rule: string) => `dd-${rule}`)
        }
        .width('100%')

        if (this.tplDraft.ddlRule === 'weekday') {
          this.FieldLabel('星期几')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach([1, 2, 3, 4, 5, 6, 7], (wd: number) => {
              ChipButton({
                text: `周${WEEKDAY_CN[wd - 1]}`,
                selected: this.tplDraft.ddlParam === `${wd}`,
                onTap: (): void => {
                this.tplDraft.ddlParam = `${wd}`;
              }
              })
            }, (wd: number) => `dw-${wd}`)
          }
          .width('100%')
        }

        if (this.tplDraft.ddlRule === 'days') {
          this.FieldLabel('几天后')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach([1, 2, 3, 5, 7, 14], (n: number) => {
              ChipButton({
                text: `${n} 天`,
                selected: this.tplDraft.ddlParam === `${n}`,
                onTap: (): void => {
                this.tplDraft.ddlParam = `${n}`;
              }
              })
            }, (n: number) => `dn-${n}`)
          }
          .width('100%')
        }

        this.FieldLabel('预计耗时（排计划时用来算块长）')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([30, 45, 60, 90, 120, 180], (m: number) => {
            ChipButton({
              text: `${m} 分钟`,
              selected: this.tplDraft.estimateMin === m,
              onTap: (): void => {
              this.tplDraft.estimateMin = m;
            }
            })
          }, (m: number) => `dm-${m}`)
        }
        .width('100%')

        Row() {
          Button('取消')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .layoutWeight(1)
            .onClick((): void => {
              this.tplDialog = false;
            })
          Button('保存')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.saveTemplate())
        }
        .width('100%')
        .margin({ top: 18 })
      }
      .width('100%')
      .padding(18)
      .glassSheet()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      if (this.loading) {
        Column() {
          Text('正在载入…')
            .fontSize(13)
            .fontColor('#94A0B5')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.mode === 'course') {
        this.CourseView()
      } else if (this.mode === 'semester') {
        this.SemesterView()
      } else if (this.mode === 'sections') {
        this.SectionsView()
      } else if (this.mode === 'backup') {
        this.BackupView()
      } else {
        this.ListView()
      }

      // ⚠️ 这两个遮罩**原来没有 onClick** —— 点窗外的深色区域毫无反应，
      // 而同一个文件之外的其它弹窗（待办页、计划页、课表页那几个）都是点了就关。
      // 用户明确要求「点击窗口外的深黑色区域应当起到（不保存）退出的效果」。
      // 这里只关窗、不落库：草稿还留在 ruleDraft / tplDraft 里，下次打开会被重新覆盖。
      if (this.ruleDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.ruleDialog = false;
          })
        this.RuleDialog()
      }
      if (this.tplDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.tplDialog = false;
          })
        this.TemplateDialog()
      }
    }
    .width('100%')
    .height('100%')
    // 底色交给 PageBackground（玻璃要有东西可透）
    .backgroundColor(Color.Transparent)
  }
}
