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
import { GLASS_BLUR, GLASS_EDGE_SOFT, GLASS_EDGE_STRONG, GLASS_RADIUS, GLASS_SHADOW_ROW,
  GLASS_SHADOW_SHEET, GLASS_TINT_ROW, GLASS_TINT_SHEET } from './Glass';
import { DRAWER_W, FLOAT_GAP, FLOAT_SIDE, H_ACTIONS } from './Float';
import { DUR_DRAWER, DUR_ITEM, DUR_SHARD, curveOrLinear, drawerCurve, dur, isMotionOn,
  motionCurve } from './Motion';

// 文件内 @Styles（Glass.ets 顶部说明了为什么不能跨文件 export）
// 深色版：模糊只留给"大面"（编辑窗），列表卡退化成半透明纯色（性能取舍）
@Styles
function glassCard() {
  .backgroundColor(GLASS_TINT_ROW)
  .border({ width: 1, color: GLASS_EDGE_SOFT })
  .borderRadius(GLASS_RADIUS)
  .shadow(GLASS_SHADOW_ROW)
}

@Styles
function glassShell() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_SHEET)
  .borderRadius(GLASS_RADIUS)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
  .shadow(GLASS_SHADOW_SHEET)
}

/** 浮窗（页头/导航栏/日期栏这类"大面"）：模糊 + 大圆角 + 浮起阴影 */
@Styles
function glassSheet() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_SHEET)
  .borderRadius(GLASS_RADIUS)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
  .shadow(GLASS_SHADOW_SHEET)
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/**
 * "碎裂掉出"的碎片参数：4 块，各飞一个方向。
 * dx/dy 是相对原位的位移（vp），rot 是旋转角。刻意做成**不对称** ——
 * 对称飞出去看起来像"开花"，不像"碎"。
 */
