import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, CourseSession, OverrideKind, SectionTime, Semester,
  SessionOverride, SessionRule } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { Db } from '../data/Db';
import { Seeder } from '../data/Seeder';
import { computeWeekSessions, dateOfWeekday, weekOfDate } from '../domain/Timetable';
import { generateMissedTodos, GenerationOutcome } from '../domain/TodoGenerator';
import { ReminderPlan, syncReminders } from '../domain/ReminderScheduler';
import { formatDate, minToHHmm, today, WEEKDAY_CN, weekdayOf } from '../util/DateUtil';
import { TodoInbox } from '../view/TodoInbox';
import { PlanDayView } from '../view/PlanDayView';
import { CourseManager } from '../view/CourseManager';
import { SettingsPage } from '../view/SettingsPage';
import { backStack } from '../util/BackStack';
import { GLASS_PANEL_BLUR, GLASS_PANEL_BOTTOM, GLASS_PANEL_EDGE, GLASS_PANEL_TOP,
  PageBackground } from '../view/Glass';
import { WallpaperRepo } from '../data/WallpaperRepo';

import { ChipButton } from '../view/ChipButton';

// 文件内 @Styles（Glass.ets 顶部说明了为什么不能跨文件 export）
@Styles
function glassPanel() {
  .backgroundBlurStyle(GLASS_PANEL_BLUR)
  .linearGradient({ angle: 180, colors: [[GLASS_PANEL_TOP, 0.0], [GLASS_PANEL_BOTTOM, 1.0]] })
  .border({ width: 1, color: GLASS_PANEL_EDGE })
}

