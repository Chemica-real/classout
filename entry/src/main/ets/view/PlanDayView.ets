import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, CourseSession, PlanBlock, RestWindow, Semester, SessionOverride,
  SessionRule, SectionTime, Todo, TodoSource, TodoStatus, VirtualLesson } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { sessionsOnDate } from '../domain/Timetable';
import { generateForLesson } from '../domain/TodoGenerator';
import { TimeAxis, DEFAULT_AXIS, allBlocksDone,
  dragOffsetWithScroll, dropRange, edgeScrollDepth, edgeScrollDirection, edgeScrollStep,
  durationToH, findFreeSlot, moveRange, normalizeDuration,
  resizeRange, sortBlocksByTime,
  selectPoolTodos } from '../domain/PlanMath';
import { BLOCK_MIN_MIN, DURATION_STEP_MIN, pinchDeltaLabel, pinchEnd, resizeEndTo,
  totalBlockMinutes } from '../domain/Validate';
// 版式常量与列几何都搬去了 domain/PlanLayout：那边能进离线断言，
// 而且 test.ts 直接 import 同一份（以前是抄一遍再断言，抄错了也发现不了）
import { AXIS_W, canBeginDrag, centerIndex, COLS_DAY, COLS_THREE, columnAtX, columnHeaderText,
  columnWidth, columnX, compactMinH, compactThreshold, dayDates, dropColumnOrFallback, LAYOUT,
  MIN_VISIBLE_H, tapAction, TAP_OPEN } from '../domain/PlanLayout';
import { addDays, formatDate, hhmmToMin, minToHHmm, parseDate, relativeDayText, today, WEEKDAY_CN,
  weekdayOf } from '../util/DateUtil';
import { ChipButton } from './ChipButton';
import { hapticLongPress } from '../util/Haptics';
import { BackHandler, backStack } from '../util/BackStack';
import { GLASS_BLUR, GLASS_EDGE_SHELF, GLASS_EDGE_SOFT, GLASS_EDGE_STRONG, GLASS_RADIUS,
  GLASS_RADIUS_SHELF, GLASS_SHADOW_ROW, GLASS_SHADOW_SHELF, GLASS_SHADOW_SHEET, GLASS_TINT_PANEL,
  GLASS_TINT_ROW, GLASS_TINT_SHELF, GLASS_TINT_SHEET } from './Glass';
import { FLOAT_GAP, FLOAT_SIDE, H_COLHEAD, H_DAYBAR } from './Float';

// 文件内 @Styles（Glass.ets 顶部说明了为什么不能跨文件 export）
// 深色版：模糊只留给页头/托盘/编辑窗这些"大面"，托盘卡用小卡材质（不模糊）
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

/**
 * 悬浮"货架"（待安排托盘）：和 `glassSheet` **刻意不同** —— 压暗、圆角小一号、
 * 阴影收敛，读起来像"凹进去的抽屉"，托盘里的卡片压在上面才有层次感。
 */
@Styles
function glassShelf() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_SHELF)
  .borderRadius(GLASS_RADIUS_SHELF)
  .border({ width: 1, color: GLASS_EDGE_SHELF })
  .shadow(GLASS_SHADOW_SHELF)
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 虚拟课时排进计划时的默认时长 */
const LESSON_MIN: number = 90;

/**
 * 网格用的时间轴。改版后会由「管理课程」里的时间窗设置算出，
 * 目前固定在默认窗（07:00–24:00）。
 */
const AXIS: TimeAxis = DEFAULT_AXIS;
const GRID_H: number = AXIS.height();
/**
 * 截止标记（"⚑ … 截止"）的高度余量（vp）。
 *
 * 它按 `yOf(23:59)` 定位，**会从网格底边往下挂出自己的一整行**（实测 92px ≈ 31vp）。
 * 不留这个余量的话，滑到底时它的下半截会被悬浮的待安排货架盖住 ——
 * 用户实测反馈就是这个："待安排栏把计划视图的最低下挡住了一点点"。
 */
const DDL_MARK_ALLOW: number = 36;

/**
 * 课程灰带 / 计划块 / 截止标记的宽度 = 父级满宽 **减去**时间轴。
 *
 * ⚠️ 这是一个真 bug 的修复（用户报「计划页面右侧在屏幕外」）：
 * 这三处原来是 `width('100%')` 配 `position({ x: 46 })`，
 * 于是右边缘 = 46 + 屏宽，整整溢出时间轴那么宽（46vp ≈ 屏宽的 12.8%），
 * 块的右侧内边距和内容全被 Scroll 视口裁掉。
 * 时间轴那条 Divider 本来就用 `layoutWeight(1)` 扣掉了 46vp —— 可见原意就是「内容区 = 100% − 46vp」，
 * 只是宽度忘了一起扣。
 *
 * ⚠️ 只用于**单日视图**。三日视图要走按列算出来的具体宽度（见 PlanLayout.columnWidth），
 * 不能用这个 calc 串。
 */
const CONTENT_W: string = `calc(100% - ${AXIS_W}vp)`;

@Component
export struct PlanDayView {
  @Prop semesterId: number;
  /** 上方悬浮浮窗（Index 的页头）占掉的高度，由 Index 量好传进来 */
  @Prop topInset: number = 0;
  /** 下方悬浮浮窗（导航栏）占掉的高度，由 Index 量好传进来 */
  @Prop bottomInset: number = 0;
  /**
   * 本页那叠浮窗（日期栏 [+ 三日列头]）量出来的总高度；**0 = 还没量到**。
   * 没量到时用 `topBarsBlockH()` 按名义高度估一个，免得第一帧内容顶到屏幕上边。
   */
  @State topBarsH: number = 0;
  /** 待安排托盘（悬浮货架）量出来的高度：网格底部要给它留 padding */
  @State trayH: number = 0;
  /** 本页浮窗叠（含 Index 页头让出的那段）的实际占位高度 */
  private topBarsBlockH(): number {
    if (this.topBarsH > 0) {
      return this.topBarsH;
    }
    // 名义高度：Index 页头让出的那段 + 一条缝 + 日期栏
    return this.topInset + FLOAT_GAP + H_DAYBAR + FLOAT_GAP;
  }

  @State semester: Semester | undefined = undefined;
  @State date: string = '';
  @State blocks: PlanBlock[] = [];
  @State todos: Todo[] = [];
  @State courses: Course[] = [];
  @State sessions: CourseSession[] = [];
  @State restWindows: RestWindow[] = [];
  /** 虚拟课程的课时（待分配的「讲」） */
  @State lessons: VirtualLesson[] = [];
  @State loading: boolean = true;
  @State selectedTodoId: number = 0;
  /**
   * 选中的**块**（单击选中，加黑框高亮）。0 = 没选中任何块。
   *
   * 交互模型由用户 2026-10-14 逐条定稿（见 HANDOFF）：
   *   单击块            → 选中；已经是选中的那一块 → 打开编辑窗
   *   未选中时双击      → 第一下选中、第二下开窗（天然满足「双击打开」）
   *   单击另一块        → 直接改选那一条
   *   单击空白          → 取消选中（若托盘里有待选待办，则优先把它放下）
   *   长按**已选中**的块 → 振动 + 拖拽改时间（必须两步，用户明确要求）
   *   双指缩放已选中的块 → 改时长（开始时间不动）
   */
  @State selectedBlockId: number = 0;
  /** 编辑窗里正在看的块。用对象引用是因为面板直接渲染它；每次改动后 refreshEditor() 会换成新对象 */
  @State editingBlock: PlanBlock | undefined = undefined;
  /** 该待办的全部块（含编辑中的这块），编辑窗用它列「其他块」。虚拟课时只有自己一条 */
  @State editorBlocks: PlanBlock[] = [];
  /** 编辑窗里的文本草稿：失焦/提交时才落库 */
  @State editorStartText: string = '';
  @State editorDurationText: string = '';
  @State editorError: string = '';
  /** 编辑窗里「删除待办」的二次确认开关 */
  @State editorConfirmDeleteTodo: boolean = false;
  /**
   * 刚刚长按过（用来吃掉长按之后紧跟的那次 onClick）。
   *
   * ⚠️ 真机实测：**长按不移动、直接松手，ArkUI 依然会补一次 onClick**。
   * 于是"选中 → 长按准备拖 → 松手"会莫名其妙弹出编辑窗。
   * 按用户定的模型，长按不该等于点击，所以这里显式吞掉那一次。
   * 在每次触摸按下时清零：长按后真的拖动了（不会产生 onClick）也不会误吞下一次真正的点击。
   */
  private longPressHandled: boolean = false;
  /**
   * 编辑窗的「代」。用来丢弃**在途的异步刷新**。
   *
   * ⚠️ 真机实测踩到的坑：`refreshEditor()` 里有 `await getBlock()`，
   * 如果在这个 await 还没回来时用户点了窗外把窗关掉，
   * 回来之后那句 `this.editingBlock = fresh` 会把**已经关掉的窗又打开**，
   * 表现为"点了窗外没反应/过一会儿自己又弹出来"。
   * 开窗、关窗都让 epoch +1；异步回来发现 epoch 变了就直接丢弃结果。
   */
  private editorEpoch: number = 0;
  @State hint: string = '';
  /** 正在被拖动的块与实时位移（拖拽中只改预览，松手才落库） */
  @State dragBlockId: number = 0;
  @State dragOffsetY: number = 0;
  /** 正在双指缩放的块（0 = 没在缩放），以及缩放预览的结束分钟 */
  @State pinchBlockId: number = 0;
  @State pinchEndMin: number = 0;
  /** 按下双指那一刻的结束分钟（缩放基准，不随手指抖动累积） */
  private pinchBaseEndMin: number = 0;
  /** 屏幕正中那个深色 ±NN min 提示（'' = 不显示） */
  @State pinchLabel: string = '';
  /** 从「待安排」拖进网格时携带的待办 id */
  @State dragTodoId: number = 0;
  /** 从「待安排」拖进网格时携带的虚拟课时 id */
  @State dragLessonId: number = 0;

  /** 本次触摸的按下点（**窗口坐标**）。位移按窗口坐标算，长按后网格滚了也不会跳 */
  @State pressStartY: number = 0;
  /** 网格的 Scroller：拖动块靠近上/下边缘时用它自动滚时间轴 */
  /**
   * 顶部瞬时提示的自动消失定时器（-1 = 没有在计时）。
   * 用户要求「把上面蓝色的日志栏去除」——原来那条提示是**常驻**的蓝色横幅，
   * 而且它在布局流里：一出现/消失，整个时间网格就上下跳 40vp，
   * 于是"单击选中（顺手清掉提示）→ 再单击"时方块会从手指底下跑掉（真机实测）。
   * 现在改成不参与布局的深色小胶囊 + 1.8 秒自动消失。
   */
  private hintTimer: number = -1;
  private gridScroller: Scroller = new Scroller();
  /** 边缘自动滚动的逐帧定时器 id（-1 = 没在滚） */
  private edgeTimer: number = -1;
  /** 当前触摸点（窗口 y）。自动滚动用它判断在不在边缘区 */
  private touchWinY: number = 0;
  /** 开始移动那一刻的网格滚动位置。自动滚动产生的偏移量用它算 */
  private dragStartScroll: number = 0;
  /** 拖动期间是否锁住 Scroll 自身滚动（锁住后只允许边缘自动滚） */
  @State gridScrollLocked: boolean = false;
  /** 网格**可视区**上边界（窗口坐标） */
  @State gridViewTop: number = 0;
  /** 网格**可视区**下边界（窗口坐标） */
  @State gridViewBottom: number = 0;
  /** 最后一次已知的触摸 y（窗口坐标） */
  private lastTouchY: number = 0;
  /** 网格在窗口里的顶边（把窗口坐标换算成网格内坐标用） */
  @State gridTop: number = 0;

  // ---- 视图与列（2026-10-14 新增：日 / 三日两档）----