const SHARD_DX: number[] = [-30, 34, -20, 26];
const SHARD_DY: number[] = [-22, -10, 30, 22];
const SHARD_ROT: number[] = [-46, 38, 28, -34];

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
  /** 上方悬浮浮窗（页头）占掉的高度，由 Index 量好传进来 */
  @Prop topInset: number = 0;
  /** 下方悬浮浮窗（导航栏）占掉的高度，由 Index 量好传进来 */
  @Prop bottomInset: number = 0;
  /** 底部那条行动按钮浮窗量出来的高度 */
  @State actionsH: number = H_ACTIONS;
  /** 编辑窗开着时通知 Index（它要把悬浮浮窗层改画到内容层之下，见 Index.pageModalOpen） */
  onModalChange: (open: boolean) => void = (): void => {};
  /** 正在"碎裂掉出"的那一条（0 = 没有）：先播碎片飞散，播完再真删 */
  @State shatterId: number = 0;
  /** 碎片是否已经飞出去（驱动碎片自身与卡片本体的位移/透明） */
  @State shatterFly: boolean = false;

  @State pendingList: Todo[] = [];
  @State activeList: Todo[] = [];
  @State courses: Course[] = [];
  @State loading: boolean = true;

  /**
   * 编辑窗是否开着。
   * ⚠️ `@Watch` 是必须的：开窗时要通知 Index 把悬浮浮窗层画到内容层之下，
   * 否则页头/导航栏会盖住编辑窗（用户实测反馈，见 `Index.pageModalOpen`）。
   */
  @State @Watch('onEditorChanged') editorVisible: boolean = false;
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
    // 组件销毁（切标签）时窗也跟着没了，别把"有浮层"的状态留给 Index
    this.onModalChange(false);
  }

  /** 编辑窗开/关 → 通知 Index 调整浮窗层的位置（见 Index.pageModalOpen） */
  private onEditorChanged(): void {
    this.onModalChange(this.editorVisible);
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
      return '#C7D3E4';
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
    // 先在内存里摘掉（带动画），再落库 + reload 校准：这样"确认/完成"是滑走的，
    // 不是"啪"地消失。动画关掉时 animateTo 的时长是 0，等于直接动。
    this.getUIContext().animateTo(
      { duration: dur(DUR_ITEM), curve: curveOrLinear(motionCurve) },
      (): void => { this.optimisticRemove(id); });
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

  /**
   * 删掉自动生成的待办 → 记进黑名单，以后不再生成。
   *
   * ★ 用户要的"删除时碎裂掉出"就在这里：**先播动画、播完再真删**。
   *   顺序很讲究：
   *     ① 标记这一条正在碎（挂出 4 块碎片）
   *     ② 下一帧开始动画（卡片本体缩掉淡出、碎片飞散旋转）
   *     ③ 动画结束时，在 `animateTo` **里面同步**把它从内存列表里摘掉 ——
   *        这样上下两条的位移也是动画过去的，不会"啪"地跳一下
   *     ④ 最后才落库（异步）并 reload 校准
   *   动画关掉时跳过 ①②③，直接删。
   */
  private removeConfirmed(t: Todo): void {
    if (!isMotionOn()) {
      this.doRemove(t).catch((e: Object): void => {
        hilog.error(DOMAIN, TAG, 'todo remove failed: %{public}s', JSON.stringify(e));
      });
      return;
    }
    this.shatterId = t.id;
    this.shatterFly = false;
    // ② 先渲染一帧"没碎"的样子，再动画过去（否则会直接跳到终点）
    setTimeout((): void => {
      this.getUIContext().animateTo(
        { duration: dur(DUR_SHARD), curve: curveOrLinear(motionCurve) },
        (): void => { this.shatterFly = true; });
    }, 16);
    // ③④ 碎片飞完：带动画地把这条从列表里摘掉，然后落库
    setTimeout((): void => {
      this.shatterId = 0;
      this.shatterFly = false;
      this.getUIContext().animateTo(
        { duration: dur(DUR_ITEM), curve: curveOrLinear(motionCurve) },
        (): void => { this.optimisticRemove(t.id); });
      this.doRemove(t).catch((e: Object): void => {
        hilog.error(DOMAIN, TAG, 'todo remove failed: %{public}s', JSON.stringify(e));
      });
    }, dur(DUR_SHARD) + 16);
  }

  /** 先从内存列表里摘掉（带动画），库里随后再删/再 reload 校准 */
  private optimisticRemove(id: number): void {
    this.pendingList = this.pendingList.filter((x: Todo) => x.id !== id);
    this.activeList = this.activeList.filter((x: Todo) => x.id !== id);
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
      .backgroundColor('rgba(255,255,255,0.10)')
      .margin({ left: 6 })
      .onClick(onTap)
  }

  @Builder
  PendingCard(t: Todo) {
    Stack() {
    Column() {
      Row() {
        if (t.courseId > 0) {
          Text(this.courseLabel(t.courseId))
            .fontSize(11)
            .fontColor('#EAF0FA')
            .backgroundColor(this.courseColor(t.courseId))
            .borderRadius(4)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .margin({ right: 6 })
        }
        Text(t.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
          .layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text(this.ddlText(t.ddl))
          .fontSize(12)
          .fontColor('#9BA7BD')
          .layoutWeight(1)
        if (this.pendingDeleteId === t.id) {
          this.SmallButton('确认删除', '#FF8080', (): void => this.removeConfirmed(t))
          this.SmallButton('取消', '#A9B5C9', (): void => {
            this.pendingDeleteId = 0;
          })
        } else {
          this.SmallButton('删除', '#FF8080', (): void => {
            this.pendingDeleteId = t.id;
          })
          this.SmallButton('编辑', '#A9B5C9', (): void => this.openEdit(t))
          this.SmallButton('确认', '#7FA8FF', (): void => this.confirm(t))
        }
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(12)
    .glassCard()
    .border({ width: 1, color: 'rgba(255,255,255,0.14)' })
    // 碎裂时本体缩掉淡出（碎片在外面飞）
    .opacity(this.shatterId === t.id && this.shatterFly ? 0 : 1)
    .scale({
      x: this.shatterId === t.id && this.shatterFly ? 0.86 : 1,
      y: this.shatterId === t.id && this.shatterFly ? 0.86 : 1
    })

    // 碎片：只在"这一条正在碎"的时候挂出来，飞完就连节点一起没了
    if (this.shatterId === t.id) {
      ForEach([0, 1, 2, 3], (i: number) => {
        Column()
          .width(16)
          .height(16)
          .borderRadius(4)
          .backgroundColor(i % 2 === 0 ? 'rgba(255,255,255,0.30)' : 'rgba(127,168,255,0.55)')
          .position({ x: 26 + i * 56, y: 22 + (i % 2) * 34 })
          .translate({
            x: this.shatterFly ? SHARD_DX[i] : 0,
            y: this.shatterFly ? SHARD_DY[i] : 0
          })
          .rotate({ angle: this.shatterFly ? SHARD_ROT[i] : 0 })
          .opacity(this.shatterFly ? 0 : 1)
          .hitTestBehavior(HitTestMode.None)
      }, (i: number) => `shard-${t.id}-${i}`)
    }
    }
    .width('100%')
    // 出现/消失都走同一套过渡（新条滑下来、被移走的滑走）
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: -10 }))
      .animation({ duration: dur(DUR_ITEM), curve: curveOrLinear(motionCurve) }))
    .margin({ bottom: 8 })
  }

  @Builder
  ActiveRow(t: Todo) {
    Row() {
      Text('○')
        .fontSize(18)
        .fontColor('#DCE4F0')
        .margin({ right: 10 })
        .onClick((): void => this.complete(t))
      Column() {
        Row() {
          if (t.courseId > 0) {
            Text(this.courseLabel(t.courseId))
              .fontSize(10)
              .fontColor('#EAF0FA')
              .backgroundColor(this.courseColor(t.courseId))
              .borderRadius(3)
              .padding({ left: 4, right: 4 })
              .margin({ right: 6 })
          }
          Text(t.title)
            .fontSize(15)
            .fontColor('#F2F5FA')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        Text(`${this.ddlText(t.ddl)} · 预计 ${t.estimateMin} 分钟`)
          .fontSize(11)
          .fontColor('#94A0B5')
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
              .fontColor('#EAF0FA')
              .backgroundColor(this.courseColor(t.courseId))
              .borderRadius(3)
              .padding({ left: 4, right: 4 })
              .margin({ right: 6 })
          }
          Text(t.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        Text(`${this.examWhen(t)}${t.note.length > 0 ? ' · ' + t.note : ''}`)
          .fontSize(11)
          .fontColor('#94A0B5')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column() {
        Text(this.countdownOf(t))
          .fontSize(12)
          .fontColor('#FF8A8A')
        Text('考完了')
          .fontSize(11)
          .fontColor('#7FA8FF')
          .margin({ top: 6 })
          .onClick((): void => this.complete(t))
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('rgba(214,69,69,0.12)')
    .borderRadius(10)
    .border({ width: 1, color: 'rgba(214,69,69,0.30)' })
    .margin({ bottom: 8 })
    .onClick((): void => this.openEdit(t))
  }

  @Builder
  EditorPanel() {
    Row() {
      // 左侧留白：既是"底下还有一页"的暗示，也是"点外面关掉"的区域
      Blank()
      Column() {
        // 抽屉头：标题固定不滚；右侧 ✕ = 关掉（底部那个「保存」也还在）
        Row() {
          Text(this.editId === 0 ? '新建待办' : '编辑待办')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
            .layoutWeight(1)
          Text('✕')
            .fontSize(14)
            .fontColor('#A9B5C9')
            .padding({ left: 12, bottom: 4 })
            .onClick((): void => {
              this.editorVisible = false;
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        // ⚠️ 内容一长（考试类、或表单被撑高）必须能滚：抽屉高度是**固定**的，
        // 超出时在这里滚，不能再像原来那样既没上限也没滚动、直接被裁掉。
        Scroll() {
          Column() {

        TextInput({ text: this.editTitle, placeholder: '例如：数学作业 P12 第 3-5 题' })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .margin({ top: 14 })
          .onChange((v: string): void => {
            this.editTitle = v;
          })

        Text('类型')
          .fontSize(12)
          .fontColor('#94A0B5')
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
            .fontColor('#94A0B5')
            .width('100%')
            .margin({ top: 6, bottom: 6 })
          TextInput({ text: this.editPlace, placeholder: '教学楼 101 · 12 号座' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.editPlace = v;
            })
        }

        Text(this.editCategory === TodoCategory.Exam ? '考试时间' : '截止')
          .fontSize(12)
          .fontColor('#94A0B5')
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
            .fontColor('#94A0B5')
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
                .fontColor('#F2F5FA')
                .placeholderColor('#8B97AC')
                .caretColor('#7FA8FF')
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
                .fontColor('#94A0B5')
                .margin({ left: 8 })
            }
            .width('100%')
            .margin({ top: 2, bottom: 6 })

            Text(this.editEstimateError.length > 0
              ? this.editEstimateError
              : `${CUSTOM_ESTIMATE_MIN}–${CUSTOM_ESTIMATE_MAX} 分钟，且必须是 5 分钟的整数倍`)
              .fontSize(10)
              .fontColor(this.editEstimateError.length > 0 ? '#FF8A8A' : '#8B97AC')
              .width('100%')
          }
        }

        if (this.courses.length > 0) {
          Text('所属课程')
            .fontSize(12)
            .fontColor('#94A0B5')
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
            }, (c: Course) =>
            // 选中态靠 key 里的 selected 变化才能重画（§12.4 第 4 条）
            `c-${c.id}-${c.name}-${c.shortName}-${this.editCourseId === c.id}`)
          }
          .width('100%')
        }

        Row() {
          Button('取消')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
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
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
      .width(DRAWER_W)
      .height('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 14 })
      .glassShell()
      // 从右侧滑入/滑出（和计划页的抽屉同一套时长与曲线）
      .transition(TransitionEffect.translate({ x: '100%' })
        .animation({ duration: dur(DUR_DRAWER), curve: curveOrLinear(drawerCurve) }))
    }
    .width('100%')
    .height('100%')
    .padding({ right: FLOAT_SIDE, top: 10, bottom: 10 })
  }

  build() {
    Stack() {
      Column() {
        if (this.loading) {
          Column() {
            Text('正在载入待办…')
              .fontSize(13)
              .fontColor('#94A0B5')
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
                    .fontColor('#F2F5FA')
                  Text(`${this.pendingList.length} 条`)
                    .fontSize(12)
                    .fontColor('#7FA8FF')
                    .margin({ left: 6 })
                  Blank()
                  Text('下课自动生成，确认后才生效')
                    .fontSize(11)
                    .fontColor('#8B97AC')
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
                    .fontColor('#F2F5FA')
                  Text(`${this.examList().length} 场`)
                    .fontSize(12)
                    .fontColor('#FF8A8A')
                    .margin({ left: 6 })
                  Blank()
                  Text('点一下可改考场')
                    .fontSize(11)
                    .fontColor('#8B97AC')
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
                  .fontColor('#F2F5FA')
                Text(`${this.taskList().length} 条`)
                  .fontSize(12)
                  .fontColor('#94A0B5')
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
                  .fontColor('#8B97AC')
                  .width('100%')
                  .padding({ top: 10, bottom: 10 })
              }
              ForEach(this.taskList(), (t: Todo) => {
                this.ActiveRow(t)
              }, (t: Todo) => this.todoKey('a', t))
            }
            .width('100%')
            // 上下都给悬浮浮窗让位：上面是页头，下面是「行动按钮 + 导航栏」两条。
            // ⚠️ padding 加在**滚动内容**上而不是视口上，列表才能滑到浮窗下面
            // （见 view/Float.ets 的文件头注释）。
            .padding({
              left: 16, right: 16, top: 12 + this.topInset + FLOAT_GAP,
              bottom: 20 + this.bottomInset + this.actionsH + FLOAT_GAP
            })
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)
        }
      }
      .width('100%')
      .height('100%')

      // 底部浮窗：行动按钮（浮在悬浮导航栏之上）
      if (!this.loading) {
        Column() {
          Row() {
            Button('+ 新建待办')
              .backgroundColor('#2E6BE6')
              .fontColor('#FFFFFF')
              .layoutWeight(2)
              .onClick((): void => this.openNew())
            Button('+ 考试')
              .backgroundColor('rgba(178,107,0,0.20)')
              .fontColor('#E8B25C')
              .layoutWeight(1)
              .margin({ left: 8 })
              .onClick((): void => this.openNewExam())
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .glassSheet()
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const h: Length | undefined = newArea.height;
            if (typeof h === 'number' && h > 0) {
              this.actionsH = h;
            }
          })
        }
        .width('100%')
        .height('100%')
        // 让出悬浮导航栏 + 再留一条缝：两个浮窗之间要看得见内容
        .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, bottom: this.bottomInset + FLOAT_GAP })
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.editorVisible) {
        // 遮罩（点空白关闭）：与抽屉同时长渐显
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: dur(DUR_DRAWER), curve: curveOrLinear(drawerCurve) }))
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