@Styles
function glassSheet() {
  .backgroundBlurStyle(GLASS_PANEL_BLUR)
  .linearGradient({ angle: 180, colors: [[GLASS_PANEL_TOP, 0.0], [GLASS_PANEL_BOTTOM, 1.0]] })
  .borderRadius(16)
  .border({ width: 1, color: GLASS_PANEL_EDGE })
  .shadow({ radius: 24, color: 'rgba(28,45,90,0.18)', offsetX: 0, offsetY: 8 })
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 每节的行高（vp） */
const SECTION_H: number = 52;
/** 机动节次（第 9、12 节）的行高 */
const FLEX_SECTION_H: number = 36;

const EMPTY_SEMESTER: Semester = {
  id: 0,
  name: '未设置学期',
  startDate: '2026-09-07',
  totalWeeks: 16,
  firstDayOfWeek: 1,
  showWeekend: true
};

@Entry
@Component
struct Index {
  @State semester: Semester = EMPTY_SEMESTER;
  @State courses: Course[] = [];
  @State rules: SessionRule[] = [];
  @State overrides: SessionOverride[] = [];
  @State sectionTimes: SectionTime[] = [];
  @State week: number = 1;
  @State tab: number = 0;
  @State loading: boolean = true;
  @State statusText: string = '正在初始化…';
  @State showManager: boolean = false;

  // 单周覆盖（停课/换教室/调课/补课）
  // 这里刻意用「一组标量」而不是 CourseSession | undefined：
  // ArkTS 在 @Builder 里对可选字段做类型收窄很别扭，拆开就不用跟它斗。
  @State sessionSheet: boolean = false;
  @State selCourseId: number = 0;
  @State selCourseName: string = '';
  @State selOriginDate: string = '';
  @State selDate: string = '';
  @State selWeekday: number = 1;
  @State selStart: number = 1;
  @State selEnd: number = 2;
  @State selLocation: string = '';
  @State selTeacher: string = '';
  @State selIsQuiz: boolean = false;
  @State selAdjusted: boolean = false;
  @State roomDraft: string = '';
  @State moveWeekday: number = 1;
  @State moveStart: number = 1;
  @State moveEnd: number = 2;
  @State adjustSheet: boolean = false;
  @State extraSheet: boolean = false;
  @State extraCourseId: number = 0;
  @State extraWeekday: number = 1;
  @State extraStart: number = 1;
  @State extraEnd: number = 2;

  private weekSessions: CourseSession[] = [];
  private readonly days: number[] = [1, 2, 3, 4, 5, 6, 7];

  /**
   * 系统返回：手势导航的左右边缘内滑、或三键导航的返回键，都会走这里。
   *
   * 顺序：**先问子组件**（它们最清楚自己开着什么：计划页的编辑窗、待办页的编辑窗、
   * 管理课程的弹窗与子页），再处理 Index 自己的三个 sheet 与「管理课程」浮层，
   * 都没有可关的才返回 false，交回系统（回桌面）。
   *
   * ⚠️ 这就是"支持鸿蒙手势导航"的实质：没有它，开着编辑窗时边缘内滑会把 App 切走，
   * 而不是关掉那一层。ArkUI 的 `onBackPress` 只能写在 `@Entry` 上，所以集中在这里，
   * 子组件通过 `util/BackStack` 注册各自的处理器。
   */
  onBackPress(): boolean {
    if (backStack.handleBack()) {
      return true;   // 子组件已经处理掉了
    }
    if (this.sessionSheet) {
      this.sessionSheet = false;
      return true;
    }
    if (this.adjustSheet) {
      this.adjustSheet = false;
      return true;
    }
    if (this.extraSheet) {
      this.extraSheet = false;
      return true;
    }
    if (this.showManager) {
      this.showManager = false;
      this.refresh();
      return true;
    }
    return false;   // 交给系统
  }

  aboutToAppear(): void {
    this.bootstrap();
  }

  private bootstrap(): void {
    this.init().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(e));
      this.statusText = `初始化失败：${JSON.stringify(e)}`;
      this.loading = false;
    });
  }

  private context(): common.UIAbilityContext {
    // 先用 EntryAbility 存好的那份；只有极端情况才回退到已废弃的 getContext()
    const stored: common.UIAbilityContext | undefined = storedAbilityContext();
    if (stored !== undefined) {
      return stored;
    }
    return getContext(this) as common.UIAbilityContext;
  }

  private async init(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    // 冷启动恢复自定义背景（没有就用渐变兜底）。AppStorage 是内存态，所以每次启动都要读回来；
    // 设置页选完图会直接写 AppStorage，PageBackground 靠 @StorageLink 立刻跟着换。
    AppStorage.setOrCreate('wallpaper', await WallpaperRepo.load(ctx));
    const sem: Semester = await Seeder.ensureSemester(ctx);
    this.semester = sem;
    await Seeder.ensureRestWindows(ctx);
    const migrated: number = await Seeder.migrateData(ctx);
    if (migrated > 0) {
      hilog.info(DOMAIN, TAG, 'migrated %{public}d todo estimates to 5-min grid', migrated);
    }
    const has: boolean = await Seeder.hasCourses(ctx, sem.id);
    if (!has) {
      this.statusText = '首次启动：正在写入课表种子数据…';
      await Seeder.seedCourses(ctx, sem.id);
    }
    this.statusText = '正在排课…';
    const now: Date = today();
    const w: number = weekOfDate(sem, now);
    this.week = w < 1 ? 1 : (w > sem.totalWeeks ? sem.totalWeeks : w);
    await this.reloadData();
    this.statusText = '正在补生成下课待办…';
    const outcome: GenerationOutcome = await generateMissedTodos(ctx, sem);
    if (outcome.created > 0) {
      hilog.info(DOMAIN, TAG, 'backfilled %{public}d todos', outcome.created);
    }
    this.statusText = '正在重排提醒…';
    const plan: ReminderPlan = await syncReminders(ctx, sem);
    hilog.info(DOMAIN, TAG, 'reminder plan: %{public}s', JSON.stringify(plan));
    await this.writeRunReport(ctx, sem, outcome, plan, migrated);
    this.loading = false;
  }

  private async reloadData(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    if (this.semester.id === 0) {
      return;
    }
    this.courses = await TimetableRepo.listCourses(ctx, this.semester.id);
    this.rules = await TimetableRepo.listRules(ctx, this.semester.id);
    this.sectionTimes = await TimetableRepo.listSectionTimes(ctx, this.semester.id);
    const from: string = formatDate(dateOfWeekday(this.semester, this.week, 1));
    const to: string = formatDate(dateOfWeekday(this.semester, this.week, 7));
    this.overrides = await TimetableRepo.listOverridesBetween(ctx, from, to);
    this.weekSessions = computeWeekSessions(this.semester, this.courses, this.rules,
      this.overrides, this.sectionTimes, this.week);
  }

  private refresh(): void {
    this.reloadData().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'reload failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 把这次启动的关键结果记下来，供「备份与恢复 → 诊断信息」显示。
   *
   * 为什么值得记：真机出问题时这是最省事的一条信息通道 ——
   * 用户不用连电脑、不用抓日志，打开设置页截图就能看到初始化每一步到底成没成
   * （种子写没写进去、补生成几条、提醒发布了几条、有没有超预算）。
   */
  private async writeRunReport(ctx: common.UIAbilityContext, sem: Semester,
    outcome: GenerationOutcome, plan: ReminderPlan, migratedCount: number): Promise<void> {
    try {
      const nowD: Date = new Date();
      const stamp: string = `${formatDate(today())} ${minToHHmm(nowD.getHours() * 60 + nowD.getMinutes())}`;
      const lines: string[] = [];
      lines.push(`启动时间: ${stamp}`);
      lines.push(`学期: ${sem.name} 起 ${sem.startDate} 共 ${sem.totalWeeks} 周 (id=${sem.id})`);
      lines.push(`当前周: 第 ${this.week} 周`);
      lines.push(`课程 ${this.courses.length} · 时段规则 ${this.rules.length} · 节次 ${this.sectionTimes.length}`);
      lines.push(`本次补生成待办: ${outcome.created} 条（回看 ${outcome.scannedDays} 天）`);
      if (migratedCount > 0) {
        lines.push(`数据迁移: ${migratedCount} 条待办时长已对齐到 5 分钟刻度`);
      }
      lines.push(`通知权限: ${plan.enabled ? '已开' : '未开（提醒不会响）'}`);
      lines.push(`提醒发布: ${plan.published} 条 → 上课 ${plan.classes} / 截止 ${plan.ddl} / 计划块 ${plan.blocks} / 简报 ${plan.briefs}`);
      if (plan.calendarEvents > 0) {
        lines.push(`代理提醒不可用 → 已写入系统日历: ${plan.calendarEvents} 个事件`);
      }
      lines.push(`超预算跳过: ${plan.skippedByBudget} 条`);
      await Db.setKv(ctx, 'last_run_report', lines.join('\n'));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'writeRunReport failed: %{public}s', JSON.stringify(e));
    }
  }

  private goWeek(delta: number): void {
    const next: number = this.week + delta;
    if (next < 1 || next > this.semester.totalWeeks) {
      return;
    }
    this.week = next;
    this.refresh();
  }

  private goToday(): void {
    const w: number = weekOfDate(this.semester, today());
    const clamped: number = w < 1 ? 1 : (w > this.semester.totalWeeks ? this.semester.totalWeeks : w);
    this.week = clamped;
    this.refresh();
  }

  private sectionHeight(section: number): number {
    for (const st of this.sectionTimes) {
      if (st.section === section) {
        return st.flexible ? FLEX_SECTION_H : SECTION_H;
      }
    }
    return SECTION_H;
  }

  private sectionOffset(section: number): number {
    let y: number = 0;
    for (const st of this.sectionTimes) {
      if (st.section >= section) {
        break;
      }
      y += this.sectionHeight(st.section);
    }
    return y;
  }

  private blockHeight(s: CourseSession): number {
    let h: number = 0;
    for (let sec = s.startSection; sec <= s.endSection; sec++) {
      h += this.sectionHeight(sec);
    }
    return h - 3;
  }

  private gridHeight(): number {
    let h: number = 0;
    for (const st of this.sectionTimes) {
      h += this.sectionHeight(st.section);
    }
    return h;
  }

  private sessionsOfDay(weekday: number): CourseSession[] {
    const out: CourseSession[] = [];
    for (const s of this.weekSessions) {
      if (s.weekday === weekday) {
        out.push(s);
      }
    }
    return out;
  }

  private weekRangeText(): string {
    const a: Date = dateOfWeekday(this.semester, this.week, 1);
    const b: Date = dateOfWeekday(this.semester, this.week, 7);
    return `${a.getMonth() + 1}/${a.getDate()} — ${b.getMonth() + 1}/${b.getDate()}`;
  }

  private isToday(weekday: number): boolean {
    return weekOfDate(this.semester, today()) === this.week && weekdayOf(today()) === weekday;
  }

  private inSemester(): boolean {
    return this.week >= 1 && this.week <= this.semester.totalWeeks;
  }

  // ---------------- 单周覆盖 ----------------

  private courseName(id: number): string {
    for (const c of this.courses) {
      if (c.id === id) {
        return c.shortName.length > 0 ? c.shortName : c.name;
      }
    }
    return '课程';
  }

  private openSession(s: CourseSession): void {
    this.selCourseId = s.course.id;
    this.selCourseName = s.course.shortName.length > 0 ? s.course.shortName : s.course.name;
    this.selOriginDate = s.originDate;
    this.selDate = s.date;
    this.selWeekday = s.weekday;
    this.selStart = s.startSection;
    this.selEnd = s.endSection;
    this.selLocation = s.location;
    this.selTeacher = s.course.teacher;
    this.selIsQuiz = s.isQuiz;
    this.selAdjusted = this.hasOverrideFor(s.course.id, s.originDate);
    this.roomDraft = s.location;
    this.moveWeekday = s.weekday;
    this.moveStart = s.startSection;
    this.moveEnd = s.endSection;
    this.sessionSheet = true;
  }

  private hasOverrideFor(courseId: number, originDate: string): boolean {
    for (const o of this.overrides) {
      if (o.courseId === courseId && o.date === originDate) {
        return true;
      }
    }
    return false;
  }

  private overrideText(o: SessionOverride): string {
    const name: string = this.courseName(o.courseId);
    if (o.kind === OverrideKind.Cancel) {
      return `${name} · ${o.date} 停课`;
    }
    if (o.kind === OverrideKind.Room) {
      return `${name} · ${o.date} 换到 ${o.newLocation}`;
    }
    if (o.kind === OverrideKind.Move) {
      return `${name} · ${o.date} 挪到 ${o.newDate} 第 ${o.newStartSection}-${o.newEndSection} 节`;
    }
    return `${name} · ${o.newDate} 补课 第 ${o.newStartSection}-${o.newEndSection} 节`;
  }

  private addOverride(o: SessionOverride): void {
    this.doAddOverride(o).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'add override failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doAddOverride(o: SessionOverride): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TimetableRepo.insertOverride(ctx, o);
    this.sessionSheet = false;
    this.extraSheet = false;
    this.refresh();
  }

  private dropOverride(o: SessionOverride): void {
    this.doDropOverride(o).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'drop override failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doDropOverride(o: SessionOverride): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TimetableRepo.deleteOverride(ctx, o.id);
    this.refresh();
  }

  /** 撤销当前这节课的全部调整 */
  private clearOverridesForSel(): void {
    this.doClearOverridesForSel().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'clear overrides failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doClearOverridesForSel(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    for (const o of this.overrides) {
      if (o.courseId === this.selCourseId && o.date === this.selOriginDate) {
        await TimetableRepo.deleteOverride(ctx, o.id);
      }
    }
    this.sessionSheet = false;
    this.refresh();
  }

  private blankOverride(courseId: number, date: string, kind: string): SessionOverride {
    return {
      id: 0,
      courseId: courseId,
      date: date,
      kind: kind,
      newDate: '',
      newStartSection: 0,
      newEndSection: 0,
      newLocation: ''
    };
  }

  private applyCancel(): void {
    this.addOverride(this.blankOverride(this.selCourseId, this.selOriginDate, OverrideKind.Cancel));
  }

  private applyRoom(): void {
    const o: SessionOverride = this.blankOverride(this.selCourseId, this.selOriginDate,
      OverrideKind.Room);
    o.newLocation = this.roomDraft.trim();
    if (o.newLocation.length === 0) {
      return;
    }
    this.addOverride(o);
  }

  private applyMove(): void {
    const o: SessionOverride = this.blankOverride(this.selCourseId, this.selOriginDate,
      OverrideKind.Move);
    o.newDate = formatDate(dateOfWeekday(this.semester, this.week, this.moveWeekday));
    o.newStartSection = this.moveStart;
    o.newEndSection = this.moveEnd < this.moveStart ? this.moveStart : this.moveEnd;
    this.addOverride(o);
  }

  private applyExtra(): void {
    if (this.extraCourseId === 0) {
      return;
    }
    const date: string = formatDate(dateOfWeekday(this.semester, this.week, this.extraWeekday));
    const o: SessionOverride = this.blankOverride(this.extraCourseId, date, OverrideKind.Extra);
    o.newDate = date;
    o.newStartSection = this.extraStart;
    o.newEndSection = this.extraEnd < this.extraStart ? this.extraStart : this.extraEnd;
    this.addOverride(o);
  }

  // ---------------- UI ----------------

  @Builder
  Header() {
    Column() {
      Row() {
        Column() {
          Text(this.semester.name)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#12161F')
          Text(this.weekRangeText())
            .fontSize(12)
            .fontColor('#8A94A6')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text('‹')
            .fontSize(22)
            .fontColor('#2E6BE6')
            .padding({ left: 10, right: 10 })
            .onClick((): void => this.goWeek(-1))
          Text(`第 ${this.week} 周`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#12161F')
          Text('›')
            .fontSize(22)
            .fontColor('#2E6BE6')
            .padding({ left: 10, right: 10 })
            .onClick((): void => this.goWeek(1))
        }
      }
      .width('100%')

      Row() {
        Text('本地生成 · 无需联网')
          .fontSize(11)
          .fontColor('#5B7A5B')
        Blank()
        Text('＋补课')
          .fontSize(12)
          .fontColor('#2E6BE6')
          .padding({ left: 8, right: 10 })
          .onClick((): void => {
            this.extraCourseId = this.courses.length > 0 ? this.courses[0].id : 0;
            this.extraSheet = true;
          })
        if (this.overrides.length > 0) {
          Text(`本周调整 ${this.overrides.length}`)
            .fontSize(12)
            .fontColor('#B26B00')
            .padding({ right: 10 })
            .onClick((): void => {
              this.adjustSheet = true;
            })
        }
        Text('管理课程')
          .fontSize(12)
          .fontColor('#2E6BE6')
          .padding({ right: 12 })
          .onClick((): void => {
            this.showManager = true;
          })
        Text(this.inSemester() ? '今天' : '回到本周')
          .fontSize(12)
          .fontColor('#2E6BE6')
          .onClick((): void => this.goToday())
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 10 })
    .glassPanel()
  }

  @Builder
  WeekdayHeader() {
    Row() {
      Column()
        .width(38)
      ForEach(this.days, (wd: number) => {
        Column() {
          Text(`周${WEEKDAY_CN[wd - 1]}`)
            .fontSize(12)
            .fontColor(this.isToday(wd) ? '#2E6BE6' : '#5A6478')
            .fontWeight(this.isToday(wd) ? FontWeight.Bold : FontWeight.Normal)
          Text(`${dateOfWeekday(this.semester, this.week, wd).getMonth() + 1}/${dateOfWeekday(this.semester, this.week, wd).getDate()}`)
            .fontSize(10)
            .fontColor(this.isToday(wd) ? '#2E6BE6' : '#98A2B3')
            .margin({ top: 1 })
        }
        .layoutWeight(1)
      }, (wd: number) => `hdr-${wd}`)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
    .glassPanel()
  }

  @Builder
  SessionBlock(s: CourseSession) {
    Column() {
      Column() {
        Text(s.course.shortName.length > 0 ? s.course.shortName : s.course.name)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1B2430')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (s.location.length > 0) {
          Text(s.location)
            .fontSize(9)
            .fontColor('#3C4657')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        if (s.course.teacher.length > 0 && this.blockHeight(s) > SECTION_H + 10) {
          Text(s.course.teacher)
            .fontSize(9)
            .fontColor('#3C4657')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 4, right: 3, top: 2, bottom: 2 })
      .backgroundColor(COURSE_COLORS[s.course.colorIndex % COURSE_COLORS.length])
      .borderRadius(6)
      .border(s.isQuiz
        ? { width: 1.5, color: '#FFFFFF', style: BorderStyle.Dashed }
        : { width: 0, color: Color.Transparent })
    }
    .width('100%')
    .height(this.blockHeight(s))
    .padding({ left: 1.5, right: 1.5 })
    .position({ y: this.sectionOffset(s.startSection) })
    .onClick((): void => this.openSession(s))
  }

  @Builder
  Grid() {
    Row() {
      // 时间轴
      Column() {
        ForEach(this.sectionTimes, (st: SectionTime) => {
          Column() {
            Text(`${st.section}`)
              .fontSize(11)
              .fontColor('#8A94A6')
            Text(minToHHmm(st.startMin))
              .fontSize(9)
              .fontColor('#B0B8C4')
          }
          .width('100%')
          .height(this.sectionHeight(st.section))
          .justifyContent(FlexAlign.Start)
          .padding({ top: 2 })
        }, (st: SectionTime) => `t-${st.section}`)
      }
      .width(38)

      // 7 天
      ForEach(this.days, (wd: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            ForEach(this.sectionTimes, (st: SectionTime) => {
              Row()
                .width('100%')
                .height(this.sectionHeight(st.section))
                .border({ width: { bottom: 1 }, color: '#EDEFF3' })
            }, (st: SectionTime) => `g-${wd}-${st.section}`)
          }
          .width('100%')

          ForEach(this.sessionsOfDay(wd), (s: CourseSession) => {
            this.SessionBlock(s)
          }, (s: CourseSession) => `s-${s.course.id}-${s.date}-${s.startSection}`)
        }
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(this.isToday(wd) ? '#F2F6FF' : Color.Transparent)
      }, (wd: number) => `col-${wd}`)    }
    .width('100%')
    .height(this.gridHeight())
    .alignItems(VerticalAlign.Top)
    .padding({ left: 4, right: 4 })
  }

  @Builder
  TabBar() {
    Row() {
      this.TabItem(0, '课表')
      this.TabItem(1, '待办')
      this.TabItem(2, '计划')
      // 用户要求：设置单独一页，放在导航栏最后一条
      this.TabItem(3, '设置')
    }
    .width('100%')
    .height(54)
    .glassPanel()
  }

  @Builder
  TabItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(this.tab === index ? '#2E6BE6' : '#8A94A6')
        .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.tab = index;
    })
  }

  @Builder
  Placeholder(title: string, hint: string) {
    Column() {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#12161F')
      Text(hint)
        .fontSize(13)
        .fontColor('#8A94A6')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SectionPicker(from: number, to: number, onPick: (sec: number) => void) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], (sec: number) => {
        ChipButton({
          text: `${sec}`,
          selected: sec >= from && sec <= to,
          onTap: (): void => onPick(sec)
        })
      }, (sec: number) => `sp-${from}-${to}-${sec}`)
    }
    .width('100%')
  }

  @Builder
  SessionSheet() {
    Column() {
      Column() {
        Text(this.selCourseName)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')
        Text(`${this.selDate} 周${WEEKDAY_CN[this.selWeekday - 1]} · 第 ${this.selStart}-${this.selEnd} 节${this.selIsQuiz ? ' · 习题课' : ''}`)
          .fontSize(12)
          .fontColor('#7A8598')
          .margin({ top: 4 })
        Text(this.selLocation.length > 0 ? this.selLocation : '地点待定')
          .fontSize(12)
          .fontColor('#7A8598')
          .margin({ top: 2 })
        if (this.selDate !== this.selOriginDate) {
          Text(`（原定 ${this.selOriginDate}，被调过）`)
            .fontSize(11)
            .fontColor('#B26B00')
            .margin({ top: 2 })
        }

        Text('换教室（只改这一周）')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 16, bottom: 6 })
        Row() {
          TextInput({ text: this.roomDraft, placeholder: '教学楼407' })
            .layoutWeight(1)
            .onChange((v: string): void => {
              this.roomDraft = v;
            })
          Button('换到这儿')
            .backgroundColor('#EEF1F6')
            .fontColor('#2E6BE6')
            .fontSize(13)
            .margin({ left: 8 })
            .onClick((): void => this.applyRoom())
        }
        .width('100%')

        Text('调到哪一天')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 14, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([1, 2, 3, 4, 5, 6, 7], (wd: number) => {
            ChipButton({
              text: `周${WEEKDAY_CN[wd - 1]}`,
              selected: this.moveWeekday === wd,
              onTap: (): void => {
              this.moveWeekday = wd;
            }
            })
          }, (wd: number) => `mw-${wd}`)
        }
        .width('100%')

        Text('起 / 止节次')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 6, bottom: 6 })
        this.SectionPicker(this.moveStart, this.moveStart, (sec: number): void => {
          this.moveStart = sec;
          if (this.moveEnd < sec) {
            this.moveEnd = sec;
          }
        })
        this.SectionPicker(this.moveEnd, this.moveEnd, (sec: number): void => {
          this.moveEnd = sec < this.moveStart ? this.moveStart : sec;
        })

        Row() {
          Button('只挪这一天')
            .backgroundColor('#EAF1FF')
            .fontColor('#2E6BE6')
            .fontSize(13)
            .layoutWeight(1)
            .onClick((): void => this.applyMove())
          Button('本周停课')
            .backgroundColor('#FDECEA')
            .fontColor('#C0392B')
            .fontSize(13)
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.applyCancel())
        }
        .width('100%')
        .margin({ top: 8 })

        if (this.selAdjusted) {
          Button('撤销这节课的调整')
            .backgroundColor('#FFF4E5')
            .fontColor('#B26B00')
            .fontSize(13)
            .width('100%')
            .margin({ top: 10 })
            .onClick((): void => this.clearOverridesForSel())
        }
        Button('关闭')
          .backgroundColor('#EEF1F6')
          .fontColor('#4A5568')
          .fontSize(13)
          .width('100%')
          .margin({ top: 10 })
          .onClick((): void => {
            this.sessionSheet = false;
          })
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
  AdjustSheet() {
    Column() {
      Column() {
        Text('本周调整')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')
        Text(`${this.semester.name} · 第 ${this.week} 周`)
          .fontSize(12)
          .fontColor('#7A8598')
          .margin({ top: 4, bottom: 12 })

        if (this.overrides.length === 0) {
          Text('本周没有调整。点课表格子里的课就能停课 / 换教室 / 调课。')
            .fontSize(12)
            .fontColor('#98A2B3')
            .width('100%')
        }

        ForEach(this.overrides, (o: SessionOverride) => {
          Row() {
            Text(this.overrideText(o))
              .fontSize(12)
              .fontColor('#4A5568')
              .layoutWeight(1)
            Text('撤销')
              .fontSize(12)
              .fontColor('#D64545')
              .padding({ left: 10, right: 4 })
              .onClick((): void => this.dropOverride(o))
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#F7F8FA')
          .borderRadius(8)
          .margin({ bottom: 6 })
        }, (o: SessionOverride) => `ov-${o.id}`)

        Button('关闭')
          .backgroundColor('#EEF1F6')
          .fontColor('#4A5568')
          .fontSize(13)
          .width('100%')
          .margin({ top: 12 })
          .onClick((): void => {
            this.adjustSheet = false;
          })
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
  ExtraSheet() {
    Column() {
      Column() {
        Text('补一节课')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')
        Text('给某一周临时加一节（调休补课就用这个）')
          .fontSize(11)
          .fontColor('#7A8598')
          .margin({ top: 4 })

        Text('哪门课')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 14, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.courses, (c: Course) => {
            ChipButton({
              text: c.shortName.length > 0 ? c.shortName : c.name,
              selected: this.extraCourseId === c.id,
              onTap: (): void => {
                this.extraCourseId = c.id;
              }
            })
          }, (c: Course) => `ec-${c.id}`)
        }
        .width('100%')

        Text('哪一天')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 6, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([1, 2, 3, 4, 5, 6, 7], (wd: number) => {
            ChipButton({
              text: `周${WEEKDAY_CN[wd - 1]}`,
              selected: this.extraWeekday === wd,
              onTap: (): void => {
              this.extraWeekday = wd;
            }
            })
          }, (wd: number) => `ew-${wd}`)
        }
        .width('100%')

        Text('起 / 止节次')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 6, bottom: 6 })
        this.SectionPicker(this.extraStart, this.extraStart, (sec: number): void => {
          this.extraStart = sec;
          if (this.extraEnd < sec) {
            this.extraEnd = sec;
          }
        })
        this.SectionPicker(this.extraEnd, this.extraEnd, (sec: number): void => {
          this.extraEnd = sec < this.extraStart ? this.extraStart : sec;
        })

        Row() {
          Button('取消')
            .backgroundColor('#EEF1F6')
            .fontColor('#4A5568')
            .fontSize(13)
            .layoutWeight(1)
            .onClick((): void => {
              this.extraSheet = false;
            })
          Button('加上这节课')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .fontSize(13)
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.applyExtra())
        }
        .width('100%')
        .margin({ top: 12 })
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
      // 玻璃态的"可透物"：铺在所有内容之下。
      // 各页面根容器都不再设不透明底色，否则会把这一层挡掉、玻璃白做。
      PageBackground()
      Column() {
        if (this.loading) {
          Column() {
            Text('ClassOUT')
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor('#12161F')
            Text(this.statusText)
              .fontSize(13)
              .fontColor('#8A94A6')
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          // 设置页不显示课表那套头部（学期名 / 第几周 / ＋补课 / 管理课程 / 今天）——
          // 那些是课表页的导航控件，摆在设置页上只会干扰
          if (this.tab !== 3) {
            this.Header()
          }
          if (this.tab === 0) {
            this.WeekdayHeader()
            Scroll() {
              this.Grid()
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .align(Alignment.TopStart)
          } else if (this.tab === 1) {
            // 包一层含 layoutWeight 的 Column：TodoInbox 自己的根节点是 height('100%')，
            // 直接放进本 Column 会占满整屏高度，把下面的 TabBar 顶出屏幕外。
            Column() {
              TodoInbox({ semesterId: this.semester.id })
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.tab === 2) {
            // 同上：PlanDayView 根节点也是 height('100%')
            Column() {
              PlanDayView({ semesterId: this.semester.id })
            }
            .width('100%')
            .layoutWeight(1)
          } else {
            // 设置页。⚠️ 原来是 else 兜底给 PlanDayView，加第 4 个标签后必须
            // 把计划页改成显式 `tab === 2`，否则「设置」会显示成计划页。
            Column() {
              SettingsPage({ semesterId: this.semester.id })
            }
            .width('100%')
            .layoutWeight(1)
          }
          this.TabBar()
        }
      }
      .width('100%')
      .height('100%')
      // 底色交给 PageBackground（见 Glass.ets）
      .backgroundColor(Color.Transparent)

      if (this.showManager) {
        // 管理课程原来**直接盖在课表上**（没有遮罩）。玻璃化的正解不是"把背景盖掉"，
        // 而是**把模糊做够**——让底下的课表变成"磨砂玻璃后面的柔和色块"：
        // **既保留背景信息（若隐若现），又不干扰前景**（这就是玻璃态说明里的第 ② 条）。
        // 所以这里是一层**较透**的薄纱 + **很厚的模糊**：
        // 薄纱太浓就变成"把背景抹掉"（那是错的），太淡则底下的字还能读（看着像渲染故障）。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(248,250,254,0.30)')
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        CourseManager({
          semesterId: this.semester.id,
          close: (): void => {
            this.showManager = false;
            this.refresh();
          }
        })
      }

      if (this.sessionSheet) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.sessionSheet = false;
          })
        this.SessionSheet()
      }

      if (this.adjustSheet) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.adjustSheet = false;
          })
        this.AdjustSheet()
      }

      if (this.extraSheet) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.extraSheet = false;
          })
        this.ExtraSheet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