  /**
   * 视图列数：`COLS_DAY`(1) = 单日，`COLS_THREE`(3) = 三日。
   * ⚠️ 用户明确删掉了整周列表视图（「功能鸡肋」），**不要再加第三档**。
   */
  @State viewCols: number = COLS_DAY;
  /** 当前视图要显示哪几天（长度 = viewCols，**中间那个 = this.date**） */
  @State colDates: string[] = [];
  /**
   * 左右两列的数据（只有三日视图才加载）。
   *
   * ★ 中间列**继续用 `this.sessions` / `this.blocks`**，所以既有逻辑
   *   （找空档、托盘过滤、拖拽落库、时长回写）一行都不用改 ——
   *   "当前查看日"在语义上仍然是 `this.date`，侧列纯粹是展示。
   */
  @State leftSessions: CourseSession[] = [];
  @State leftBlocks: PlanBlock[] = [];
  @State rightSessions: CourseSession[] = [];
  @State rightBlocks: PlanBlock[] = [];
  /** 网格视口宽度（vp）。三日视图的列宽/列 x 都要用它 */
  @State gridW: number = 360;
  /** 网格在窗口里的左边（把窗口 x 换算成网格内 x，跨天拖拽命中列要用） */
  @State gridLeft: number = 0;
  /** 拖拽中的目标列。等于中心列 = 不改天 */
  @State dragColIndex: number = 0;

  /** 系统返回的处理器（注册到 util/BackStack，由 Index.onBackPress 触发） */
  private backHandler: BackHandler | undefined = undefined;

  aboutToAppear(): void {
    this.date = formatDate(today());
    // 先按当前视图把列日期填上，别等 reload 回来（否则首帧网格是空的）
    this.colDates = dayDates(this.date, this.viewCols);
    this.dragColIndex = centerIndex(this.viewCols);
    // 手势导航/返回键要能"从最上面那层开始关"
    this.backHandler = (): boolean => this.handleBack();
    backStack.register(this.backHandler);
    this.load();
  }

  aboutToDisappear(): void {
    // 必须注销：本组件会随标签切换销毁，留着就是指向已销毁组件的处理器
    if (this.backHandler !== undefined) {
      backStack.unregister(this.backHandler);
      this.backHandler = undefined;
    }
  }

  /**
   * 计划页的返回顺序：先关编辑窗 → 再取消选中的块 → 再取消托盘的选中 → 都不管。
   * 都处理不了才返回 false，让更下层（Index 的浮层/系统）接着处理。
   */
  private handleBack(): boolean {
    if (this.editingBlock !== undefined) {
      this.closeEditor();
      return true;
    }
    if (this.selectedBlockId > 0) {
      this.selectedBlockId = 0;
      this.showHint('');
      return true;
    }
    if (this.selectedTodoId > 0) {
      this.selectedTodoId = 0;
      this.showHint('');
      return true;
    }
    return false;
  }

  // ---- 列几何（纯算术都在 domain/PlanLayout，有离线断言）----

  /** 中心列下标 = 当前查看日所在的那一列 */
  private centerCol(): number {
    return centerIndex(this.viewCols);
  }

  /** 第 i 列显示哪一天 */
  private dateOfCol(i: number): string {
    return i >= 0 && i < this.colDates.length ? this.colDates[i] : this.date;
  }

  /** 第 i 列的课程。中心列 = 当前查看日的课程（this.sessions） */
  private sessionsOfCol(i: number): CourseSession[] {
    if (i === this.centerCol()) {
      return this.sessions;
    }
    return i < this.centerCol() ? this.leftSessions : this.rightSessions;
  }

  /** 第 i 列的块。中心列 = 当前查看日的块（this.blocks） */
  private blocksOfCol(i: number): PlanBlock[] {
    if (i === this.centerCol()) {
      return this.blocks;
    }
    return i < this.centerCol() ? this.leftBlocks : this.rightBlocks;
  }

  /**
   * 第 i 列的宽度。
   * 单日视图仍然用 `calc(100% - 46vp)`：不需要先量到视口宽度，首帧就是对的。
   * 三日视图用算出来的具体 vp（列宽 = (视口宽 − 时间轴)/3）。
   */
  private colWidthOf(i: number): Length {
    if (this.viewCols <= COLS_DAY) {
      return CONTENT_W;
    }
    return columnWidth(this.gridW, this.viewCols);
  }

  /** 第 i 列的左边缘 x（vp） */
  private colXOf(i: number): number {
    if (this.viewCols <= COLS_DAY) {
      return AXIS_W;
    }
    return columnX(this.gridW, this.viewCols, i);
  }

  /** 块画在哪一列：拖拽中的块跟着手指跨列，其余就按它自己所在的列 */
  private blockColOf(b: PlanBlock, ci: number): number {
    if (this.isDragging(b) && this.viewCols > COLS_DAY) {
      return this.dragColIndex;
    }
    return ci;
  }

  /** 某个块当前在第几列（拖出来时原位空位要画在它原来那一列） */
  private colIndexOfBlock(id: number): number {
    for (let i = 0; i < this.viewCols; i++) {
      for (const b of this.blocksOfCol(i)) {
        if (b.id === id) {
          return i;
        }
      }
    }
    return this.centerCol();
  }

