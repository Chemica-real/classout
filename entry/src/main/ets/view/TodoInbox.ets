import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, Todo, TodoCategory, TodoSource, TodoStatus } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { addDays, countdownText, formatDate, hhmmToMin, minToHHmm, parseDate, relativeDayText,
  today } from '../util/DateUtil';
import { pickDateTime } from '../util/DateTimePicker';
import { ExamRange, Validation, examRangeOf, normalizeEstimate, validateEstimate,
  validateExamRange } from '../domain/Validate';
import { CATEGORY_NAME_MAX, CategoryOption, CategoryVerdict, addCustomCategory,
  allCategoryOptions, categoryLabel, parseCustomCategories,
  validateCategoryName } from '../domain/Categories';
import { saveCustomCategories, saveNoteExpanded } from '../data/Prefs';
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
  /**
   * 「请打开这条待办」的请求（计划页的截止列表点进来的）。
   * 数据载入后执行一次，然后回调 Index 清 0（否则每次 reload 都会再开一次窗）。
   */
  @Prop openTodoId: number = 0;
  /**
   * 「请重新读库」的令牌：Index 每次切到「待办」标签时会先补生成下课待办，
   * 补生成完自增它 —— 这个组件是按 `tab` 条件渲染的，刚挂载时列表还是补生成之前的，
   * 靠这个 @Watch 再读一次库，新条目才会当场出现（用户 2026-10-16 要求）。
   */
  @Prop @Watch('onReloadRequested') reloadToken: number = 0;
  onOpenTodoConsumed: () => void = (): void => {};
  /** 编辑窗开着时通知 Index（它要把悬浮浮窗层改画到内容层之下，见 Index.pageModalOpen） */
  onModalChange: (open: boolean) => void = (): void => {};
  /** 正在"碎裂掉出"的那一条（0 = 没有）：先播碎片飞散，播完再真删 */
  @State shatterId: number = 0;
  /** 碎片是否已经飞出去（驱动碎片自身与卡片本体的位移/透明） */
  @State shatterFly: boolean = false;

  @State pendingList: Todo[] = [];
  @State activeList: Todo[] = [];
  /** 已完成的待办：放在列表最下方、加灰显示（用户要求"不要让它消失"） */
  @State doneList: Todo[] = [];
  /** 「已完成」区是否展开。默认展开 —— 用户要的就是"完成之后能看见它去哪了" */
  @State doneOpen: boolean = true;
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
  @State editCategory: string = TodoCategory.None;
  /**
   * 自定义待办类型（`'\n'` 分隔，和设置页共用一份）。
   * 在编辑窗里「＋新建类型」新建的**就是全局的**，回到设置页能看到、也能删（用户 2026-10-15）。
   */
  @StorageLink('todoCategories') catRaw: string = '';
  /** 备注区是单行输入框还是大文本框 —— 全局记忆（用户 2026-10-16） */
  @StorageLink('noteExpanded') noteExpanded: boolean = false;
  /** 「＋新建类型」展开的输入行 */
  @State catCreating: boolean = false;
  @State catDraft: string = '';
  @State catError: string = '';
  /** 备注（**所有类型都能写**）。考试时这个框的标签是「考场 / 座位」，见 EditorPanel */
  @State editNote: string = '';
  /** 考试专用：**结束**时刻（开始时刻存在 editDdl 里）；其它类型恒为 '' */
  @State editExamEnd: string = '';
  /** 考试起止不合法时的提示（'' = 没问题） */
  @State editExamError: string = '';

  @State pendingDeleteId: number = 0;
  /**
   * 编辑抽屉里的「删除待办」是否已经进入二次确认。
   *
   * 为什么要有它：确认过的待办（列表里的「待办」和「即将考试」）**原来根本没有删除入口** ——
   * 卡片点一下只开编辑窗，而编辑窗里只有取消/保存。用户实测反馈后补上这个按钮，
   * 并且**必须二次确认**（删了不可恢复，自动生成的那条还会被记进黑名单）。
   */
  @State editorConfirmDelete: boolean = false;

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

  /** 待办页的返回顺序：先收掉编辑窗里的删除确认 → 再关编辑窗 → 再收掉待确认的删除 */
  private handleBack(): boolean {
    if (this.editorVisible) {
      // 删除确认是编辑窗里更上面的一层，先收它
      if (this.editorConfirmDelete) {
        this.editorConfirmDelete = false;
        return true;
      }
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

  /** Index 补生成完下课待办 → 再读一次库 */
  onReloadRequested(): void {
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
    this.doneList = await TodoRepo.listDoneTodos(ctx);
    this.loading = false;
    // 计划页请求打开某条待办：数据到位了才找得到它
    this.openRequestedTodo();
  }

  /**
   * 处理"计划页截止列表点了一条"的请求。
   * 找不到（比如那条刚被删了）就静默放弃 —— 但**请求一样要清掉**，免得一直重试。
   */
  private openRequestedTodo(): void {
    const id: number = this.openTodoId;
    if (id <= 0) {
      return;
    }
    const t: Todo | undefined = this.findTodo(id);
    this.onOpenTodoConsumed();
    if (t !== undefined) {
      this.openEdit(t);
    }
  }

  private findTodo(id: number): Todo | undefined {
    const lists: Todo[][] = [this.pendingList, this.activeList, this.doneList];
    for (const list of lists) {
      for (const t of list) {
        if (t.id === id) {
          return t;
        }
      }
    }
    return undefined;
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
      + `-${t.estimateMin}-${t.status}-${t.note}-${t.doneAt}`;
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

  /** '2026-10-20 09:00' (+ 结束) → '10 月 20 日 09:00–11:00' */
  private examWhen(t: Todo): string {
    if (t.ddl.length < 16) {
      return '时间待定';
    }
    const d: Date = parseDate(t.ddl.substring(0, 10));
    const span: string = t.endAt.length >= 16 ? `–${t.endAt.substring(11, 16)}` : '';
    return `${d.getMonth() + 1} 月 ${d.getDate()} 日 ${t.ddl.substring(11, 16)}${span}`;
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

  /** 四个快捷胶囊对应的截止时间（顺序：今天 / 明天 / 本周日 / 3 天后，都是 23:59） */
  private presetDdls(): string[] {
    const wd: number = today().getDay() === 0 ? 7 : today().getDay();
    return [
      `${formatDate(today())} 23:59`,
      `${formatDate(addDays(today(), 1))} 23:59`,
      `${formatDate(addDays(today(), 7 - wd))} 23:59`,
      `${formatDate(addDays(today(), 3))} 23:59`
    ];
  }

  /** 当前截止时间是不是正好落在某个快捷档位上（是的话「自定义」胶囊不亮） */
  private ddlIsPreset(): boolean {
    return this.presetDdls().indexOf(this.editDdl) >= 0;
  }

  /** '2026-10-15 14:07' → '10/15 14:07'：够短，能直接当胶囊文字 */
  private ddlShort(ddl: string): string {
    if (ddl.length < 16) {
      return '自定义…';
    }
    return `${ddl.substring(5, 7)}/${ddl.substring(8, 10)} ${ddl.substring(11, 16)}`;
  }

  /** 「自定义…」：走鸿蒙的日期 + 时间选择器（分钟不受 5 分钟那套限制） */
  private pickCustomDdl(): void {
    pickDateTime(this.getUIContext(), this.editDdl, (v: string): void => {
      this.editDdl = v;
    });
  }

  /** '10/14 12:03 完成'：已完成条目上那行小字 */
  private doneAtText(t: Todo): string {
    if (t.doneAt <= 0) {
      return '已完成';
    }
    const d: Date = new Date(t.doneAt);
    return `${d.getMonth() + 1}/${d.getDate()} ${minToHHmm(d.getHours() * 60 + d.getMinutes())} 完成`;
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
    this.doneList = this.doneList.filter((x: Todo) => x.id !== id);
  }

  private async doRemove(t: Todo): Promise<void> {
    await this.deleteRecord(t);
    this.pendingDeleteId = 0;
    await this.reload();
  }

  /**
   * 真正落库删一条：自动生成的先记黑名单（以后不再生成），再删记录。
   * 列表卡片上的删除与编辑抽屉里的删除**共用这一处**，免得两条路各写一遍黑名单逻辑。
   */
  private async deleteRecord(t: Todo): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    if (t.source === TodoSource.Template && t.generationKey.length > 0) {
      await TodoRepo.blacklist(ctx, t.generationKey, Date.now());
    }
    await TodoRepo.deleteTodo(ctx, t.id);
  }

  /**
   * 编辑抽屉里的「确认删除」。
   *
   * 顺序：先关掉抽屉（连带收起二次确认），再**带动画**把这一条从内存列表里摘掉
   * （上下两条滑过去，而不是"啪"地跳一下），最后才落库 + reload 校准。
   * 不播「碎裂掉出」那套碎片动画 —— 它只画在「待确认」卡片上（`PendingCard`），
   * 而这里删的是确认过的条目，碎片没有宿主。
   */
  private deleteFromEditor(): void {
    const id: number = this.editId;
    if (id <= 0) {
      return;
    }
    this.editorConfirmDelete = false;
    this.editorVisible = false;
    this.getUIContext().animateTo(
      { duration: dur(DUR_ITEM), curve: curveOrLinear(motionCurve) },
      (): void => { this.optimisticRemove(id); });
    this.doDeleteFromEditor(id).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'todo remove failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doDeleteFromEditor(id: number): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const t: Todo | undefined = await TodoRepo.getTodo(ctx, id);
    if (t !== undefined) {
      await this.deleteRecord(t);
    }
    await this.reload();
  }

  /**
   * 列表里任意一条的「带动画删除」（已完成的条目、以及编辑抽屉走这条）。
   * 「待确认」卡片另有"碎裂掉出"，见 `removeConfirmed()`。
   */
  private deleteRow(t: Todo): void {
    this.getUIContext().animateTo(
      { duration: dur(DUR_ITEM), curve: curveOrLinear(motionCurve) },
      (): void => { this.optimisticRemove(t.id); });
    this.doRemove(t).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'todo remove failed: %{public}s', JSON.stringify(e));
    });
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
    this.editCategory = TodoCategory.None;
    this.catCreating = false;
    this.catDraft = '';
    this.catError = '';
    this.editNote = '';
    this.editExamEnd = '';
    this.editExamError = '';
    this.editorConfirmDelete = false;
    this.editorVisible = true;
  }

  /**
   * 新建考试：默认"下周同一天 09:00–11:00"。
   * 考试要的是**一段固定时间**（用户 2026-10-14 提的），所以一开始就把结束时刻填上一个整数，
   * 用户只需要改自己关心的那一边。
   */
  private openNewExam(): void {
    this.openNew();
    this.editCategory = TodoCategory.Exam;
    const day: string = formatDate(addDays(today(), 7));
    this.editDdl = `${day} 09:00`;
    this.editExamEnd = `${day} 11:00`;
    this.editEstimate = 120;
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
    this.catCreating = false;
    this.catDraft = '';
    this.catError = '';
    this.editNote = t.note;
    // 考试：回填结束时刻。老数据没有 end_at（迁移补的是空串）→ 给个"开始 +2 小时"的默认，
    // 免得用户一打开就看到"结束时间没选"、还得自己算。
    this.editExamEnd = t.category === TodoCategory.Exam ? this.endOfExam(t) : '';
    this.editExamError = '';
    this.editorConfirmDelete = false;
    this.editorVisible = true;
  }

  /** 考试的结束时刻；老数据（endAt 为空）用"开始 +2 小时"兜底，封顶 23:59 */
  private endOfExam(t: Todo): string {
    if (t.endAt.length >= 16) {
      return t.endAt;
    }
    return this.defaultExamEnd(t.ddl);
  }

  /** 由开始时刻推一个默认结束时刻（+2 小时，封顶 23:59）；开始都没填就返回空串 */
  private defaultExamEnd(start: string): string {
    if (start.length < 16) {
      return '';
    }
    const s0: number = hhmmToMin(start.substring(11, 16));
    const e0: number = s0 + 120 > 1439 ? 1439 : s0 + 120;
    return `${start.substring(0, 10)} ${minToHHmm(e0)}`;
  }

  /**
   * 切换"类型"。
   * 切到**考试**时顺手把结束时刻补上（把原来那个"截止"当开始用）—— 否则用户切过去
   * 立刻看到"开始和结束都要选"，像是自己弄坏了什么。
   */
  private chooseCategory(c: string): void {
    this.editCategory = c;
    if (c === TodoCategory.Exam && this.editExamEnd.length < 16) {
      this.editExamEnd = this.defaultExamEnd(this.editDdl);
    }
    this.editExamError = '';
  }

  // ---- 待办类型（内置 + 自定义） ----

  private customCategories(): string[] {
    return parseCustomCategories(this.catRaw);
  }

  /**
   * 编辑窗里那一排类型胶囊。
   *
   * 除了"内置四个 + 自定义"，还要**兜一条认不出的当前值**（比如备份恢复后少了类型定义，
   * 或者极老的 `'other'`）：不兜的话用户打开这条待办会看到"一个都没选中"，
   * 像是类型丢了。`categoryLabel` 给得出中文名就显示出来。
   */
  private editorCategories(): CategoryOption[] {
    const out: CategoryOption[] = allCategoryOptions(this.customCategories());
    const cur: string = this.editCategory;
    if (cur.length === 0 || cur === TodoCategory.None) {
      return out;
    }
    for (const o of out) {
      if (o.key === cur) {
        return out;
      }
    }
    const label: string = categoryLabel(cur, this.customCategories());
    if (label.length > 0) {
      out.push({ key: cur, label: label, builtin: false });
    }
    return out;
  }

  /** 卡片上的类型小标签；「无」返回空串（不画） */
  private categoryText(t: Todo): string {
    return categoryLabel(t.category, this.customCategories());
  }

  private toggleCatCreating(): void {
    this.catCreating = !this.catCreating;
    this.catDraft = '';
    this.catError = '';
  }

  /**
   * 折叠 / 展开备注输入框。状态**写进 kv 记住**（用户 2026-10-16），
   * 并且和计划页的块编辑窗共用同一个键 —— 两边永远一致。
   */
  private toggleNoteExpanded(): void {
    const next: boolean = !this.noteExpanded;
    this.noteExpanded = next;
    saveNoteExpanded(this.context(), next).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'save noteExpanded failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 在待办卡片上新建一个类型 —— **这是全局新建**：写进 kv + AppStorage，
   * 设置页那份会立刻跟着变（用户 2026-10-15 明确要求）。
   */
  private addCategoryInline(): void {
    const list: string[] = this.customCategories();
    const verdict: CategoryVerdict = validateCategoryName(this.catDraft, list);
    if (!verdict.ok) {
      this.catError = verdict.message;
      return;
    }
    const name: string = this.catDraft.trim();
    saveCustomCategories(this.context(), addCustomCategory(list, name))
      .then((clean: string[]): void => {
        this.catRaw = clean.join('\n');
        this.editCategory = name;
        this.catCreating = false;
        this.catDraft = '';
        this.catError = '';
      })
      .catch((e: Object): void => {
        this.catError = '保存失败';
        hilog.error(DOMAIN, TAG, 'add category failed: %{public}s', JSON.stringify(e));
      });
  }

  /**
   * 考试的开始/结束各自滚一次鸿蒙的日期+时间选择器。
   * 只改开始时顺手把"结束早于开始"的情况拉正（+2 小时），省掉一次来回。
   */
  private pickExamTime(isStart: boolean): void {
    const cur: string = isStart ? this.editDdl : this.editExamEnd;
    pickDateTime(this.getUIContext(), cur, (v: string): void => {
      if (isStart) {
        this.editDdl = v;
        if (!validateExamRange(this.editDdl, this.editExamEnd).ok) {
          const d: Date = parseDate(v.substring(0, 10));
          const start: number = hhmmToMin(v.substring(11, 16));
          const end: number = start + 120 > 1439 ? 1439 : start + 120;
          this.editExamEnd = `${formatDate(d)} ${minToHHmm(end)}`;
        }
      } else {
        this.editExamEnd = v;
      }
      this.editExamError = '';
    });
  }

  private saveEditor(): void {
    this.doSave().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'todo save failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSave(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const title: string = this.editTitle.trim().length > 0 ? this.editTitle.trim() : '未命名待办';
    const isExam: boolean = this.editCategory === TodoCategory.Exam;
    // 考试是"一段固定时间"，起止填不对就别存 —— 否则计划视图里那块没有可靠的长度
    let examMinutes: number = 0;
    if (isExam) {
      const verdict: Validation = validateExamRange(this.editDdl, this.editExamEnd);
      if (!verdict.ok) {
        this.editExamError = verdict.message;
        return;
      }
      this.editExamError = '';
      const r: ExamRange = examRangeOf(this.editDdl, this.editExamEnd);
      examMinutes = r.endMin - r.startMin;
    }
    if (this.editId === 0) {
      const todo: Todo = {
        id: 0,
        title: title,
        courseId: this.editCourseId,
        category: this.editCategory,
        priority: 1,
        ddl: this.editDdl,
        endAt: isExam ? this.editExamEnd : '',
        estimateMin: isExam ? examMinutes : this.editEstimate,
        status: TodoStatus.Active,
        source: TodoSource.Manual,
        generationKey: '',
        note: this.editNote,
        submitChannel: '',
        repeatRule: '',
        photos: '',
        createdAt: Date.now(),
        confirmedAt: Date.now(),
        doneAt: 0
      };
      const id: number = await TodoRepo.insertTodo(ctx, todo);
      todo.id = id;
      // 考试：自动在计划视图里排上这一段（重叠也照排，见 TodoRepo.syncExamBlock）
      await TodoRepo.syncExamBlock(ctx, todo);
    } else {
      const existing: Todo | undefined = await TodoRepo.getTodo(ctx, this.editId);
      if (existing !== undefined) {
        existing.title = title;
        existing.ddl = this.editDdl;
        existing.category = this.editCategory;
        existing.endAt = isExam ? this.editExamEnd : '';
        existing.estimateMin = isExam ? examMinutes : this.editEstimate;
        existing.courseId = this.editCourseId;
        existing.note = this.editNote;
        await TodoRepo.updateTodo(ctx, existing);
        await TodoRepo.syncExamBlock(ctx, existing);
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

  /**
   * 卡片上的**类型小标签**（用户 2026-10-15：「要：在待办卡片上显示一个小类型标签」）。
   * 用中性灰，和彩色的课程胶囊区分开；「无」不画（`categoryText` 返回空串）。
   */
  @Builder
  CategoryTag(t: Todo) {
    if (this.categoryText(t).length > 0) {
      Text(this.categoryText(t))
        .fontSize(10)
        .fontColor('#C3CDDE')
        .backgroundColor('rgba(255,255,255,0.14)')
        .borderRadius(3)
        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        .margin({ right: 6 })
    }
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
        this.CategoryTag(t)
        Text(t.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
          .layoutWeight(1)
      }
      .width('100%')

      // 备注：有才显示（自动生成的待办备注为空，见 domain/TodoGenerator）
      if (t.note.length > 0) {
        Text(t.note)
          .fontSize(11)
          .fontColor('#7C8798')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }

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
          this.CategoryTag(t)
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
        // 备注：有才显示（自动生成的待办备注为空，见 domain/TodoGenerator）
        if (t.note.length > 0) {
          Text(t.note)
            .fontSize(11)
            .fontColor('#7C8798')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
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

  /**
   * 已完成的待办：**加灰 + 划掉**，留在列表最下方而不是消失（用户要求）。
   * 两个动作：恢复成待办 / 删除（删除走二次确认，和其它删除一致）。
   */
  @Builder
  DoneRow(t: Todo) {
    Row() {
      Text('✓')
        .fontSize(16)
        .fontColor('#7C8798')
        .margin({ right: 10 })
      Column() {
        Row() {
          this.CategoryTag(t)
          Text(t.title)
            .fontSize(14)
            .fontColor('#8B97AC')
            .decoration({ type: TextDecorationType.LineThrough, color: '#7C8798' })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        Text(`${this.doneAtText(t)}${t.estimateMin > 0 ? ` · 预计 ${t.estimateMin} 分钟` : ''}`)
          .fontSize(11)
          .fontColor('#7C8798')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.pendingDeleteId === t.id) {
        this.SmallButton('确认删除', '#FF8080', (): void => this.deleteRow(t))
        this.SmallButton('取消', '#A9B5C9', (): void => {
          this.pendingDeleteId = 0;
        })
      } else {
        this.SmallButton('恢复', '#7FA8FF', (): void => this.reopen(t))
        this.SmallButton('删除', '#FF8080', (): void => {
          this.pendingDeleteId = t.id;
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.05)')
    .borderRadius(GLASS_RADIUS)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
    .margin({ bottom: 8 })
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: -10 }))
      .animation({ duration: dur(DUR_ITEM), curve: curveOrLinear(motionCurve) }))
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
          // 内置四个（作业/自学/考试/无）+ 自定义的类型。
          // ⚠️ key 必须带选中态，否则点一下不会重画（§21.6d 老坑）。
          ForEach(this.editorCategories(), (o: CategoryOption) => {
            ChipButton({
              text: o.label,
              selected: this.editCategory === o.key,
              onTap: (): void => this.chooseCategory(o.key)
            })
          }, (o: CategoryOption) => `cat-${o.key}-${this.editCategory === o.key}`)
          // 用户 2026-10-15：把原来的「其他」胶囊换成「新建类型」按钮，颜色略不同。
          // 点开就地输入，新建的是**全局类型**（设置页同步可见）。
          Text('＋ 新建类型')
            .fontSize(12)
            .fontColor('#E8B25C')
            .backgroundColor('rgba(232,178,92,0.16)')
            .borderRadius(14)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 8 })
            .onClick((): void => this.toggleCatCreating())
        }
        .width('100%')

        if (this.catCreating) {
          Row() {
            TextInput({ text: this.catDraft, placeholder: `新类型名（最多 ${CATEGORY_NAME_MAX} 个字）` })
              .fontColor('#F2F5FA')
              .placeholderColor('#8B97AC')
              .caretColor('#7FA8FF')
              .layoutWeight(1)
              .onChange((v: string): void => {
                this.catDraft = v;
                this.catError = '';
              })
              .onSubmit((): void => this.addCategoryInline())
            Button('添加')
              .backgroundColor('rgba(232,178,92,0.20)')
              .fontColor('#E8B25C')
              .fontSize(12)
              .margin({ left: 8 })
              .onClick((): void => this.addCategoryInline())
            Button('取消')
              .backgroundColor('rgba(255,255,255,0.12)')
              .fontColor('#A9B5C9')
              .fontSize(12)
              .margin({ left: 8 })
              .onClick((): void => this.toggleCatCreating())
          }
          .width('100%')
          .margin({ top: 2, bottom: 4 })

          if (this.catError.length > 0) {
            Text(this.catError)
              .fontSize(11)
              .fontColor('#FF8A8A')
              .width('100%')
          }
        }

        // 备注：**所有类型都能写**（用户要求「待办可写备注」）。
        // 考试时它就是原来的「考场 / 座位」—— 同一个 `note` 字段，只是标签随类型变。
        //
        // ★ 用户 2026-10-16：「备注区可以展开（默认单行文本输入框，但下有展开箭头，
        //   点击展开成大文本框（可以上下滚动的，避免把整个属性界面撑满）），
        //   是单行文本还是大文本框需要**记忆**」。
        Row() {
          Text(this.editCategory === TodoCategory.Exam ? '考场 / 座位' : '备注')
            .fontSize(12)
            .fontColor('#94A0B5')
            .layoutWeight(1)
          Text(this.noteExpanded ? '收起 ▴' : '展开 ▾')
            .fontSize(11)
            .fontColor('#7FA8FF')
            .padding({ left: 10, top: 2, bottom: 2 })
            .onClick((): void => this.toggleNoteExpanded())
        }
        .width('100%')
        .margin({ top: 6, bottom: 6 })

        if (this.noteExpanded) {
          // 大文本框：固定高度 + **内部滚动**，不会把整个属性面板撑满
          TextArea({
            text: this.editNote,
            placeholder: this.editCategory === TodoCategory.Exam
              ? '教学楼 101 · 12 号座' : '可选，随便记点什么'
          })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .height(150)
            .width('100%')
            .onChange((v: string): void => {
              this.editNote = v;
            })
        } else {
          TextInput({
            text: this.editNote,
            placeholder: this.editCategory === TodoCategory.Exam
              ? '教学楼 101 · 12 号座' : '可选，随便记点什么'
          })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .onChange((v: string): void => {
              this.editNote = v;
            })
        }

        if (this.editCategory === TodoCategory.Exam) {
          // 考试 = 一段**固定时间**（用户 2026-10-14）：开始 + 结束各滚一次系统选择器。
          // ⚠️ 这两行**不能抽成带参数的 @Builder**：@Builder 的参数按值传入、首次渲染后固化，
          //    那样选完时间界面不会跟着变（同 ChipButton.ets 顶部那条老坑）。
          Text('考试时间')
            .fontSize(12)
            .fontColor('#94A0B5')
            .margin({ top: 14, bottom: 6 })
            .width('100%')
          Row() {
            Text('开始')
              .fontSize(12)
              .fontColor('#94A0B5')
              .width(40)
            Text(this.editDdl.length >= 16 ? this.editDdl : '未选')
              .fontSize(13)
              .fontColor('#F2F5FA')
              .layoutWeight(1)
            Button('选择…')
              .backgroundColor('rgba(255,255,255,0.14)')
              .fontColor('#7FA8FF')
              .fontSize(12)
              .onClick((): void => this.pickExamTime(true))
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Row() {
            Text('结束')
              .fontSize(12)
              .fontColor('#94A0B5')
              .width(40)
            Text(this.editExamEnd.length >= 16 ? this.editExamEnd : '未选')
              .fontSize(13)
              .fontColor('#F2F5FA')
              .layoutWeight(1)
            Button('选择…')
              .backgroundColor('rgba(255,255,255,0.14)')
              .fontColor('#7FA8FF')
              .fontSize(12)
              .onClick((): void => this.pickExamTime(false))
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Text(this.editExamError.length > 0
            ? this.editExamError
            : '保存后会自动排进计划视图（与已有的块重叠也照排）')
            .fontSize(10)
            .fontColor(this.editExamError.length > 0 ? '#FF8A8A' : '#8B97AC')
            .width('100%')
        } else {
          Text('截止')
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
            // 自定义：滚鸿蒙自己的日期 + 时间选择器（分钟不受任何限制）
            ChipButton({
              text: this.editDdl.length > 0 && !this.ddlIsPreset()
                ? this.ddlShort(this.editDdl) : '自定义…',
              selected: this.editDdl.length > 0 && !this.ddlIsPreset(),
              onTap: (): void => this.pickCustomDdl()
            })
          }
          .width('100%')
          Text(this.editDdl.length > 0 ? `截止：${this.ddlText(this.editDdl)}` : '截止：无')
            .fontSize(11)
            .fontColor('#8B97AC')
            .width('100%')
            .margin({ top: 2 })
        }

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

        // ---- 删除（只对"已经存在"的待办出现；新建时不显示）----
        // ★ 用户实测反馈：确认过的待办原来没有任何删除入口（卡片点一下只开这个抽屉，
        //   而抽屉里只有取消/保存）。这里补上，并且**必须点两下**才真删。
        if (this.editId > 0) {
          Divider()
            .color('rgba(255,255,255,0.12)')
            .margin({ top: 18, bottom: 14 })
          if (this.editorConfirmDelete) {
            Text('确定删除这条待办？删除后不可恢复。')
              .fontSize(11)
              .fontColor('#FF8A8A')
              .width('100%')
            Row() {
              Button('取消')
                .backgroundColor('rgba(255,255,255,0.14)')
                .fontColor('#C3CDDE')
                .layoutWeight(1)
                .onClick((): void => {
                  this.editorConfirmDelete = false;
                })
              Button('确认删除')
                .backgroundColor('#D64545')
                .fontColor('#FFFFFF')
                .layoutWeight(1)
                .margin({ left: 10 })
                .onClick((): void => this.deleteFromEditor())
            }
            .width('100%')
            .margin({ top: 8 })
          } else {
            Button('删除待办')
              .backgroundColor('rgba(214,69,69,0.18)')
              .fontColor('#FF8A8A')
              .fontSize(13)
              .width('100%')
              .onClick((): void => {
                this.editorConfirmDelete = true;
              })
          }
        }
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

              // ---- 已完成：留在页面最下方、加灰显示 ----
              // ★ 用户实测反馈：完成之后那条**直接消失**了，既看不到它去哪了、也没法恢复。
              //   现在放到这里：默认展开（就是要让人看见"它没丢"），可收起。
              if (this.doneList.length > 0) {
                Row() {
                  Text('已完成')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#94A0B5')
                  Text(`${this.doneList.length} 条`)
                    .fontSize(12)
                    .fontColor('#7C8798')
                    .margin({ left: 6 })
                  Blank()
                  Text(this.doneOpen ? '收起 ▴' : '展开 ▾')
                    .fontSize(11)
                    .fontColor('#7FA8FF')
                    .padding({ left: 8 })
                    .onClick((): void => {
                      this.doneOpen = !this.doneOpen;
                    })
                }
                .width('100%')
                .margin({ top: 18, bottom: 8 })

                if (this.doneOpen) {
                  ForEach(this.doneList, (t: Todo) => {
                    this.DoneRow(t)
                  }, (t: Todo) => this.todoKey('d', t))
                }
              }
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
