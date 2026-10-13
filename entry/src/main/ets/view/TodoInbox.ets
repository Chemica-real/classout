import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, Todo, TodoCategory, TodoSource, TodoStatus } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { addDays, countdownText, formatDate, parseDate, relativeDayText, today } from '../util/DateUtil';
import { normalizeEstimate, Validation, validateEstimate } from '../domain/Validate';
import { ChipButton } from './ChipButton';
import { BackHandler, backStack } from '../util/BackStack';
import { GLASS_CARD_BLUR, GLASS_CARD_EDGE, GLASS_CARD_RADIUS, GLASS_CARD_SHADOW,
  GLASS_CARD_TINT, GLASS_PANEL_BLUR, GLASS_PANEL_EDGE, GLASS_PANEL_TINT } from './Glass';

// 文件内 @Styles（Glass.ets 顶部说明了为什么不能跨文件 export）
@Styles
function glassCard() {
  .backgroundBlurStyle(GLASS_CARD_BLUR)
  .backgroundColor(GLASS_CARD_TINT)
  .borderRadius(GLASS_CARD_RADIUS)
  .border({ width: 1, color: GLASS_CARD_EDGE })
  .shadow(GLASS_CARD_SHADOW)
}

@Styles
function glassShell() {
  .backgroundBlurStyle(GLASS_PANEL_BLUR)
  .backgroundColor(GLASS_PANEL_TINT)
  .borderRadius(16)
  .border({ width: 1, color: GLASS_PANEL_EDGE })
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/**
 * 预设的预计时长档位。选择器里排在「自定义」输入框前面。
 *
 * ⚠️ 这些档位是**快捷选择**，不是约束本身。约束在下一条：
 * 时长至少 15 分钟、必须是 5 分钟的整数倍（用户 2026-10-14 拍定），
 * 单一实现见 domain/Validate.normalizeEstimate / validateEstimate。
 */
const PRESET_ESTIMATES: number[] = [15, 30, 60, 90, 120, 180];

/** 自定义时长的合法范围（分钟）。真正的判定走 domain/Validate */
const CUSTOM_ESTIMATE_MIN: number = 15;
const CUSTOM_ESTIMATE_MAX: number = 600;

@Component
export struct TodoInbox {
  @Prop @Watch('onSemesterIdChanged') semesterId: number;

  @State pendingList: Todo[] = [];
  @State activeList: Todo[] = [];
  @State courses: Course[] = [];
  @State loading: boolean = true;

  @State editorVisible: boolean = false;
  @State editId: number = 0;
  @State editTitle: string = '';
  @State editDdl: string = '';
  @State editEstimate: number = 60;
  /** 自定义预计时长的输入状态。'' = 没有在用自定义 */
  @State editEstimateCustom: string = '';
  @State editEstimateFocus: boolean = false;
  /** 自定义时长被归一化时的说明（'' = 输入没问题）。只在失焦/提交后出现，打字中途不打断 */
  @State editEstimateError: string = '';
  @State editCourseId: number = 0;
  @State editCategory: string = TodoCategory.Other;
  /** 考试专用：考场 / 座位，存在 note 里 */
  @State editPlace: string = '';

  @State pendingDeleteId: number = 0;

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

  /** 待办页的返回顺序：先关编辑窗 → 再收掉待确认的删除 → 都不管 */
  private handleBack(): boolean {
    if (this.editorVisible) {
      this.editorVisible = false;
      return true;
    }
    if (this.pendingDeleteId > 0) {
      this.pendingDeleteId = 0;
      return true;
    }
    return false;
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
      hilog.error(DOMAIN, TAG, 'todo load failed: %{public}s', JSON.stringify(e));
      this.loading = false;
    });
  }

  /**
   * ⚠️ 为什么要 @Watch：这个组件在切走标签页时会被销毁，但「管理课程」是盖在上面的浮层
   * （`Index.showManager`），底下的『待办』标签仍然是挂载着的。在管理课程里新建学期 /
   * 切换当前学期 / 改课程之后，prop 会变，可没有 @Watch 就没人再去读库，列表和课程胶囊
   * 便一直停在旧数据 —— 用户看到的又是「要切一下页面才刷新」。
   */
  onSemesterIdChanged(): void {
    this.load();
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    if (this.semesterId === 0) {
      this.loading = false;
      return;
    }
    this.courses = await TimetableRepo.listCourses(ctx, this.semesterId);
    this.pendingList = await TodoRepo.listTodos(ctx, 'status = ?', [TodoStatus.Pending]);
    this.activeList = await TodoRepo.listTodos(ctx, 'status = ?', [TodoStatus.Active]);
    this.loading = false;
  }

  /**
   * ForEach 的 key：**必须包含所有会被渲染的字段**。
   *
   * ⚠️ 这是一个真 bug 的修复（用户实测「改了待办属性之后不刷新，必须切换页面才刷新」）：
   * 原来的 key 只有 `a-${t.id}`。`doSave()` 其实**确实**调了 `reload()`（库是立刻更新的），
   * 但 `reload()` 换掉数组之后 key 没变 → ArkUI 复用旧节点、不重渲 → 界面停在旧值上；
   * 切标签会销毁重建整个组件，于是"切一下就好了"。
   * 计划页的块 key 一直带着 startMin/endMin/done，所以那边从来没有这个病。
   *
   * 教训同 HANDOFF §6.4：只要列表项的内容会变，key 就必须跟着变。
   */
  private todoKey(prefix: string, t: Todo): string {
    return `${prefix}-${t.id}-${t.title}-${t.ddl}-${t.category}-${t.courseId}`
      + `-${t.estimateMin}-${t.status}-${t.note}`;
  }

  private courseOf(id: number): Course | undefined {
    for (const c of this.courses) {
      if (c.id === id) {
        return c;
      }
    }
    return undefined;
  }

  private courseLabel(id: number): string {
    const c: Course | undefined = this.courseOf(id);
    if (c === undefined) {
      return '';
    }
    return c.shortName.length > 0 ? c.shortName : c.name;
  }

  private courseColor(id: number): string {
    const c: Course | undefined = this.courseOf(id);
    if (c === undefined) {
      return '#9DB2C8';
    }
    return COURSE_COLORS[c.colorIndex % COURSE_COLORS.length];
  }

  // ---- 考试 ----

  private examList(): Todo[] {
    const out: Todo[] = [];
    for (const t of this.activeList) {
      if (t.category === TodoCategory.Exam) {
        out.push(t);
      }
    }
    return out;
  }

  private taskList(): Todo[] {
    const out: Todo[] = [];
    for (const t of this.activeList) {
      if (t.category !== TodoCategory.Exam) {
        out.push(t);
      }
    }
    return out;
  }

  /** '2026-10-20 09:00' → '10 月 20 日 09:00' */
  private examWhen(t: Todo): string {
    if (t.ddl.length < 16) {
      return '时间待定';
    }
    const d: Date = parseDate(t.ddl.substring(0, 10));
    return `${d.getMonth() + 1} 月 ${d.getDate()} 日 ${t.ddl.substring(11, 16)}`;
  }

  private countdownOf(t: Todo): string {
    if (t.ddl.length < 10) {
      return '';
    }
    return countdownText(parseDate(t.ddl.substring(0, 10)), today());
  }

  /** '2026-10-14 23:59' → '10/14 23:59 · 明天' */
  private ddlText(ddl: string): string {
    if (ddl.length === 0) {
      return '无截止';
    }
    const date: Date = parseDate(ddl.substring(0, 10));
    const time: string = ddl.length >= 16 ? ddl.substring(11, 16) : '';
    return `${date.getMonth() + 1}/${date.getDate()} ${time} · ${relativeDayText(date)}`;
  }

  private confirm(t: Todo): void {
    this.mutate(t.id, TodoStatus.Active);
  }

  private complete(t: Todo): void {
    this.mutate(t.id, TodoStatus.Done);
  }

  private reopen(t: Todo): void {
    this.mutate(t.id, TodoStatus.Active);
  }

  private mutate(id: number, status: string): void {
    this.doMutate(id, status).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'todo mutate failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doMutate(id: number, status: string): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const doneAt: number = status === TodoStatus.Done ? Date.now() : 0;
    await TodoRepo.setTodoStatus(ctx, id, status, doneAt);
    await this.reload();
  }

  /** 删掉自动生成的待办 → 记进黑名单，以后不再生成 */
  private removeConfirmed(t: Todo): void {
    this.doRemove(t).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'todo remove failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doRemove(t: Todo): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    if (t.source === TodoSource.Template && t.generationKey.length > 0) {
      await TodoRepo.blacklist(ctx, t.generationKey, Date.now());
    }
    await TodoRepo.deleteTodo(ctx, t.id);
    this.pendingDeleteId = 0;
    await this.reload();
  }

  /**
   * 「自定义」那个胶囊是否处于选中态：当前时长不在任何预设档位上。
   * （考试类待办的 estimateMin 是 0，不参与，见编辑面板里的 if）
   */
  private customEstimateActive(): boolean {
    return PRESET_ESTIMATES.indexOf(this.editEstimate) < 0;
  }

  /** 「自定义」胶囊的文字：选中时直接显示当前分钟数，一眼看到自己填了什么 */
  private customChipLabel(): string {
    return this.customEstimateActive() ? `${this.editEstimate} 分钟` : '自定义';
  }

  /**
   * 自定义输入框失焦/提交时归一化。
   *
   * 规则（用户 2026-10-14 拍定）：至少 15 分钟，且必须是 5 分钟的整数倍。
   * 非 5 倍数的输入**对齐到最近的 5**（27 → 25、28 → 30），越界夹紧。
   *
   * ⚠️ 对齐之后一定把结果写回输入框并给出说明 —— 悄悄改掉用户填的数字是这个项目
   * 上一版被用户抓到的 bug，宁可啰嗦一句也不能不吭声。
   */
  private commitCustomEstimate(): void {
    const raw: string = this.editEstimateCustom.trim();
    this.editEstimateFocus = false;
    if (raw.length === 0) {
      this.editEstimateError = '';
      return;
    }
    const n: number = Number.parseInt(raw, 10);
    if (Number.isNaN(n)) {
      this.editEstimateError = '时长要填一个数字';
      return;
    }
    const verdict: Validation = validateEstimate(n, false);
    const fixed: number = normalizeEstimate(n, false);
    this.editEstimate = fixed;
    this.editEstimateCustom = `${fixed}`;
    this.editEstimateError = verdict.ok ? '' : `已对齐到 ${fixed} 分钟（${verdict.message}）`;
  }

  private openNew(): void {
    this.editId = 0;
    this.editTitle = '';
    this.editDdl = `${formatDate(today())} 23:59`;
    this.editEstimate = 60;
    this.editEstimateCustom = '';
    this.editEstimateFocus = false;
    this.editCourseId = 0;
    this.editCategory = TodoCategory.Other;
    this.editPlace = '';
    this.editorVisible = true;
  }

  private openNewExam(): void {
    this.openNew();
    this.editCategory = TodoCategory.Exam;
    this.editEstimate = 0;
    this.editDdl = `${formatDate(addDays(today(), 7))} 09:00`;
  }

  private openEdit(t: Todo): void {
    this.editId = t.id;
    this.editTitle = t.title;
    this.editDdl = t.ddl;
    this.editEstimate = t.estimateMin;
    // 已有待办的时长若不落在预设档位上，就回填进自定义输入框，别让用户重填
    const preset: number[] = PRESET_ESTIMATES;
    this.editEstimateCustom = preset.indexOf(t.estimateMin) >= 0 || t.estimateMin <= 0
      ? '' : `${t.estimateMin}`;
    this.editEstimateFocus = false;
    this.editCourseId = t.courseId;
    this.editCategory = t.category;
    this.editPlace = t.category === TodoCategory.Exam ? t.note : '';
    this.editorVisible = true;
  }

  private saveEditor(): void {
    this.doSave().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'todo save failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSave(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const title: string = this.editTitle.trim().length > 0 ? this.editTitle.trim() : '未命名待办';
    if (this.editId === 0) {
      const todo: Todo = {
        id: 0,
        title: title,
        courseId: this.editCourseId,
        category: this.editCategory,
        priority: 1,
        ddl: this.editDdl,
        estimateMin: this.editCategory === TodoCategory.Exam ? 0 : this.editEstimate,
        status: TodoStatus.Active,
        source: TodoSource.Manual,
        generationKey: '',
        note: this.editCategory === TodoCategory.Exam ? this.editPlace : '',
        submitChannel: '',
        repeatRule: '',
        photos: '',
        createdAt: Date.now(),
        confirmedAt: Date.now(),
        doneAt: 0
      };
      await TodoRepo.insertTodo(ctx, todo);
    } else {
      const existing: Todo | undefined = await TodoRepo.getTodo(ctx, this.editId);
      if (existing !== undefined) {
        existing.title = title;
        existing.ddl = this.editDdl;
        existing.category = this.editCategory;
        existing.estimateMin = this.editCategory === TodoCategory.Exam ? 0 : this.editEstimate;
        existing.courseId = this.editCourseId;
        if (this.editCategory === TodoCategory.Exam) {
          existing.note = this.editPlace;
        }
        await TodoRepo.updateTodo(ctx, existing);
      }
    }
    this.editorVisible = false;
    await this.reload();
  }

  // ---------------- UI ----------------

  @Builder
  SmallButton(text: string, color: string, onTap: () => void) {
    Text(text)
      .fontSize(12)
      .fontColor(color)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(10)
      .backgroundColor('#F2F4F8')
      .margin({ left: 6 })
      .onClick(onTap)
  }

  @Builder
  PendingCard(t: Todo) {
    Column() {
      Row() {
        if (t.courseId > 0) {
          Text(this.courseLabel(t.courseId))
            .fontSize(11)
            .fontColor('#1B2430')
            .backgroundColor(this.courseColor(t.courseId))
            .borderRadius(4)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .margin({ right: 6 })
        }
        Text(t.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')
          .layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text(this.ddlText(t.ddl))
          .fontSize(12)
          .fontColor('#7A8598')
          .layoutWeight(1)
        if (this.pendingDeleteId === t.id) {
          this.SmallButton('确认删除', '#D64545', (): void => this.removeConfirmed(t))
          this.SmallButton('取消', '#5A6478', (): void => {
            this.pendingDeleteId = 0;
          })
        } else {
          this.SmallButton('删除', '#D64545', (): void => {
            this.pendingDeleteId = t.id;
          })
          this.SmallButton('编辑', '#5A6478', (): void => this.openEdit(t))
          this.SmallButton('确认', '#2E6BE6', (): void => this.confirm(t))
        }
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(12)
    .glassCard()
    .border({ width: 1, color: '#E3E8F0' })
    .margin({ bottom: 8 })
  }

  @Builder
  ActiveRow(t: Todo) {
    Row() {
      Text('○')
        .fontSize(18)
        .fontColor('#C2CBDA')
        .margin({ right: 10 })
        .onClick((): void => this.complete(t))
      Column() {
        Row() {
          if (t.courseId > 0) {
            Text(this.courseLabel(t.courseId))
              .fontSize(10)
              .fontColor('#1B2430')
              .backgroundColor(this.courseColor(t.courseId))
              .borderRadius(3)
              .padding({ left: 4, right: 4 })
              .margin({ right: 6 })
          }
          Text(t.title)
            .fontSize(15)
            .fontColor('#12161F')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        Text(`${this.ddlText(t.ddl)} · 预计 ${t.estimateMin} 分钟`)
          .fontSize(11)
          .fontColor('#8A94A6')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .glassCard()
    .margin({ bottom: 8 })
    .onClick((): void => this.openEdit(t))
  }

  @Builder
  ExamCard(t: Todo) {
    Row() {
      Column() {
        Row() {
          if (t.courseId > 0) {
            Text(this.courseLabel(t.courseId))
              .fontSize(10)
              .fontColor('#1B2430')
              .backgroundColor(this.courseColor(t.courseId))
              .borderRadius(3)
              .padding({ left: 4, right: 4 })
              .margin({ right: 6 })
          }
          Text(t.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#12161F')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        Text(`${this.examWhen(t)}${t.note.length > 0 ? ' · ' + t.note : ''}`)
          .fontSize(11)
          .fontColor('#8A94A6')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column() {
        Text(this.countdownOf(t))
          .fontSize(12)
          .fontColor('#C0392B')
        Text('考完了')
          .fontSize(11)
          .fontColor('#2E6BE6')
          .margin({ top: 6 })
          .onClick((): void => this.complete(t))
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFF8F8')
    .borderRadius(10)
    .border({ width: 1, color: '#F5D9D9' })
    .margin({ bottom: 8 })
    .onClick((): void => this.openEdit(t))
  }

  @Builder
  EditorPanel() {
    Column() {
      Column() {
        Text(this.editId === 0 ? '新建待办' : '编辑待办')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')

        TextInput({ text: this.editTitle, placeholder: '比如：课乙 P123 第 5-9 题' })
          .margin({ top: 14 })
          .onChange((v: string): void => {
            this.editTitle = v;
          })

        Text('类型')
          .fontSize(12)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ top: 14, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ChipButton({
            text: '作业',
            selected: this.editCategory === TodoCategory.Homework,
            onTap: (): void => {
            this.editCategory = TodoCategory.Homework;
          }
          })
          ChipButton({
            text: '自学',
            selected: this.editCategory === TodoCategory.Self,
            onTap: (): void => {
            this.editCategory = TodoCategory.Self;
          }
          })
          ChipButton({
            text: '考试',
            selected: this.editCategory === TodoCategory.Exam,
            onTap: (): void => {
            this.editCategory = TodoCategory.Exam;
          }
          })
          ChipButton({
            text: '其他',
            selected: this.editCategory === TodoCategory.Other,
            onTap: (): void => {
            this.editCategory = TodoCategory.Other;
          }
          })
        }
        .width('100%')

        if (this.editCategory === TodoCategory.Exam) {
          Text('考场 / 座位')
            .fontSize(12)
            .fontColor('#8A94A6')
            .width('100%')
            .margin({ top: 6, bottom: 6 })
          TextInput({ text: this.editPlace, placeholder: '教学楼407 · 12 号座' })
            .onChange((v: string): void => {
              this.editPlace = v;
            })
        }

        Text(this.editCategory === TodoCategory.Exam ? '考试时间' : '截止')
          .fontSize(12)
          .fontColor('#8A94A6')
          .margin({ top: 14, bottom: 6 })
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ChipButton({
            text: '今天 23:59',
            selected: this.editDdl === `${formatDate(today())} 23:59`,
            onTap: (): void => {
            this.editDdl = `${formatDate(today())} 23:59`;
          }
          })
          ChipButton({
            text: '明天 23:59',
            selected: this.editDdl === `${formatDate(addDays(today(), 1))} 23:59`,
            onTap: (): void => {
            this.editDdl = `${formatDate(addDays(today(), 1))} 23:59`;
          }
          })
          ChipButton({
            text: '本周日 23:59',
            selected: this.editDdl === `${formatDate(addDays(today(), 7 - (today().getDay() === 0 ? 7 : today().getDay())))} 23:59`,
            onTap: (): void => {
            const wd: number = today().getDay() === 0 ? 7 : today().getDay();
            this.editDdl = `${formatDate(addDays(today(), 7 - wd))} 23:59`;
          }
          })
          ChipButton({
            text: '3 天后 23:59',
            selected: this.editDdl === `${formatDate(addDays(today(), 3))} 23:59`,
            onTap: (): void => {
            this.editDdl = `${formatDate(addDays(today(), 3))} 23:59`;
          }
          })
          ChipButton({
            text: '无截止',
            selected: this.editDdl.length === 0,
            onTap: (): void => {
            this.editDdl = '';
          }
          })
        }
        .width('100%')

        if (this.editCategory !== TodoCategory.Exam) {
          Text('预计耗时')
            .fontSize(12)
            .fontColor('#8A94A6')
            .margin({ top: 8, bottom: 6 })
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(PRESET_ESTIMATES, (m: number) => {
              ChipButton({
                text: `${m} 分钟`,
                selected: this.editEstimate === m,
                onTap: (): void => {
                this.editEstimate = m;
                this.editEstimateCustom = '';
                this.editEstimateFocus = false;
              }
              })
            }, (m: number) => `est-${m}`)
            // 自定义：选中它才展开输入框，收起时只多占一个胶囊的位置
            ChipButton({
              text: this.customChipLabel(),
              selected: this.customEstimateActive() || this.editEstimateFocus,
              onTap: (): void => {
                this.editEstimateFocus = true;
                this.editEstimateCustom = `${this.editEstimate}`;
              }
            })
          }
          .width('100%')

          if (this.editEstimateFocus || this.customEstimateActive()) {
            Row() {
              TextInput({ text: this.editEstimateCustom, placeholder: '如 25' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string): void => {
                  this.editEstimateCustom = v;
                  // 边输边生效：否则用户填了值、焦点还在输入框里，
                  // 「自定义」胶囊和别处显示的分钟数都还是旧值，看着像没生效。
                  // 只有**已经合法**的值才即时生效：打字打一半（"2" 想打 "25"）
                  // 不能被当成 2 分钟，也不能在这里报错打断，归一化留给失焦时做。
                  const n: number = Number.parseInt(v, 10);
                  if (!Number.isNaN(n) && validateEstimate(n, false).ok) {
                    this.editEstimate = n;
                    this.editEstimateError = '';
                  }
                })
                .onSubmit((): void => this.commitCustomEstimate())
                .onBlur((): void => this.commitCustomEstimate())
              Text('分钟')
                .fontSize(12)
                .fontColor('#8A94A6')
                .margin({ left: 8 })
            }
            .width('100%')
            .margin({ top: 2, bottom: 6 })

            Text(this.editEstimateError.length > 0
              ? this.editEstimateError
              : `${CUSTOM_ESTIMATE_MIN}–${CUSTOM_ESTIMATE_MAX} 分钟，且必须是 5 分钟的整数倍`)
              .fontSize(10)
              .fontColor(this.editEstimateError.length > 0 ? '#C0392B' : '#98A2B3')
              .width('100%')
          }
        }

        if (this.courses.length > 0) {
          Text('所属课程')
            .fontSize(12)
            .fontColor('#8A94A6')
            .margin({ top: 8, bottom: 6 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ChipButton({
              text: '无',
              selected: this.editCourseId === 0,
              onTap: (): void => {
              this.editCourseId = 0;
            }
            })
            ForEach(this.courses, (c: Course) => {
              ChipButton({
                text: c.shortName.length > 0 ? c.shortName : c.name,
                selected: this.editCourseId === c.id,
                onTap: (): void => {
                  this.editCourseId = c.id;
                }
              })
            }, (c: Course) => `c-${c.id}`)
          }
          .width('100%')
        }

        Row() {
          Button('取消')
            .backgroundColor('#EEF1F6')
            .fontColor('#4A5568')
            .layoutWeight(1)
            .onClick((): void => {
              this.editorVisible = false;
            })
          Button('保存')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.saveEditor())
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('100%')
      .padding(18)
      .glassShell()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Column() {
        if (this.loading) {
          Column() {
            Text('正在载入待办…')
              .fontSize(13)
              .fontColor('#8A94A6')
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              if (this.pendingList.length > 0) {
                Row() {
                  Text('待确认')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#12161F')
                  Text(`${this.pendingList.length} 条`)
                    .fontSize(12)
                    .fontColor('#2E6BE6')
                    .margin({ left: 6 })
                  Blank()
                  Text('下课自动生成，确认后才生效')
                    .fontSize(11)
                    .fontColor('#98A2B3')
                }
                .width('100%')
                .margin({ bottom: 8 })

                ForEach(this.pendingList, (t: Todo) => {
                  this.PendingCard(t)
                }, (t: Todo) => this.todoKey('p', t))
              }

              if (this.examList().length > 0) {
                Row() {
                  Text('即将考试')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#12161F')
                  Text(`${this.examList().length} 场`)
                    .fontSize(12)
                    .fontColor('#C0392B')
                    .margin({ left: 6 })
                  Blank()
                  Text('点一下可改考场')
                    .fontSize(11)
                    .fontColor('#98A2B3')
                }
                .width('100%')
                .margin({ top: this.pendingList.length > 0 ? 14 : 0, bottom: 8 })

                ForEach(this.examList(), (t: Todo) => {
                  this.ExamCard(t)
                }, (t: Todo) => this.todoKey('x', t))
              }

              Row() {
                Text('待办')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#12161F')
                Text(`${this.taskList().length} 条`)
                  .fontSize(12)
                  .fontColor('#8A94A6')
                  .margin({ left: 6 })
              }
              .width('100%')
              .margin({
                top: this.pendingList.length > 0 || this.examList().length > 0 ? 14 : 0,
                bottom: 8
              })

              if (this.taskList().length === 0) {
                Text('暂无待办。下课之后，配了模板的课程会自动生成待办到这里。')
                  .fontSize(12)
                  .fontColor('#98A2B3')
                  .width('100%')
                  .padding({ top: 10, bottom: 10 })
              }
              ForEach(this.taskList(), (t: Todo) => {
                this.ActiveRow(t)
              }, (t: Todo) => this.todoKey('a', t))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 20 })
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)

          Row() {
            Button('+ 新建待办')
              .backgroundColor('#2E6BE6')
              .fontColor('#FFFFFF')
              .layoutWeight(2)
              .onClick((): void => this.openNew())
            Button('+ 考试')
              .backgroundColor('#FFF4E5')
              .fontColor('#B26B00')
              .layoutWeight(1)
              .margin({ left: 8 })
              .onClick((): void => this.openNewExam())
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
          // 底色交给 PageBackground
          .backgroundColor(Color.Transparent)
        }
      }
      .width('100%')
      .height('100%')

      if (this.editorVisible) {
        // 遮罩（点空白关闭）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.editorVisible = false;
          })
        // 面板是遮罩的「兄弟」而不是子节点：点面板不会冒泡到遮罩上
        this.EditorPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}