  /**
   * 切换 日 / 三日。**保持当前日期不变**（用户要求：不重置到今天）。
   * 切视图会把选中与编辑窗收起来，避免"选中的块在新视图里根本看不见"。
   */
  private setViewCols(cols: number): void {
    if (this.viewCols === cols) {
      return;
    }
    this.viewCols = cols;
    this.dragColIndex = centerIndex(cols);
    this.selectedBlockId = 0;
    this.closeEditor();
    this.refresh();
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
      hilog.error(DOMAIN, TAG, 'plan load failed: %{public}s', JSON.stringify(e));
      this.loading = false;
    });
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const sem: Semester | undefined = await TimetableRepo.getSemester(ctx);
    this.semester = sem;
    if (sem === undefined) {
      this.loading = false;
      return;
    }
    this.courses = await TimetableRepo.listCourses(ctx, sem.id);
    const rules: SessionRule[] = await TimetableRepo.listRules(ctx, sem.id);
    const times: SectionTime[] = await TimetableRepo.listSectionTimes(ctx, sem.id);
    // 当前视图要显示哪几天（中间那列 = this.date）
    this.colDates = dayDates(this.date, this.viewCols);
    const firstDate: string = this.colDates.length > 0 ? this.colDates[0] : this.date;
    const lastDate: string = this.colDates.length > 0
      ? this.colDates[this.colDates.length - 1] : this.date;
    // 一次把整个范围的单周覆盖查出来，各列共用（sessionsOnDate 内部会按日期过滤）
    const overrides: SessionOverride[] =
      await TimetableRepo.listOverridesBetween(ctx, firstDate, lastDate);
    // 中间列 = 当前查看日（语义与改动前完全一致）
    this.sessions = sessionsOnDate(sem, this.courses, rules, overrides, times, parseDate(this.date));
    this.blocks = await TodoRepo.listBlocksOn(ctx, this.date);
    // 侧列：只有三日视图才去查（单日视图白查就是浪费）
    if (this.viewCols === COLS_THREE && this.colDates.length === COLS_THREE) {
      const leftDate: string = this.colDates[0];
      const rightDate: string = this.colDates[2];
      this.leftSessions = sessionsOnDate(sem, this.courses, rules, overrides, times,
        parseDate(leftDate));
      this.leftBlocks = await TodoRepo.listBlocksOn(ctx, leftDate);
      this.rightSessions = sessionsOnDate(sem, this.courses, rules, overrides, times,
        parseDate(rightDate));
      this.rightBlocks = await TodoRepo.listBlocksOn(ctx, rightDate);
    } else {
      this.leftSessions = [];
      this.leftBlocks = [];
      this.rightSessions = [];
      this.rightBlocks = [];
    }
    this.todos = await TodoRepo.listTodos(ctx, 'status != ?', [TodoStatus.Archived]);
    this.restWindows = await TimetableRepo.listRestWindows(ctx);
    this.lessons = await TodoRepo.listLessonsOfVirtualCourses(ctx, sem.id);
    this.loading = false;
  }

  private refresh(): void {
    this.reload().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'plan reload failed: %{public}s', JSON.stringify(e));
    });
  }

  private courseOf(id: number): Course | undefined {
    for (const c of this.courses) {
      if (c.id === id) {
        return c;
      }
    }
    return undefined;
  }

  private colorOf(courseId: number): string {
    const c: Course | undefined = this.courseOf(courseId);
    if (c === undefined) {
      return '#8FA0BA';
    }
    return COURSE_COLORS[c.colorIndex % COURSE_COLORS.length];
  }

  private todoOf(id: number): Todo | undefined {
    for (const t of this.todos) {
      if (t.id === id) {
        return t;
      }
    }
    return undefined;
  }

  private todoTitle(id: number): string {
    const t: Todo | undefined = this.todoOf(id);
    return t === undefined ? '待办' : t.title;
  }

  private todoCourseId(id: number): number {
    const t: Todo | undefined = this.todoOf(id);
    return t === undefined ? 0 : t.courseId;
  }

  // ---- 虚拟课程的课时 ----

  private lessonOf(id: number): VirtualLesson | undefined {
    for (const l of this.lessons) {
      if (l.id === id) {
        return l;
      }
    }
    return undefined;
  }

  private lessonTitle(l: VirtualLesson): string {
    if (l.title.length > 0) {
      return l.title;
    }
    const c: Course | undefined = this.courseOf(l.courseId);
    const name: string = c === undefined
      ? '虚拟课程'
      : (c.shortName.length > 0 ? c.shortName : c.name);
    return `${name} 第 ${l.seq} 讲`;
  }

  /** 还没做完、且今天还没排过的课时 */
  private poolLessons(): VirtualLesson[] {
    const scheduled: Set<number> = new Set<number>();
    for (const b of this.blocks) {
      if (b.lessonId > 0) {
        scheduled.add(b.lessonId);
      }
    }
    const out: VirtualLesson[] = [];
    for (const l of this.lessons) {
      if (!l.done && !scheduled.has(l.id)) {
        out.push(l);
      }
    }
    return out;
  }

  private blockTitle(b: PlanBlock): string {
    if (b.lessonId > 0) {
      const l: VirtualLesson | undefined = this.lessonOf(b.lessonId);
      return l === undefined ? '虚拟课时' : this.lessonTitle(l);
    }
    return this.todoTitle(b.todoId);
  }

  private blockCourseId(b: PlanBlock): number {
    if (b.lessonId > 0) {
      const l: VirtualLesson | undefined = this.lessonOf(b.lessonId);
      return l === undefined ? 0 : l.courseId;
    }
    return this.todoCourseId(b.todoId);
  }

  private placeLesson(l: VirtualLesson, startMin: number, duration: number,
    date: string): void {
    this.doPlaceLesson(l, startMin, duration, date).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'place lesson failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doPlaceLesson(l: VirtualLesson, startMin: number, duration: number,
    date: string): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const block: PlanBlock = {
      id: 0,
      todoId: 0,
      lessonId: l.id,
      date: date,
      startMin: startMin,
      endMin: startMin + duration,
      done: false
    };
    await TodoRepo.insertBlock(ctx, block);
    this.showHint(`已安排：${this.lessonTitle(l)}`);
    await this.reload();
  }

  private autoPlaceLesson(l: VirtualLesson): void {
    const weekday: number = weekdayOf(parseDate(this.date));
    const isToday: boolean = this.date === formatDate(today());
    const from: number = isToday ? this.nowMinute() : AXIS.startMin;
    const slot: number = findFreeSlot(AXIS, this.busyRanges(), this.restRanges(weekday), LESSON_MIN, from);
    if (slot < 0) {
      this.showHint('这天（或剩余时间）排不下了，换一天试试');
      return;
    }
    this.placeLesson(l, slot, normalizeDuration(LESSON_MIN), this.date);
    this.showHint(`已排到 ${minToHHmm(slot)}`);
  }

  /**
   * 「待安排」托盘里的待办：未完成、且**今天**还没排过。
   * 判据在 domain/PlanMath.selectPoolTodos（纯函数，有离线断言）。
   * this.blocks 由 listBlocksOn(ctx, this.date) 载入，只含当天，正好对上那边的要求。
   * 换到别的日期时待办会重新出现，所以「拆成多块分散在不同天」仍然可行。
   */
  private poolTodos(): Todo[] {
    return selectPoolTodos(this.todos, this.blocks);
  }

  private selectedTodo(): Todo | undefined {
    return this.todoOf(this.selectedTodoId);
  }

  /**
   * 弹一条瞬时提示（不占布局、自动消失）。
   * 传空串 = 立刻清掉。
   */
  private showHint(text: string): void {
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
    this.hint = text;
    if (text.length === 0) {
      return;
    }
    this.hintTimer = setTimeout((): void => {
      this.showHint('');
      this.hintTimer = -1;
    }, 1800);
  }

  private goDay(delta: number): void {
    this.date = formatDate(addDays(parseDate(this.date), delta));
    this.selectedTodoId = 0;
    this.refresh();
  }

  private goToday(): void {
    this.date = formatDate(today());
    this.selectedTodoId = 0;
    this.refresh();
  }

  private headerText(): string {
    const d: Date = parseDate(this.date);
    return `${d.getMonth() + 1} 月 ${d.getDate()} 日 周${WEEKDAY_CN[weekdayOf(d) - 1]}`;
  }

  /**
   * 网格上的空白点击。
   *
   * 优先级：① 托盘里有选中的待办 → 在点击处放下它（原有功能，不能丢）；
   *         ② 有选中的块 → 取消选中（用户明确要求「单击其他地方取消选中」）；
   *         ③ 都没有 → 给一句提示。
   */
  private onGridTap(event: ClickEvent): void {
    // 点在哪一列就排到那一天（三日视图）。命中不到列（点在时间轴上）→ 退回中心列。
    // ⚠️ 用户要求"点侧列**不换天**"：这里只影响排到哪天，不改 this.date。
    const tapCol: number = this.viewCols > COLS_DAY
      ? dropColumnOrFallback(this.gridW, this.viewCols, event.windowX - this.gridLeft,
        this.centerCol())
      : this.centerCol();
    const tapDate: string = this.dateOfCol(tapCol);
    if (this.selectedTodoId > 0) {
      const todo: Todo | undefined = this.selectedTodo();
      if (todo !== undefined) {
        // ⚠️ 必须用**窗口坐标**换算，不能用 `event.y`：
        // `ClickEvent.y` 是相对"接住这次点击的那个节点"的坐标，而网格上还叠着
        // HourLines 的刻度行、课程灰带、块等子节点 —— 点在刻度行上时 y 只有几十像素，
        // 于是不管点哪儿都落在 07:30 附近（真机实测复现过）。
        // 这里改成和 onPoolDrop 完全一致的换算法，两处终于统一。
        const rawY: number = event.windowY - this.gridTop;
        const localY: number = rawY > 0 ? rawY : 0;
        const range: number[] = dropRange(AXIS, localY, todo.estimateMin);
        this.place(todo, range[0], range[1] - range[0], tapDate);
        return;
      }
    }
    if (this.selectedBlockId > 0) {
      this.selectedBlockId = 0;
      this.showHint('');
      return;
    }
    this.showHint('单击块选中它；再点一下打开详情。长按选中的块可以拖时间。');
  }

  /**
   * 单击一个块。
   *
   * 「未选中时双击打开编辑窗」不需要额外的双击手势 ——
   * 第一下把块选中，第二下落在**已选中**的块上，于是直接开窗。
   * 这样单击选中没有延迟，也不会有"点了没反应"的观感。
   */
  private onBlockTap(b: PlanBlock): void {
    // 长按之后被系统补发的那次 onClick：不算点击（用户要求长按 ≠ 点击）
    if (this.longPressHandled) {
      this.longPressHandled = false;
      return;
    }
    // 判据在 domain/PlanLayout.tapAction（有离线断言）：
    // 已选中的同一条再单击 = 开编辑窗；否则 = 选中/改选
    if (tapAction(this.selectedBlockId, b.id) === TAP_OPEN) {
      this.openEditor(b);
      return;
    }
    this.selectedBlockId = b.id;
    // 选中块时清掉托盘选择，避免"两种选中"打架（否则点空白会去放待办而不是取消选中）
    this.selectedTodoId = 0;
    this.showHint('');
  }

  /** 从「待安排」拖进网格后放下 */
  private onPoolDrop(event: DragEvent): void {
    const todoId: number = this.dragTodoId;
    const lessonId: number = this.dragLessonId;
    this.dragTodoId = 0;
    this.dragLessonId = 0;
    // DragEvent.getY() 自 API 10 起废弃，用窗口坐标减去网格顶边
    const rawY: number = event.getWindowY() - this.gridTop;
    const localY: number = rawY > 0 ? rawY : 0;
    // 放到哪一列就排到那一天（三日视图）
    const dropCol: number = this.viewCols > COLS_DAY
      ? dropColumnOrFallback(this.gridW, this.viewCols, event.getWindowX() - this.gridLeft,
        this.centerCol())
      : this.centerCol();
    const dropDate: string = this.dateOfCol(dropCol);

    if (lessonId > 0) {
      const l: VirtualLesson | undefined = this.lessonOf(lessonId);
      if (l === undefined) {
        return;
      }
      const range: number[] = dropRange(AXIS, localY, LESSON_MIN);
      this.placeLesson(l, range[0], range[1] - range[0], dropDate);
      return;
    }

    if (todoId === 0) {
      return;
    }
    const todo: Todo | undefined = this.todoOf(todoId);
    if (todo === undefined) {
      return;
    }
    const range: number[] = dropRange(AXIS, localY, todo.estimateMin);
    this.place(todo, range[0], range[1] - range[0], dropDate);
  }

  // ---- 拖拽改时间 ----

  /**
   * 拖动块时，触摸点进入距上/下边缘这么近的范围就自动滚时间轴。
   * 用户要求：「长按移动块的时候屏幕不应该滚动，除非我把块接近最上/下代表我想滚动时间」。
   */
  private static readonly EDGE_ZONE: number = 60;
  /**
   * 贴到最边缘时每帧滚多少 vp。16ms 一帧 → 约 375vp/s。
   *
   * ⚠️ 原来是「每 50ms 硬跳 16vp」：速度恒定、肉眼可见台阶，
   * 用户实测报「拖到最上最下时不跟手，而且时间轴的跳动不顺滑」。
   * 现在改成**逐帧推进 + 按进入深度线性加速**（见 PlanMath.edgeScrollStep）。
   */
  private static readonly EDGE_MAX_STEP: number = 6;
  /** 逐帧推进的间隔（ms），约一帧 */
  private static readonly EDGE_TICK_MS: number = 16;

  /**
   * 触摸按下。记录按下时刻与位置。
   *
   * ★ 为什么用 onTouch 而不是 LongPressGesture + PanGesture：
   *   挂 PanGesture 会和父级 `Scroll` **争手势** ——
   *   争到手之后、没武装时又什么都不做，于是**从块上起手就滚不动**
   *   （用户实测报过：「拖拽始于一个待办，拖拽不动、没有任何反应」）。
   *   `onTouch` 不注册任何手势，**完全不参与手势竞争**，Scroll 行为不受影响；
   *   长按判定与位移都自己算，逻辑也没有变复杂。
   */
  private onBlockTouchDown(b: PlanBlock, event: TouchEvent): void {
    this.pressStartY = event.touches.length > 0 ? event.touches[0].windowY : 0;
    this.lastTouchY = this.pressStartY;
    this.touchWinY = this.pressStartY;
    // 新手势开始：清掉上一次长按的标记（否则"长按后拖动"会吞掉下一次真正的点击）
    this.longPressHandled = false;
    // ★ 滚动基准在**按下**时记录，且整个拖动期间**不再改**。
    //   块位移公式里的 touchDeltaY 是以按下点为基准的，
    //   若基准滚动位置改成"长按那一刻"，两者基准不一致 → 块会漂。
    this.dragStartScroll = this.gridScroller.currentOffset().yOffset;
  }

  /**
   * 长按块 = 进入拖拽（由 `parallelGesture` 的 LongPressGesture 调用）。
   *
   * **两步模型**（用户明确要求「必须两步：先单击选中，再长按拖动」）：
   * 没被选中的块长按不响应 —— 这样"想滚动的人"永远不会因为按久了而误拖色块。
   *
   * ★ 为什么用 `parallelGesture` 而不是自己计时：
   *   自己计时需要判断"用户是不是在滚动"才能取消长按，而实测"父级 Scroll 接管手势后，
   *   子组件的 onTouch 收不到后续 Move 事件"，无法区分"按住不动"和"正在滚动"，慢速滚动会白振一次。
   *   `parallelGesture` 让长按**和 Scroll 并行识别**，被 Scroll 抢走时系统直接 Cancel 它。
   */
  private onBlockLongPress(b: PlanBlock, ci: number): void {
    // 两步模型的守卫（在 domain/PlanLayout.canBeginDrag，有断言）：
    // 只有**已选中**的块才进入拖拽，未选中的长按完全不响应
    if (!canBeginDrag(this.selectedBlockId, b.id)) {
      return;
    }
    hapticLongPress();
    this.longPressHandled = true;
    // 跨天拖拽的起点 = **这块自己所在的列**。
    // ⚠️ 这里以前写成 centerCol()：侧列的块一按下去就会先跳到中间列（潜伏 bug，
    //   在"侧列只读"时期不会暴露，三列都可拖之后就一定会现形）。
    this.dragColIndex = ci;
    // 长按后禁用 Scroll 自己滚 —— 移动块时时间轴要钉住，
    // 只有 updateEdgeScroll() 在边缘处用代码滚（用户要求）。
    this.gridScrollLocked = true;
    this.dragBlockId = b.id;
    this.dragOffsetY = 0;
    this.showHint('拖动改时间；拖到屏幕上/下边缘会自动滚动时间轴');
  }

  /**
   * 边缘自动滚动的**有效顶边**（窗口坐标）。
   *
   * ⚠️ 不能直接用 `gridViewTop`：日期栏/三日列头/页头都改成了**悬浮浮窗**，
   * 网格视口从屏幕顶就开始了，但**浮窗盖住的那一段是看不见的**。
   * 若还按视口顶边判断"进入上边缘区"，手指会在浮窗底下就触发自动滚动 ——
   * 表现为"还没拖到能看见的边界，时间轴就自己往上跑了"。
   * 所以顶边要往下推整整一叠浮窗的高度。
   */
  private edgeTop(): number {
    return this.gridViewTop + this.topBarsBlockH();
  }

  /**
   * 边缘自动滚动的**有效底边**（窗口坐标）。
   *
   * 同理：待安排托盘与悬浮导航栏现在都盖在网格视口的下半部分，
   * 视口底边已经不是"看得见的底边"了，要往上收掉它们的高度。
   */
  private edgeBottom(): number {
    return this.gridViewBottom - this.bottomInset
      - (this.trayH > 0 ? this.trayH + FLOAT_GAP : 0);
  }

  /**
   * 边缘自动滚动：拖动块时触摸点靠近上/下边缘就让时间轴自己滚。
   *
   * 为什么需要它：移动块时屏幕是钉住的（用户要求），
   * 但如果块要挪到当前视口之外，没有自动滚动就根本挪不过去。
   *
   * ⚠️ 方向**每帧重算**。旧实现把方向捕获在定时器闭包里，一旦启动就改不了 ——
   * 手指从顶部区拖到底部区，时间轴还在往上滚。
   */
  private updateEdgeScroll(): void {
    if (this.dragBlockId === 0) {
      this.stopEdgeScroll();
      return;
    }
    const span: number = this.edgeBottom() - this.edgeTop();
    if (span <= 0) {
      this.stopEdgeScroll();
      return;
    }
    const dir: number = edgeScrollDirection(this.touchWinY, this.edgeTop(),
      this.edgeBottom(), PlanDayView.EDGE_ZONE);
    if (dir === 0) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeTimer !== -1) {
      return;   // 已经在滚了
    }
    this.edgeTimer = setInterval((): void => this.edgeTick(), PlanDayView.EDGE_TICK_MS);
  }

  /**
   * 自动滚动的一帧。
   *
   * ★ 必须在这里重算 offsetY，而且要和 MOVE 用**同一个公式、同一个基准**。
   *
   *   为什么非在这里不可：**手指停住不动时不再产生 Move 事件**，而自动滚动还在继续。
   *   若不在这里重算，块就不会跟着补偿，它会留在网格坐标里、跟着视图一起跑 ——
   *   用户实测：「手指停在 173.958 不动，offsetY 却从 -195 一路涨到 -50.79」，
   *   表现为块向下漂，而且**松手时 endMove 会用这个漂掉的 offsetY 落库**，
   *   块的时间会跳到约 2.4 小时之前（数据错误，不只是手感）。
   *
   *   曾经把它删掉过，理由是"和 MOVE 重复补偿"—— 那是错的：
   *   这两个地方是**同一个公式的两个执行时机**（手指动 / 手指停），不是两次叠加。
   */
  private edgeTick(): void {
    if (this.dragBlockId === 0) {
      this.stopEdgeScroll();
      return;
    }
    const dir: number = edgeScrollDirection(this.touchWinY, this.edgeTop(),
      this.edgeBottom(), PlanDayView.EDGE_ZONE);
    if (dir === 0) {
      this.stopEdgeScroll();
      return;
    }
    const depth: number = edgeScrollDepth(this.touchWinY, this.edgeTop(),
      this.edgeBottom(), PlanDayView.EDGE_ZONE);
    const step: number = edgeScrollStep(depth, PlanDayView.EDGE_ZONE, PlanDayView.EDGE_MAX_STEP);
    this.gridScroller.scrollBy(0, dir * step);
    const dy: number = this.lastTouchY - this.pressStartY;
    const scrolled: number = this.gridScroller.currentOffset().yOffset - this.dragStartScroll;
    this.dragOffsetY = dragOffsetWithScroll(dy, scrolled);
  }

  private stopEdgeScroll(): void {
    if (this.edgeTimer !== -1) {
      clearInterval(this.edgeTimer);
      this.edgeTimer = -1;
    }
  }

  /**
   * 触摸移动。
   *
   * - 未武装 + 位移超容差 → 判定为滑动，**取消长按候选**，放行给 Scroll
   * - 未武装 + 位移很小但按够久 → **就地武装**（用按下时刻判断，不需要定时器）
   * - 已武装 → 按**窗口坐标**算位移，移动块
   *
   * 用窗口坐标而不是本地坐标：长按之后网格可能已经滚了一点，
   * 本地坐标会跟着变，导致块突然跳一下。
   */
  private onBlockTouchMove(b: PlanBlock, event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    this.lastTouchY = event.touches[0].windowY;
    this.touchWinY = this.lastTouchY;
    // 没进入拖拽（没长按过，或长按的不是这块）→ 什么都不做，让 Scroll 正常滚动
    if (this.dragBlockId !== b.id) {
      return;
    }
    // 已进入拖拽：拦下事件，别让父级 Scroll 跟着滚（用户要求：
    // 移动块时屏幕不动，只有块接近上/下边缘才滚时间轴）
    event.stopPropagation();
    const dy: number = this.lastTouchY - this.pressStartY;
    // 补偿网格滚动：块要钉在手指下，就必须减去"网格自己滚掉的那部分"。
    // 否则网格一滚，块相对网格就跑了（等于块的开始时间被偷偷改掉）。
    const scrolled: number = this.gridScroller.currentOffset().yOffset - this.dragStartScroll;
    this.dragOffsetY = dragOffsetWithScroll(dy, scrolled);
    // 横向：跨天拖拽。手指在哪一列，块就落在哪一列的时间线里
    // （用户要求"半透明态的待办始终处于三天之中某一天的时间线中"）。
    // 命中不到任何列时保留上一列，免得手指滑出网格就跳回中间。
    if (this.viewCols > COLS_DAY && event.touches.length > 0) {
      const localX: number = event.touches[0].windowX - this.gridLeft;
      this.dragColIndex = dropColumnOrFallback(this.gridW, this.viewCols, localX,
        this.dragColIndex);
    }
    this.updateEdgeScroll();
  }

  /**
   * 触摸抬起：位移落库、解除滚动锁。
   *
   * ⚠️ 旧实现在这里**不解锁**，于是"长按之后不拖、直接松手"会让 Scroll 一直处于
   * `enableScrollInteraction(false)`（时间轴从此滚不动），只能再点一下别处才恢复。
   */
  private onBlockTouchUp(b: PlanBlock): void {
    this.stopEdgeScroll();
    this.gridScrollLocked = false;
    if (this.dragBlockId === b.id) {
      this.endMove(b);
    }
  }

  private onBlockTouchCancel(): void {
    this.stopEdgeScroll();
    this.gridScrollLocked = false;
    this.dragBlockId = 0;
    this.dragOffsetY = 0;
  }

  // ---- 双指缩放改时长 ----

  /**
   * 双指缩放开始：只在**选中的那一块**上生效（用户要求「在选中状态下，双指缩放以更改时长」）。
   * 记录按下那一刻的结束分钟作为基准 —— 用基准而不是"当前值"，手指抖动不会累积误差。
   */
  private beginPinch(b: PlanBlock): void {
    if (this.selectedBlockId !== b.id) {
      return;
    }
    this.pinchBlockId = b.id;
    this.pinchBaseEndMin = b.endMin;
    this.pinchEndMin = b.endMin;
    this.pinchLabel = pinchDeltaLabel(0);
  }

  private updatePinch(b: PlanBlock, event: GestureEvent): void {
    if (this.pinchBlockId !== b.id) {
      return;
    }
    // 开始时间**不动**，只把结束时间往下拉长 / 往上压短；
    // 5 分钟分度、最短 15 分钟、不越过时间窗末尾都在 pinchEnd 里（纯函数，有断言）
    const next: number = pinchEnd(b.startMin, this.pinchBaseEndMin, event.scale, AXIS.endMin);
    this.pinchEndMin = next;
    this.pinchLabel = pinchDeltaLabel(next - this.pinchBaseEndMin);
  }

  /** 松手确定：把预览值落库（并回写待办时长） */
  private endPinch(b: PlanBlock): void {
    if (this.pinchBlockId !== b.id) {
      return;
    }
    const next: number = this.pinchEndMin;
    this.pinchBlockId = 0;
    this.pinchLabel = '';
    if (next === b.endMin) {
      return;   // 没变，不产生空改动
    }
    b.endMin = next;
    this.persistBlock(b);
    this.showHint(`时长改为 ${b.endMin - b.startMin} 分钟`);
  }

  private endMove(b: PlanBlock): void {
    if (this.dragBlockId === 0) {
      return;   // 没真正开始拖，别落库
    }
    const offset: number = this.dragOffsetY;
    const targetCol: number = this.dragColIndex;
    this.dragBlockId = 0;
    this.dragOffsetY = 0;
    this.gridScrollLocked = false;
    const targetDate: string = this.dateOfCol(targetCol);
    const crossDay: boolean = this.viewCols > COLS_DAY && targetDate !== b.date;
    if (offset === 0 && !crossDay) {
      return;   // 长按了但既没动也没跨天 → 不产生空改动
    }
    // moveRange 把开始时间吸附到 15 分钟刻度（用户要求「以开始时间为准吸附」）
    const range: number[] = moveRange(AXIS, b.startMin, b.endMin, offset);
    b.startMin = range[0];
    b.endMin = range[1];
    if (crossDay) {
      // 跨天：块的日期换到落点列那一天（updateBlock 的 SET 里本来就有 date）
      b.date = targetDate;
      this.showHint(`挪到 ${targetDate} ${minToHHmm(b.startMin)}-${minToHHmm(b.endMin)}`);
    } else {
      this.showHint(`挪到 ${minToHHmm(b.startMin)}-${minToHHmm(b.endMin)}`);
    }
    this.persistBlock(b);
  }

  private persistBlock(b: PlanBlock): void {
    this.doPersist(b).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'persist block failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doPersist(b: PlanBlock): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TodoRepo.updateBlock(ctx, b);
    await this.syncTodoDuration(b.todoId);
    await this.reload();
    await this.refreshEditor();
  }

  /**
   * 把「该待办所有块的时长合计」回写到 todo.estimate_min。
   *
   * ⚠️ 这是用户报的 bug：「在计划界面更改待办时长，并没有更改待办界面对应的待办的时长，
   * 只是在计划图里拉长了」。根因是计划页**从来不写 todo.estimate_min** ——
   * 它只改 plan_block，而块根本没有时长列（时长 = end_min − start_min）。
   *
   * 口径（用户 2026-10-14 选定）：合计 = 该待办**全部**块的时长之和，
   * 这样「拆成多块分散在不同天」的语义不会被弄丢。
   * 一个块都没有时合计为 -1 → **不回写**，否则删光块会把待办变成「预计 0 分钟」。
   */
  private async syncTodoDuration(todoId: number): Promise<void> {
    if (todoId <= 0) {
      return;
    }
    const ctx: common.UIAbilityContext = this.context();
    const all: PlanBlock[] = await TodoRepo.listBlocksByTodo(ctx, todoId);
    const total: number = totalBlockMinutes(all, todoId);
    if (total < 0) {
      return;
    }
    await TodoRepo.setTodoEstimate(ctx, todoId, total);
  }

  // ---- 块的编辑窗 ----

  /**
   * 打开块的编辑窗。
   *
   * 用 `this.editingBlock` 存对象、并在每次改动后 `refreshEditor()` 换成新对象：
   * `reload()` 会整体替换 `this.blocks`，旧引用就和列表脱钩了
   *（原来就是这个坑 —— 面板里的 ± 按钮能继续用只是因为它们只读 `b.id`）。
   */
  private openEditor(b: PlanBlock): void {
    this.editorEpoch++;
    this.editingBlock = b;
    this.editorError = '';
    this.editorConfirmDeleteTodo = false;
    this.editorStartText = minToHHmm(b.startMin);
    this.editorDurationText = `${b.endMin - b.startMin}`;
    this.refreshEditor().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'refresh editor failed: %{public}s', JSON.stringify(e));
    });
  }

  private closeEditor(): void {
    this.editorEpoch++;
    this.editingBlock = undefined;
    this.editorBlocks = [];
    this.editorError = '';
    this.editorConfirmDeleteTodo = false;
  }

  /** 重新读编辑中的块与它所属待办的全部块；块已经不在库里就自动关窗 */
  private async refreshEditor(): Promise<void> {
    const epoch: number = this.editorEpoch;
    const cur: PlanBlock | undefined = this.editingBlock;
    if (cur === undefined) {
      return;
    }
    const ctx: common.UIAbilityContext = this.context();
    const fresh: PlanBlock | undefined = await TodoRepo.getBlock(ctx, cur.id);
    // 期间窗被关掉或换到了别的块 → 丢弃这次结果，否则会把关掉的窗重新打开
    if (epoch !== this.editorEpoch) {
      return;
    }
    if (fresh === undefined) {
      this.closeEditor();
      return;
    }
    this.editingBlock = fresh;
    if (fresh.todoId > 0) {
      this.editorBlocks = sortBlocksByTime(await TodoRepo.listBlocksByTodo(ctx, fresh.todoId));
    } else {
      this.editorBlocks = [fresh];
    }
    this.editorStartText = minToHHmm(fresh.startMin);
    this.editorDurationText = `${fresh.endMin - fresh.startMin}`;
  }

  /** 「这个待办还在别的哪天排了块」——不含正在看的这一块 */
  private editorOtherBlocks(): PlanBlock[] {
    const cur: PlanBlock | undefined = this.editingBlock;
    if (cur === undefined) {
      return [];
    }
    const out: PlanBlock[] = [];
    for (const b of this.editorBlocks) {
      if (b.id !== cur.id) {
        out.push(b);
      }
    }
    return out;
  }

  /** 编辑窗里的「课程属性」行（用户要求计划页把课程显示出来）；没有就返回 '' */
  private editorCourseText(b: PlanBlock): string {
    const cid: number = this.blockCourseId(b);
    if (cid <= 0) {
      return '';
    }
    const c: Course | undefined = this.courseOf(cid);
    if (c === undefined) {
      return '';
    }
    if (b.lessonId > 0 && c.location.length > 0) {
      return `${c.name} · ${c.location}`;
    }
    return c.name;
  }

  /** 开始时间输入：HH:MM，时长保持不变 */
  private commitEditorStart(): void {
    const b: PlanBlock | undefined = this.editingBlock;
    if (b === undefined) {
      return;
    }
    const min: number = hhmmToMin(this.editorStartText.trim());
    if (Number.isNaN(min)) {
      this.editorError = '开始时间要写成 HH:MM，比如 14:30';
      return;
    }
    if (min % DURATION_STEP_MIN !== 0) {
      this.editorError = `开始时间要落在 ${DURATION_STEP_MIN} 分钟刻度上，比如 14:30`;
      return;
    }
    if (min < AXIS.startMin || min > AXIS.endMin) {
      this.editorError = `开始时间要在 ${minToHHmm(AXIS.startMin)}–${minToHHmm(AXIS.endMin)} 之间`;
      return;
    }
    const dur: number = b.endMin - b.startMin;
    if (min + dur > AXIS.endMin) {
      this.editorError = '这个开始时间放不下当前时长（会超出 24:00）';
      return;
    }
    this.editorError = '';
    b.startMin = min;
    b.endMin = min + dur;
    this.persistBlock(b);
  }

  /** 时长输入：开始时间不动，只改结束时间（5 分钟分度、最短 15 分钟） */
  private commitEditorDuration(): void {
    const b: PlanBlock | undefined = this.editingBlock;
    if (b === undefined) {
      return;
    }
    const n: number = Number.parseInt(this.editorDurationText.trim(), 10);
    if (Number.isNaN(n)) {
      this.editorError = '时长要填一个数字';
      return;
    }
    if (n < BLOCK_MIN_MIN) {
      this.editorError = `一块至少 ${BLOCK_MIN_MIN} 分钟`;
      return;
    }
    if (n % DURATION_STEP_MIN !== 0) {
      this.editorError = `时长要是 ${DURATION_STEP_MIN} 分钟的整数倍`;
      return;
    }
    if (b.startMin + n > AXIS.endMin) {
      this.editorError = '这么长会超过 24:00，先把开始时间挪早一点';
      return;
    }
    this.editorError = '';
    b.endMin = b.startMin + n;
    this.persistBlock(b);
  }

  /** 「日期 ‹ ›」：整块挪到前一天/后一天。跨天挪块不靠拖拽，靠这个（用户选的方案） */
  private shiftBlockDate(b: PlanBlock, delta: number): void {
    b.date = formatDate(addDays(parseDate(b.date), delta));
    this.persistBlock(b);
    this.showHint(`改到 ${b.date}`);
  }

  private adjustEditorStart(b: PlanBlock, delta: number): void {
    const min: number = b.startMin + delta;
    const dur: number = b.endMin - b.startMin;
    if (min < AXIS.startMin || min + dur > AXIS.endMin) {
      this.editorError = '再挪就出时间窗了';
      return;
    }
    this.editorError = '';
    b.startMin = min;
    b.endMin = min + dur;
    this.persistBlock(b);
  }

  private adjustEditorDuration(b: PlanBlock, delta: number): void {
    const end: number = resizeEndTo(b.startMin, b.endMin + delta, AXIS.endMin);
    if (end === b.endMin) {
      this.editorError = '改不动了（最短 15 分钟，且不能超过 24:00）';
      return;
    }
    this.editorError = '';
    b.endMin = end;
    this.persistBlock(b);
  }

  /** 改截止时间（只对待办块有效） */
  private setEditorDdl(ddl: string): void {
    const b: PlanBlock | undefined = this.editingBlock;
    if (b === undefined || b.todoId === 0) {
      return;
    }
    this.doSetDdl(b.todoId, ddl).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'set ddl failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSetDdl(todoId: number, ddl: string): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const t: Todo | undefined = await TodoRepo.getTodo(ctx, todoId);
    if (t === undefined) {
      return;
    }
    t.ddl = ddl;
    await TodoRepo.updateTodo(ctx, t);
    this.showHint(ddl.length > 0 ? `截止时间改为 ${ddl}` : '已取消截止时间');
    await this.reload();
  }

  /** 编辑窗里的「删除待办」：连它的所有块一起删；自动生成的还要进黑名单 */
  private removeTodoFromEditor(b: PlanBlock): void {
    this.doRemoveTodo(b).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'remove todo failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doRemoveTodo(b: PlanBlock): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const t: Todo | undefined = await TodoRepo.getTodo(ctx, b.todoId);
    if (t !== undefined && t.source === TodoSource.Template && t.generationKey.length > 0) {
      await TodoRepo.blacklist(ctx, t.generationKey, Date.now());
    }
    await TodoRepo.deleteTodo(ctx, b.todoId);
    this.closeEditor();
    this.selectedBlockId = 0;
    this.showHint(t === undefined ? '已删除待办' : `已删除待办「${t.title}」`);
    await this.reload();
  }

  /** 已占用的时间段（课表 + 已排的块） */
  private busyRanges(): number[][] {
    const out: number[][] = [];
    for (const s of this.sessions) {
      out.push([s.startMin, s.endMin]);
    }
    for (const b of this.blocks) {
      out.push([b.startMin, b.endMin]);
    }
    return out;
  }

  /** 该星期几适用的不可排时段 */
  private restRanges(weekday: number): number[][] {
    const out: number[][] = [];
    for (const w of this.restWindows) {
      if (w.weekday === 0 || w.weekday === weekday) {
        out.push([w.startMin, w.endMin]);
      }
    }
    return out;
  }

  private nowMinute(): number {
    const d: Date = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }

  /** 一键找空档：跳过课表、已排的块、以及用户设的休息时段 */
  private autoPlace(t: Todo): void {
    const weekday: number = weekdayOf(parseDate(this.date));
    const isToday: boolean = this.date === formatDate(today());
    const from: number = isToday ? this.nowMinute() : AXIS.startMin;
    const slot: number = findFreeSlot(AXIS, this.busyRanges(), this.restRanges(weekday),
      t.estimateMin, from);
    if (slot < 0) {
      this.showHint('这天（或剩余时间）排不下了，换一天试试');
      return;
    }
    this.place(t, slot, normalizeDuration(t.estimateMin), this.date);
    this.showHint(`已排到 ${minToHHmm(slot)}`);
  }

  private place(todo: Todo, startMin: number, duration: number, date: string): void {
    this.doPlace(todo, startMin, duration, date).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'place block failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doPlace(todo: Todo, startMin: number, duration: number,
    date: string): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const block: PlanBlock = {
      id: 0,
      todoId: todo.id,
      lessonId: 0,
      date: date,
      startMin: startMin,
      endMin: startMin + duration,
      done: false
    };
    await TodoRepo.insertBlock(ctx, block);
    // 排了新块 → 待办的总时长跟着变（用户要求：计划页的改动必须落到待办本身）
    await this.syncTodoDuration(todo.id);
    // 放下之后清掉托盘选中：它这时已经从托盘里消失了（selectPoolTodos 过滤掉了当天已排的），
    // 再留着选中态会让顶部一直显示"已选中"，下一次点空白还会莫名其妙再排一块。
    this.selectedTodoId = 0;
    this.showHint(`已安排：${todo.title}（${minToHHmm(startMin)}-${minToHHmm(startMin + duration)}）`);
    await this.reload();
  }

  private toggleBlockDone(block: PlanBlock): void {
    this.doToggle(block).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'toggle block failed: %{public}s', JSON.stringify(e));
    });
  }

  /** 点完成圆圈：三列都可点 */
  private onBlockToggleDone(block: PlanBlock): void {
    this.toggleBlockDone(block);
  }

  /** 块打勾/取消；所有块完成 → 待办自动完成；虚拟课时完成 → 触发生成模板 */
  private async doToggle(block: PlanBlock): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    block.done = !block.done;
    await TodoRepo.updateBlock(ctx, block);

    // 虚拟课程的课时：打勾 = 这一讲上完了，跟真课下课走同一条生成逻辑
    if (block.lessonId > 0) {
      const l: VirtualLesson | undefined = await TodoRepo.getLesson(ctx, block.lessonId);
      if (l !== undefined) {
        await TodoRepo.setLessonDone(ctx, l.id, block.done, block.done ? Date.now() : 0);
        const sem: Semester | undefined = this.semester;
        if (block.done && sem !== undefined) {
          const created: number = await generateForLesson(ctx, sem, l, block.date,
            block.startMin, block.endMin);
          if (created > 0) {
            this.showHint(`「${this.lessonTitle(l)}」完成，已生成 ${created} 条待办，去『待办』确认`);
          }
        }
      }
      await this.reload();
      return;
    }

    // 判断「待办是否全部完成」必须看跨全部日期的块：待办可以拆成多块分散在不同天
    const allBlocks: PlanBlock[] = await TodoRepo.listBlocksByTodo(ctx, block.todoId);
    if (allBlocksDone(allBlocks, block.todoId)) {
      await TodoRepo.setTodoStatus(ctx, block.todoId, TodoStatus.Done, Date.now());
    } else {
      await TodoRepo.setTodoStatus(ctx, block.todoId, TodoStatus.Active, 0);
    }
    await this.reload();
  }

  private removeBlock(block: PlanBlock): void {
    this.doRemove(block).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'remove block failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doRemove(block: PlanBlock): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const todoId: number = block.todoId;
    await TodoRepo.deleteBlock(ctx, block.id);
    this.closeEditor();
    // 少了一块 → 待办总时长跟着缩（一个块都不剩时 syncTodoDuration 不会动它）
    await this.syncTodoDuration(todoId);
    await this.reload();
  }

  private yOf(min: number): number {
    return AXIS.minuteToY(min);
  }

  private hOf(from: number, to: number): number {
    return durationToH(to - from);
  }

  /** 块的 y：拖动中带上实时位移，只改预览 */
  private blockY(b: PlanBlock): number {
    const base: number = AXIS.minuteToY(b.startMin);
    return this.dragBlockId === b.id ? base + this.dragOffsetY : base;
  }

  /**
   * 块的高。**常规块严格等于真实时长**（1 分钟 = 1vp，全项目约定）；
   * **紧凑块**（放不下两行字的短块）允许撑到 compactMinH()，否则一整行字会被切掉。
   *
   * 这个例外只影响很短（≲20 分钟）的块，且用户明确要求过
   * （「长度 15min 的计划可以例外地把字体放小以便包含」）。
   * 代价：紧凑块会盖住它下方最多几 vp —— 那段本来就画不下任何东西。
   */
  /**
   * 块按**真实时长**算的高度（不含紧凑撑高）。
   * 渲染分支必须用这个判断，否则「撑高」会让判据自己变来变去。
   */
  private blockTimedH(b: PlanBlock): number {
    return durationToH(this.blockEndMin(b) - b.startMin) - 2;
  }

  /** 块在屏幕上显示的结束分钟：双指缩放时用预览值，其余用真实值 */
  private blockEndMin(b: PlanBlock): number {
    return this.pinchBlockId === b.id ? this.pinchEndMin : b.endMin;
  }

  private blockH(b: PlanBlock): number {
    const raw: number = durationToH(this.blockEndMin(b) - b.startMin) - 2;
    // 再小也要留 MIN_VISIBLE_H：块小到点不到就没法再点开编辑窗了
    const timed: number = raw < MIN_VISIBLE_H ? MIN_VISIBLE_H : raw;
    if (timed < compactThreshold()) {
      return Math.max(timed, compactMinH());
    }
    return timed;
  }

  private blockById(id: number): PlanBlock | undefined {
    for (const b of this.blocks) {
      if (b.id === id) {
        return b;
      }
    }
    return undefined;
  }

  private isSelected(b: PlanBlock): boolean {
    return this.selectedBlockId === b.id;
  }

  private isDragging(b: PlanBlock): boolean {
    return this.dragBlockId === b.id;
  }

  /** 课程的简称（没有简称就用全名）；计划页显示「这块属于哪门课」用 */
  private courseShort(courseId: number): string {
    const c: Course | undefined = this.courseOf(courseId);
    if (c === undefined) {
      return '课程';
    }
    return c.shortName.length > 0 ? c.shortName : c.name;
  }

  /** 拖动中的块留在原位的"空位"的 y */
  private ghostY(): number {
    const b: PlanBlock | undefined = this.blockById(this.dragBlockId);
    return b === undefined ? -999 : AXIS.minuteToY(b.startMin);
  }

  /** 拖动中的块留在原位的"空位"的高度 */
  private ghostH(): number {
    const b: PlanBlock | undefined = this.blockById(this.dragBlockId);
    return b === undefined ? 0 : durationToH(b.endMin - b.startMin) - 2;
  }

  // ---------------- UI ----------------

  @Builder
  HourLines() {
    Column() {
      ForEach(this.hourMarks(), (mark: number) => {
        Row() {
          Text(minToHHmm(mark))
            .fontSize(LAYOUT.hour)
            // ⚠️ 同上：时间刻度是深色下最不能含糊的东西（用户实测"看不清"），
            // 用 §18.5 里"次级正文"那档，比原来的"最弱（刻度）"亮两级
            .fontColor('#CBD6E8')
            .width(40)
            .textAlign(TextAlign.End)
          Divider()
            .color('rgba(255,255,255,0.12)')
            .strokeWidth(1)
            .layoutWeight(1)
            .margin({ left: 6 })
        }
        .width('100%')
        .height(60)
        .alignItems(VerticalAlign.Top)
      }, (mark: number) => `hour-${mark}`)
    }
    .width('100%')
  }

  private hourMarks(): number[] {
    const list: number[] = [];
    for (const t of AXIS.marks) {
      list.push(t);
    }
    return list;
  }

  @Builder
  ClassBlock(s: CourseSession, ci: number) {
    Column() {
      Text(s.course.shortName.length > 0 ? s.course.shortName : s.course.name)
        .fontSize(LAYOUT.title)
        .fontColor('#A9B5C9')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.hOf(s.startMin, s.endMin) > 40 && s.location.length > 0) {
        Text(s.location)
          .fontSize(LAYOUT.sub)
          .fontColor('#8B97AC')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width(this.colWidthOf(ci))
    .height(this.hOf(s.startMin, s.endMin) - 2)
    .padding({ left: 6, right: 6, top: 2 })
    .backgroundColor('rgba(255,255,255,0.10)')
    .borderRadius(6)
    .position({ x: this.colXOf(ci), y: this.yOf(s.startMin) })
  }

  /**
   * 常规块的副行：时间 · 课程简称。
   * 用户要求「如果某待办有对应的课程属性，在待安排框和计划表格里都要显示」。
   */
  private blockSubText(b: PlanBlock): string {
    const t: string = `${minToHHmm(b.startMin)}-${minToHHmm(this.blockEndMin(b))}`;
    const cid: number = this.blockCourseId(b);
    if (cid <= 0) {
      return t;
    }
    return `${t} · ${this.courseShort(cid)}`;
  }

  /** 紧凑块的标题：有课程属性时前缀课程简称（15 分钟的块放不下第二行） */
  private blockCompactTitle(b: PlanBlock): string {
    const cid: number = this.blockCourseId(b);
    if (cid <= 0) {
      return this.blockTitle(b);
    }
    return `${this.courseShort(cid)}·${this.blockTitle(b)}`;
  }

  /** 三日视图里列与列之间的竖直分隔线（单日视图不画） */
  @Builder
  ColumnSeparators() {
    ForEach([1, 2], (i: number) => {
      Column()
        .width(1)
        .height(GRID_H)
        .backgroundColor('rgba(255,255,255,0.12)')
        .position({ x: this.colXOf(i), y: 0 })
    }, (i: number) => `csep-${i}`)
  }

  /**
   * 拖拽中留在原位的虚线空位。
   *
   * ⚠️ 宽度必须按**列宽**算，不能再用 `CONTENT_W`（那是"整条内容区"的宽度）：
   * 三日视图里 x 是某一列的左边缘，配 `CONTENT_W` 就会从这一列起画满整屏，
   * 右边拖出去一大截（用户实测报"虚线框右侧过长"）。单日视图 colWidthOf 返回的
   * 仍然是 CONTENT_W，所以单日行为不变。
   */
  @Builder
  DragGhost() {
    Column()
      .width(this.colWidthOf(this.ghostCol()))
      .height(this.ghostH())
      .borderRadius(6)
      .border({ width: 2, color: 'rgba(255,255,255,0.35)', style: BorderStyle.Dashed })
      .position({ x: this.colXOf(this.ghostCol()), y: this.ghostY() })
  }

  /** 虚线空位画在哪一列 = 被拖的块原来所在的那一列 */
  private ghostCol(): number {
    return this.colIndexOfBlock(this.dragBlockId);
  }

  @Builder
  PlanBlockView(b: PlanBlock, ci: number) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.blockTimedH(b) >= compactThreshold()) {
        // ---- 常规排版：完成圆圈 + 标题 + 时间（两行）----
        Row() {
          Text(b.done ? '●' : '○')
            .fontSize(LAYOUT.title)
            .fontColor(b.done ? '#7FA8FF' : '#FFFFFF')
            .margin({ right: 6 })
            .onClick((): void => this.onBlockToggleDone(b))
          Column() {
            Text(this.blockTitle(b))
              .fontSize(LAYOUT.title)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.blockSubText(b))
              .fontSize(LAYOUT.sub)
              .fontColor('#CBD6E8')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 6, top: 3 })
        .backgroundColor(this.colorOf(this.blockCourseId(b)))
        // 拖拽中半透明（用户要的"从原来在的地方被抽出来跟着手指"的观感）
        .opacity(this.isDragging(b) ? 0.72 : (b.done ? 0.5 : 0.95))
        .borderRadius(6)
        // 选中即黑框高亮（用户要的"选中状态加黑框"）
        .border({
          width: this.isSelected(b) || this.isDragging(b) ? 2 : 0,
          color: '#F2F5FA'
        })
        .onClick((): void => this.onBlockTap(b))
        // 双指缩放改时长。挂在**内层内容**上而不是外层 Stack：
        // 外层已经用 parallelGesture 挂了长按，同一个节点再挂一个手势有可能把前一个顶掉。
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart((): void => this.beginPinch(b))
            .onActionUpdate((event: GestureEvent): void => this.updatePinch(b, event))
            .onActionEnd((): void => this.endPinch(b))
        )
      } else {
        // ---- 紧凑排版：单行「标题 + 时间」，字更小 ----
        // 15 分钟的块只有 13vp 高，两行放不下。这里不画完成圆圈
        //（点开面板也能标记完成），把空间留给标题和时间。
        Row() {
          Text(this.blockCompactTitle(b))
            .fontSize(LAYOUT.compact)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          // 紧凑块只显示**开始时间**：块本身很窄放不下「12:00-12:15」整段，
          // 折行后下半会被块裁掉。结束时间由块高能看出来，点开面板也有完整区间。
          Text(minToHHmm(b.startMin))
            .fontSize(Math.max(9, LAYOUT.compact - 1))
            .fontColor('#CBD6E8')
            .margin({ left: 6 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 7, right: 5 })
        .backgroundColor(this.colorOf(this.blockCourseId(b)))
        .opacity(this.isDragging(b) ? 0.72 : (b.done ? 0.5 : 0.95))
        .borderRadius(6)
        .border({
          width: this.isSelected(b) || this.isDragging(b) ? 2 : 0,
          color: '#F2F5FA'
        })
        .onClick((): void => this.onBlockTap(b))
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart((): void => this.beginPinch(b))
            .onActionUpdate((event: GestureEvent): void => this.updatePinch(b, event))
            .onActionEnd((): void => this.endPinch(b))
        )
      }

      // 底边「⋯」把手已经按用户要求删除（改时长交给双指缩放和编辑窗里的数值输入）。
      // 顺带消掉了把手与块手势互抢导致的"一次长按振两下、同时进入移动和改时长"的 bug。
    }
    .width(this.colWidthOf(this.blockColOf(b, ci)))
    .height(this.blockH(b))
    .position({ x: this.colXOf(this.blockColOf(b, ci)), y: this.blockY(b) })
    .zIndex(this.isDragging(b) ? 10 : (this.isSelected(b) ? 5 : 1))
    // 长按：**只有已选中的块**才进入拖拽（用户明确要求的两步模型）。
    // 没选中的块长按不响应 —— 这样"想滚动时间轴"的人永远不会误拖色块。
    // ★ 用 `parallelGesture` 而不是 `gesture`：它不参与父级 Scroll 的手势竞争 ——
    //   用户想滚动时 Scroll 照常接管（长按被系统 Cancel，不会白振）。
    .parallelGesture(
      LongPressGesture({ repeat: false, duration: 400, fingers: 1 })
        .onAction((): void => this.onBlockLongPress(b, ci))
    )
    // onTouch 只负责"进入拖拽之后的位移"。它不注册手势，所以不抢占 Scroll。
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.onBlockTouchDown(b, event);
      } else if (event.type === TouchType.Move) {
        this.onBlockTouchMove(b, event);
      } else if (event.type === TouchType.Up) {
        this.onBlockTouchUp(b);
      } else {
        this.onBlockTouchCancel();
      }
    })
  }

  @Builder
  DdlMarkers() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.ddlToday(), (t: Todo) => {
        Row() {
          Text(`⚑ ${t.title} 截止`)
            .fontSize(LAYOUT.tray)
            .fontColor('#FF8A8A')
        }
        .width(CONTENT_W)
        .padding({ left: 6, top: 1, bottom: 1 })
        .backgroundColor('rgba(214,69,69,0.18)')
        .borderRadius(4)
        .position({ x: AXIS_W, y: this.yOf(this.ddlMinute(t)) })
      }, (t: Todo) => `ddl-${t.id}`)
    }
    .width('100%')
    .height(GRID_H)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  private ddlToday(): Todo[] {
    const out: Todo[] = [];
    for (const t of this.todos) {
      if (t.status !== TodoStatus.Done && t.ddl.length >= 16 && t.ddl.substring(0, 10) === this.date) {
        out.push(t);
      }
    }
    return out;
  }

  private ddlMinute(t: Todo): number {
    if (t.ddl.length < 16) {
      return AXIS.startMin;
    }
    const h: number = parseInt(t.ddl.substring(11, 13), 10);
    const m: number = parseInt(t.ddl.substring(14, 16), 10);
    const min: number = h * 60 + m;
    return min < AXIS.startMin ? AXIS.startMin : min;
  }

  @Builder
  TodoPool() {
    Column() {
      Row() {
        Text('待安排')
          .fontSize(LAYOUT.tray)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
        Blank()
        if (this.selectedTodoId > 0) {
          Text('已选中，点网格空白处放下')
            .fontSize(LAYOUT.cardSub)
            .fontColor('#7FA8FF')
        } else {
          Text('拖动 / 点选 / ⚡ 一键找空档')
            .fontSize(LAYOUT.tray)
            .fontColor('#8B97AC')
        }
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.poolTodos().length === 0) {
        Text('没有待安排的事项。先去『待办』里确认几条。')
          .fontSize(LAYOUT.tray)
          .fontColor('#8B97AC')
          .margin({ bottom: 6 })
      } else {
        Scroll() {
          Row() {
            ForEach(this.poolTodos(), (t: Todo) => {
              Column() {
                // 上面这块负责拖拽与选中（点 ⚡ 不会连带选中）
                Column() {
                  Text(t.title)
                    .fontSize(LAYOUT.tray)
                    .fontColor('#F2F5FA')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  // 课程属性：用户要求「待安排框里也要显示」
                  if (t.courseId > 0) {
                    Text(this.courseShort(t.courseId))
                      .fontSize(LAYOUT.cardSub)
                      .fontColor('#CBD6E8')
                      .backgroundColor(this.colorOf(t.courseId))
                      .borderRadius(4)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .margin({ top: 2 })
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(`预计 ${t.estimateMin} 分钟`)
                    .fontSize(LAYOUT.cardSub)
                    .fontColor('#9BA7BD')
                    .margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .draggable(true)
                .onDragStart((event: DragEvent, extraParams: string): void => {
                  this.dragTodoId = t.id;
                  this.showHint('拖到网格上松手放下');
                })
                .onClick((): void => {
                  this.selectedTodoId = this.selectedTodoId === t.id ? 0 : t.id;
                  this.showHint(this.selectedTodoId > 0 ? '现在点网格空白处放下它' : '');
                })

                Text('⚡ 找空档')
                  .fontSize(LAYOUT.cardSub)
                  .fontColor('#7FA8FF')
                  .margin({ top: 6 })
                  .onClick((): void => this.autoPlace(t))
              }
              .width(140)
              .padding(10)
              // 托盘卡是"小卡" → `.glassCard()` **不含模糊**（用户定的性能取舍）
              .glassCard()
              // 选中态用半透明蓝 + 亮蓝描边
              // （深色底上 #2E6BE6 当描边太暗，要用提亮的那支才看得出"选中"）
              .backgroundColor(this.selectedTodoId === t.id
                ? 'rgba(46,107,230,0.30)' : GLASS_TINT_ROW)
              .border({
                width: this.selectedTodoId === t.id ? 1.5 : 1,
                color: this.selectedTodoId === t.id ? '#7FA8FF' : GLASS_EDGE_SOFT
              })
              .margin({ right: 8 })
            }, (t: Todo) => `pool-${t.id}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }

      if (this.poolLessons().length > 0) {
        Text('虚拟课程课时（拖进计划，打勾完成会触发生成待办）')
          .fontSize(LAYOUT.cardSub)
          .fontColor('#E0A94E')
          .margin({ top: 12, bottom: 6 })
        Scroll() {
          Row() {
            ForEach(this.poolLessons(), (l: VirtualLesson) => {
              Column() {
                Column() {
                  Text(this.lessonTitle(l))
                    .fontSize(LAYOUT.tray)
                    .fontColor('#F2F5FA')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${LESSON_MIN} 分钟`)
                    .fontSize(LAYOUT.cardSub)
                    .fontColor('#D8C48A')
                    .margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .draggable(true)
                .onDragStart((event: DragEvent, extraParams: string): void => {
                  this.dragLessonId = l.id;
                  this.showHint('拖到网格上松手放下这一讲');
                })

                Text('⚡ 找空档')
                  .fontSize(LAYOUT.cardSub)
                  .fontColor('#E8B25C')
                  .margin({ top: 6 })
                  .onClick((): void => this.autoPlaceLesson(l))
              }
              .width(140)
              .padding(10)
              // 虚拟课时托盘卡同样是"小卡"：不模糊，用暖色薄纱与真待办卡区分开
              .glassCard()
              .backgroundColor('rgba(240,190,90,0.16)')
              .border({ width: 1, color: 'rgba(240,190,90,0.28)' })
              .margin({ right: 8 })
            }, (l: VirtualLesson) => `pl-${l.id}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    // 悬浮货架：和导航栏刻意用不同材质（见 Glass.ets 的 GLASS_TINT_SHELF）
    .glassShelf()
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const h: Length | undefined = newArea.height;
      if (typeof h === 'number') {
        this.trayH = h;
      }
    })
  }

  @Builder
  BlockEditor(b: PlanBlock) {
    Column() {
      // ⚠️ 编辑窗内容长（课程/日期/开始/时长/截止/其他块/三个按钮），
      // 在真机上实测会超出屏幕，底部的「完成」被裁到 TabBar 底下点不到。
      // 所以套一层 Scroll 并限制最大高度：内容短时仍然居中，长时可滚。
      Scroll() {
      Column() {
        Text(this.blockTitle(b))
          .fontSize(LAYOUT.chip)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
        // 课程属性（只读）：用户要求计划页把待办的课程显示出来
        if (this.editorCourseText(b).length > 0) {
          Text(this.editorCourseText(b))
            .fontSize(LAYOUT.tray)
            .fontColor('#CBD6E8')
            .backgroundColor(this.colorOf(this.blockCourseId(b)))
            .borderRadius(5)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ top: 6 })
        }
        Text(`${b.date} ${minToHHmm(b.startMin)} - ${minToHHmm(b.endMin)}（${b.endMin - b.startMin} 分钟）`)
          .fontSize(LAYOUT.tray)
          .fontColor('#9BA7BD')
          .margin({ top: 6 })

        // 日期 ‹ ›：跨天挪块走这里，不靠拖拽（用户选的方案）
        Row() {
          Text('日期')
            .fontSize(LAYOUT.tray)
            .fontColor('#94A0B5')
            .layoutWeight(1)
          Text('‹')
            .fontSize(20)
            .fontColor('#7FA8FF')
            .padding({ left: 12, right: 12 })
            .onClick((): void => this.shiftBlockDate(b, -1))
          Text(b.date)
            .fontSize(LAYOUT.tray)
            .fontColor('#F2F5FA')
          Text('›')
            .fontSize(20)
            .fontColor('#7FA8FF')
            .padding({ left: 12, right: 12 })
            .onClick((): void => this.shiftBlockDate(b, 1))
        }
        .width('100%')
        .margin({ top: 10 })

        Text('开始时间（HH:MM）')
          .fontSize(LAYOUT.tray)
          .fontColor('#94A0B5')
          .margin({ top: 12, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ChipButton({
            text: '-30 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorStart(b, -30);
          }
          })
          ChipButton({
            text: '-15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorStart(b, -15);
          }
          })
          ChipButton({
            text: '+15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorStart(b, 15);
          }
          })
          ChipButton({
            text: '+30 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorStart(b, 30);
          }
          })
        }
        .width('100%')

        TextInput({ text: this.editorStartText, placeholder: '14:30' })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .onChange((v: string): void => {
            this.editorStartText = v;
          })
          .onSubmit((): void => this.commitEditorStart())
          .onBlur((): void => this.commitEditorStart())
          .margin({ top: 6 })

        Text('时长（分钟）')
          .fontSize(LAYOUT.tray)
          .fontColor('#94A0B5')
          .margin({ top: 8, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ChipButton({
            text: '-15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorDuration(b, -15);
          }
          })
          ChipButton({
            text: '+15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorDuration(b, 15);
          }
          })
          ChipButton({
            text: '+30 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.adjustEditorDuration(b, 30);
          }
          })
        }
        .width('100%')

        TextInput({ text: this.editorDurationText, placeholder: '60' })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .type(InputType.Number)
          .onChange((v: string): void => {
            this.editorDurationText = v;
          })
          .onSubmit((): void => this.commitEditorDuration())
          .onBlur((): void => this.commitEditorDuration())
          .margin({ top: 6 })

        if (this.editorError.length > 0) {
          Text(this.editorError)
            .fontSize(LAYOUT.cardSub)
            .fontColor('#FF8A8A')
            .width('100%')
            .margin({ top: 6 })
        }

        if (b.todoId > 0) {
          Text('截止时间')
            .fontSize(LAYOUT.tray)
            .fontColor('#94A0B5')
            .margin({ top: 12, bottom: 6 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ChipButton({
              text: '今天 23:59',
              selected: false,
              fontSize: LAYOUT.title,
              onTap: (): void => this.setEditorDdl(`${formatDate(today())} 23:59`)
            })
            ChipButton({
              text: '明天 23:59',
              selected: false,
              fontSize: LAYOUT.title,
              onTap: (): void => this.setEditorDdl(`${formatDate(addDays(today(), 1))} 23:59`)
            })
            ChipButton({
              text: '3 天后',
              selected: false,
              fontSize: LAYOUT.title,
              onTap: (): void => this.setEditorDdl(`${formatDate(addDays(today(), 3))} 23:59`)
            })
            ChipButton({
              text: '无截止',
              selected: false,
              fontSize: LAYOUT.title,
              onTap: (): void => this.setEditorDdl('')
            })
          }
          .width('100%')

          Text(this.editorDdlText(b))
            .fontSize(LAYOUT.cardSub)
            .fontColor('#9BA7BD')
            .margin({ top: 4 })

          if (this.editorOtherBlocks().length > 0) {
            Text('这个待办还排在别的时段')
              .fontSize(LAYOUT.tray)
              .fontColor('#94A0B5')
              .margin({ top: 12, bottom: 6 })
            ForEach(this.editorOtherBlocks(), (o: PlanBlock) => {
              Text(`${o.date} ${minToHHmm(o.startMin)}-${minToHHmm(o.endMin)}${o.done ? ' · 已完成' : ''}`)
                .fontSize(LAYOUT.cardSub)
                .fontColor('#C3CDDE')
                .width('100%')
                .padding({ top: 2, bottom: 2 })
            }, (o: PlanBlock) => `eo-${o.id}-${o.done}`)
          }
        }

        Row() {
          Button(b.done ? '取消完成' : '标记完成')
            .backgroundColor(b.done ? 'rgba(255,255,255,0.14)' : '#2E6BE6')
            .fontColor(b.done ? '#C3CDDE' : '#FFFFFF')
            .layoutWeight(1)
            .onClick((): void => {
              this.closeEditor();
              this.toggleBlockDone(b);
            })
          Button('移除此块')
            .backgroundColor('rgba(214,69,69,0.18)')
            .fontColor('#FF8A8A')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.removeBlock(b))
        }
        .width('100%')
        .margin({ top: 18 })

        // 删除整个待办（连它的所有块一起删）—— 不可撤销，所以二次确认。
        // 自动生成（模板）的待办还要进黑名单，否则下次下课又会生成回来。
        if (b.todoId > 0) {
          if (this.editorConfirmDeleteTodo) {
            Row() {
              Text('确定删除整个待办？它在别的日期的块也会一起没。')
                .fontSize(LAYOUT.cardSub)
                .fontColor('#FF8A8A')
                .layoutWeight(1)
              Text('取消')
                .fontSize(LAYOUT.tray)
                .fontColor('#A9B5C9')
                .padding({ left: 10, right: 10 })
                .onClick((): void => {
                  this.editorConfirmDeleteTodo = false;
                })
              Text('删除待办')
                .fontSize(LAYOUT.tray)
                .fontColor('#FFFFFF')
                .backgroundColor('#D64545')
                .borderRadius(8)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .onClick((): void => this.removeTodoFromEditor(b))
            }
            .width('100%')
            .margin({ top: 12 })
          } else {
            Button('删除这个待办')
              .backgroundColor('rgba(214,69,69,0.14)')
              .fontColor('#FF8A8A')
              .width('100%')
              .margin({ top: 10 })
              .onClick((): void => {
                this.editorConfirmDeleteTodo = true;
              })
          }
        }

        Button('完成')
          .backgroundColor('rgba(255,255,255,0.14)')
          .fontColor('#C3CDDE')
          .width('100%')
          .margin({ top: 10 })
          .onClick((): void => this.closeEditor())
      }
      .width('100%')
      .padding(18)
      .glassShell()
      }
      .constraintSize({ maxHeight: '88%' })
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .justifyContent(FlexAlign.Center)
  }

  /** 编辑窗里的截止时间显示 */
  private editorDdlText(b: PlanBlock): string {
    const t: Todo | undefined = this.todoOf(b.todoId);
    if (t === undefined || t.ddl.length === 0) {
      return '当前：无截止';
    }
    return `当前：${t.ddl}`;
  }

  /**
   * 日期栏 —— **悬浮浮窗**（用户点名要做成浮窗的三条之一）。
   *
   * 它原来是流程里的一条 `glassPanel`，会把网格挤下去；现在浮在网格之上，
   * 网格往上滑时会钻到它下面（内容层的 padding 见 `build()`）。
   */
  @Builder
  DayBarFloat() {
    Row() {
      Text('‹')
        .fontSize(22)
        .fontColor('#7FA8FF')
        .padding({ left: 8, right: 8 })
        .onClick((): void => this.goDay(-1))
      Column() {
        Text(this.headerText())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
        Text(relativeDayText(parseDate(this.date)))
          .fontSize(LAYOUT.cardSub)
          .fontColor('#94A0B5')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      Text('›')
        .fontSize(22)
        .fontColor('#7FA8FF')
        .padding({ left: 8, right: 8 })
        .onClick((): void => this.goDay(1))
      // 视图切换：日 | 三日。
      // ⚠️ 用户明确删掉了整周列表视图（"功能鸡肋"），不要再加第三档。
      ChipButton({
        text: '日',
        selected: this.viewCols <= COLS_DAY,
        fontSize: LAYOUT.cardSub,
        onTap: (): void => this.setViewCols(COLS_DAY)
      })
      ChipButton({
        text: '三日',
        selected: this.viewCols === COLS_THREE,
        fontSize: LAYOUT.cardSub,
        onTap: (): void => this.setViewCols(COLS_THREE)
      })
      Text('今天')
        .fontSize(LAYOUT.tray)
        .fontColor('#7FA8FF')
        .margin({ left: 4 })
        .onClick((): void => this.goToday())
    }
    .width('100%')
    .padding({ left: 8, right: 12, top: 10, bottom: 8 })
    .glassSheet()
  }

  /**
   * 三日视图的列头（每列显示自己的日期）。
   *
   * ⚠️ **它不做成悬浮浮窗**（用户 2026-10-14 明确："三日图界面最上面的三个日期不要做成悬浮窗了，
   * 会出去"）：它必须和网格的三列严格对齐，而悬浮面板左右留边 + 外层 padding 再缩一次，
   * 列宽就对不上了（实测列头比网格右偏 7 / 31 / 31 px）。
   * 现在它回到**滚动内容里**，作为表格自己的表头，用和网格同源的几何
   * （`AXIS_W` 空位 + `layoutWeight(1)` 均分），上下滚时跟着表格一起走。
   */
  @Builder
  ColHeadRow() {
    Row() {
      Column()
        .width(AXIS_W)
      ForEach(this.colDates, (cd: string, ci: number) => {
        Column() {
          Text(columnHeaderText(cd))
            .fontSize(LAYOUT.tray)
            // 三列都可操作，所以侧列不再画成"灰掉不可用"；
            // 只有"当前查看日"那一列加粗 + 灰底（它是 ‹ › 的基准）
            .fontWeight(ci === this.centerCol() ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(ci === this.centerCol() ? '#F2F5FA' : '#A9B5C9')
          if (cd === formatDate(today())) {
            Text('今天')
              .fontSize(LAYOUT.cardSub)
              .fontColor('#7FA8FF')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        // 固定高度：中间那列多一行「今天」，不定高的话三列高度不齐、
        // 网格顶边会看起来是斜的
        .height(H_COLHEAD)
        // ⚠️ 深色下这条和浅色版**方向相反**：浅色版标记"今天"用的是
        // 「比纯白更灰」（`#F5F6F8` vs `#FFFFFF`），在深色底上"更灰"= 更暗，
        // 会被读成"禁用"。所以改成**中间列比两侧亮**才是"高亮"。
        .backgroundColor(ci === this.centerCol() ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.03)')
      }, (cd: string) => `colh-${cd}`)
    }
    .width('100%')
    .glassPanel()
  }

  build() {
    Stack() {
      Column() {
        // 时间网格
        Scroll(this.gridScroller) {
          Column() {
            // 表格自己的表头行：跟着网格一起滚（不是浮窗）
            if (this.viewCols > COLS_DAY) {
              this.ColHeadRow()
            }
            Stack({ alignContent: Alignment.TopStart }) {
              this.HourLines()
              if (this.viewCols > COLS_DAY) {
                this.ColumnSeparators()
              }
              // 每一列各自画自己的课程灰带与块。
              // 单日视图 viewCols=1，这段退化成和以前完全一样的一列。
              ForEach(this.colDates, (cd: string, ci: number) => {
                ForEach(this.sessionsOfCol(ci), (s: CourseSession) => {
                  this.ClassBlock(s, ci)
                }, (s: CourseSession) => `cls-${ci}-${s.course.id}-${s.startSection}`)
              }, (cd: string) => `colcls-${cd}`)
              // 被拖走的块留在原位的虚线空位：让用户看清"这一块是从哪儿抽出来的"
              if (this.dragBlockId > 0) {
                this.DragGhost()
              }
              ForEach(this.colDates, (cd: string, ci: number) => {
                ForEach(this.blocksOfCol(ci), (b: PlanBlock) => {
                  this.PlanBlockView(b, ci)
                }, (b: PlanBlock) => `blk-${ci}-${b.id}-${b.startMin}-${b.endMin}-${b.done}`)
              }, (cd: string) => `colblk-${cd}`)
              // 截止标记只画在当前查看日那一列：它是"今天要交什么"的提示，
              // 侧列本来就是只读展示，铺满三列反而更乱
              this.DdlMarkers()
            }
            .width('100%')
            .height(GRID_H)
            .onAreaChange((oldArea: Area, newArea: Area): void => {
              const y: Length | undefined = newArea.globalPosition.y;
              if (typeof y === 'number') {
                this.gridTop = y;
              }
            })
            .onClick((event: ClickEvent): void => this.onGridTap(event))
              .onDrop((event: DragEvent, extraParams: string): void => this.onPoolDrop(event))
            }
          }
          .width('100%')
          // ⚠️ 给上面那叠浮窗让位，而且必须加在**滚动内容**上（不是视口上）：
          // 这样网格往上滑时会钻到日期栏/页头下面，滑到底时最后一行也完全露得出来。
          // 上下都给浮窗让位：上面是日期栏，下面是"待安排托盘 + 导航栏"。
          // 加在**滚动内容**上，网格才能滑到它们下面，同时最后一行也滑得出来。
          .padding({
            top: this.topBarsBlockH() + FLOAT_GAP,
            // ⚠️ `+ DDL_MARK_ALLOW`：截止标记会从网格底边往下挂出一行，
            // 不留余量就会被悬浮货架盖掉下半截（用户实测发现的）
            bottom: this.bottomInset + FLOAT_GAP + this.trayH + FLOAT_GAP + DDL_MARK_ALLOW
          })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        // 长按武装之后禁止 Scroll 自己滚动 —— 移动块时屏幕要钉住，
        // 只有块靠近上/下边缘时由 updateEdgeScroll() 用代码滚。
        .enableScrollInteraction(!this.gridScrollLocked)
        // 量出网格**可视区**的上下边界（窗口坐标），拖动时用它判断是否进入边缘自动滚动区。
        // 注意量的是 Scroll 本身（视口），不是里面那个 1080vp 高的内容 Stack。
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          const top: Length | undefined = newArea.globalPosition.y;
          const h: Length | undefined = newArea.height;
          // 列几何要用视口宽度与左边（都是 vp）
          const left: Length | undefined = newArea.globalPosition.x;
          const w: Length | undefined = newArea.width;
          if (typeof top === 'number') {
            this.gridViewTop = top;
          }
          if (typeof top === 'number' && typeof h === 'number') {
            this.gridViewBottom = top + h;
          }
          if (typeof left === 'number') {
            this.gridLeft = left;
          }
          if (typeof w === 'number') {
            this.gridW = w;
          }
        })

      }
      .width('100%')
      .height('100%')

      // ================= 浮窗层（不参与内容布局）=================
      // 日期栏浮在网格之上；网格往上滑时会钻到它下面。
      Column() {
        // ⚠️ 定位壳：根 Stack 默认居中排子节点，浮窗必须靠"满屏 + 顶到上边"钉住
        Column() {
          this.DayBarFloat()
        }
        .width('100%')
        // ⚠️ `+ FLOAT_GAP`：用户要求"多个玻璃浮窗相连时中间要有空行"，
        // Index 的页头正好压在 topInset 处，不留缝两条玻璃就贴在一起了
        .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, top: this.topInset + FLOAT_GAP })
        // 量出这叠浮窗的总高度：网格内容的 padding 与"边缘自动滚动"的顶边都用它
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          const h: Length | undefined = newArea.height;
          if (typeof h === 'number' && h > 0) {
            this.topBarsH = h;
          }
        })
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Transparent)

      // 底部：待安排托盘 —— **悬浮货架**，浮在悬浮导航栏之上。
      // 它和导航栏刻意用不同材质（压暗 + 小一号圆角 + 收敛阴影），
      // 这样两层叠在一起时有层次感，而不是两块一样的玻璃（用户要求）。
      Column() {
        this.TodoPool()
      }
      .width('100%')
      .height('100%')
      .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, bottom: this.bottomInset + FLOAT_GAP })
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      // 瞬时提示：悬浮在网格上方的深色小胶囊，**完全不参与布局**，
      // 所以它出现/消失不会让时间网格上下跳动（这正是原来那条蓝色横幅的隐藏 bug）。
      if (this.hint.length > 0) {
        Column() {
          Text(this.hint)
            .fontSize(LAYOUT.cardSub)
            .fontColor('#FFFFFF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .backgroundColor('rgba(12,18,28,0.86)')
        .borderRadius(16)
        .margin({ left: 24, right: 24 })
        // 只显示、绝不吞触摸事件，否则会挡住下面的滑动与点击
        .hitTestBehavior(HitTestMode.None)
        // 提示要落在那叠浮窗**下面**：它是浮动的，所以这里用浮窗的实际高度定位
        .position({ x: 24, y: this.topBarsBlockH() + 8 })
      }

      // 双指缩放时屏幕正中的深色 ±NN min 提示。
      // hitTestBehavior(None) 很关键：它只是显示，绝不能把手指的触摸事件吃掉，
      // 否则提示一出现缩放就断了。
      if (this.pinchLabel.length > 0) {
        Column() {
          Text(this.pinchLabel)
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 24, right: 24, top: 14, bottom: 14 })
        .backgroundColor('rgba(12,18,28,0.88)')
        .borderRadius(16)
        .hitTestBehavior(HitTestMode.None)
      }

      // 编辑窗遮罩：点窗外的深色区域 = 不保存直接退出（用户要求的行为）
      if (this.editingBlock !== undefined) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => this.closeEditor())
        this.BlockEditor(this.editingBlock)
      }
    }
    .width('100%')
    .height('100%')
    // 底色交给 PageBackground；网格本身不做玻璃（要读准时间）
    .backgroundColor(Color.Transparent)
  }
}
