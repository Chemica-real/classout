import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, CourseSession, PlanBlock, RestWindow, Semester, SessionOverride,
  SessionRule, SectionTime, Todo, TodoStatus, VirtualLesson } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { sessionsOnDate } from '../domain/Timetable';
import { generateForLesson } from '../domain/TodoGenerator';
import { TimeAxis, DEFAULT_AXIS, MIN_BLOCK_MIN, allBlocksDone,
  dragOffsetWithScroll, dropRange, edgeScrollDirection, durationToH, findFreeSlot, moveRange, normalizeDuration,
  resizeRange,
  selectPoolTodos, sortPoolTodos } from '../domain/PlanMath';
import { addDays, formatDate, minToHHmm, parseDate, relativeDayText, today, WEEKDAY_CN,
  weekdayOf } from '../util/DateUtil';
import { ChipButton } from './ChipButton';
import { hapticLongPress } from '../util/Haptics';

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
 * ★ 字号试版开关（临时，只为给用户看 13/14/15vp 三档对比截图，见 PLAN_REDESIGN.md §7）
 *
 * 改这一个数字就能重建出另一档，不用改散落各处的 fontSize。
 * 试版结束后这套常量保留（它本来就是好实践），但 SELECTED 会定成一档。
 *
 * 每档的构成：
 *   title  = 网格里块标题（待办/课时）
 *   sub    = 块副文字（时间范围）、位置
 *   hour   = 时间轴刻度
 *   tray   = 待安排格里的文字
 *   cardSub= 次级说明文字（"预计 N 分钟"等）
 */
class LayoutSpec {
  title: number;
  sub: number;
  hour: number;
  tray: number;
  cardSub: number;
  chip: number;
  /**
   * 短块（放不下「标题+副文字」两行时）用的紧凑字号。
   * 用户明确要求：「长度 15min 的计划可以例外地把字体放小以便包含」。
   * 15 分钟的块按 1 分钟 = 1vp 只有 13vp 高，正文字号必然溢出，
   * 所以在**不改变块的真实高度**的前提下把内容压进去。
   */
  compact: number;

  constructor(title: number, sub: number, hour: number, tray: number,
    cardSub: number, chip: number, compact: number) {
    this.title = title;
    this.sub = sub;
    this.hour = hour;
    this.tray = tray;
    this.cardSub = cardSub;
    this.chip = chip;
    this.compact = compact;
  }
}

const LAYOUT_A: LayoutSpec = new LayoutSpec(12, 9, 10, 12, 10, 12, 10);
const LAYOUT_B: LayoutSpec = new LayoutSpec(13, 10, 11, 13, 11, 13, 10);
const LAYOUT_C: LayoutSpec = new LayoutSpec(14, 11, 12, 14, 12, 14, 10);
const LAYOUT_D: LayoutSpec = new LayoutSpec(15, 12, 13, 15, 12, 14, 11);

/** ← 改这里切换档位（A=现状 12/9，B=13/10，C=14/11，D=15/12） */
const LAYOUT: LayoutSpec = LAYOUT_C;

/**
 * 块的最小**视觉**高度（vp），不是最小**时长**。
 *
 * ⚠️ 这里曾经算错两次，记下来：
 *   1. 最初把分钟常量 MIN_BLOCK_MIN 当 vp 用（预览 15vp、松手 13vp），前后不一致；
 *   2. 后来改成「装得下标题+副文字」的高度（46vp；那个函数已废弃删除）——
 *      但 1 分钟 = 1vp 是全项目约定，块高必须等于真实时长。
 *      给 15 分钟的块画 46vp 会让它盖住后面 31 分钟、把那些时段点不到。
 *
 * 正确的最小值只用来**防止拖动时块塌成不可见**，13 分钟的块就是 13vp。
 * 装不下的内容是靠紧凑排版（LAYOUT.compact）压进去的，不是靠把块画高。
 */
const MIN_VISIBLE_H: number = 6;

/**
 * 紧凑块的最小高度：**文字的行高**，不是时长。
 *
 * 13vp 的块（15 分钟）装不下一整行字 —— 实测 10vp 字号的行高约 14–16vp，
 * 用 13vp 会把字上下各切掉一截。所以紧凑块允许比它的时长高一点点（最多 3vp），
 * 代价是它下方的 3vp 会被盖住；这是用户明确要的取舍
 * （「长度 15min 的计划可以例外地把字体放小以便包含」）。
 */
function compactMinH(): number {
  return Math.ceil(LAYOUT.compact * 1.4);
}

/** 块高度小于此值时改用紧凑排版（单行：标题 + 时间，去掉完成圆圈） */
function compactThreshold(): number {
  return Math.ceil(LAYOUT.title * 1.35) + Math.ceil(LAYOUT.sub * 1.35);
}

@Component
export struct PlanDayView {
  @Prop semesterId: number;

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
  @State editingBlock: PlanBlock | undefined = undefined;
  @State hint: string = '';
  /** 正在被拖动的块与实时位移（拖拽中只改预览，松手才落库） */
  @State dragBlockId: number = 0;
  @State dragOffsetY: number = 0;
  @State resizeBlockId: number = 0;
  @State resizeOffsetY: number = 0;
  /** 从「待安排」拖进网格时携带的待办 id */
  @State dragTodoId: number = 0;
  /** 从「待安排」拖进网格时携带的虚拟课时 id */
  @State dragLessonId: number = 0;

  /**
   * 已「武装」的块：**长按之后**才允许拖动。
   *
   * 为什么要这一步：默认上下滑动切时间轴是这个页面的主要操作，
   * 如果手指一落在块上就能拖，想滚动的人会不断误拖（用户的明确要求）。
   * 长按给一次振动 + 描边，告诉用户"现在可以拖了"。
   * 点一下空白处、或拖完松手，就解除武装。
   */
  @State armedMoveId: number = 0;
  /** 已武装的底边把手（长按把手后允许改时长） */
  @State armedResizeId: number = 0;
  /** 本次触摸的按下点（**窗口坐标**）。位移按窗口坐标算，长按后网格滚了也不会跳 */
  @State pressStartY: number = 0;
  /** 网格的 Scroller：拖动块靠近上/下边缘时用它自动滚时间轴 */
  private gridScroller: Scroller = new Scroller();
  /** 边缘自动滚动的重复定时器 id（-1 = 没在滚） */
  private edgeTimer: number = -1;
  /** 当前触摸点（窗口 y）。自动滚动用它判断在不在边缘区 */
  private touchWinY: number = 0;
  /** 开始移动/改时长那一刻的网格滚动位置。自动滚动产生的偏移量用它算 */
  private dragStartScroll: number = 0;
  /** 网格**可视区**上边界（窗口坐标） */
  /** 武装拖动期间是否锁住 Scroll 自身滚动（锁住后只允许边缘自动滚） */
  @State gridScrollLocked: boolean = false;
  @State gridViewTop: number = 0;
  /** 网格**可视区**下边界（窗口坐标） */
  @State gridViewBottom: number = 0;
  private pressActive: boolean = false;
  /**
   * 最后一次已知的触摸 y（窗口坐标）。
   * 定时器醒来时用它判断"用户是不是已经移开了" —— 真滚动时前 450ms 早就移出容差了，
   * 所以这时**不该武装、更不该振动**（实测慢速拖拽会白振一次）。
   */
  private lastTouchY: number = 0;
  /** 网格在窗口里的顶边（把窗口坐标换算成网格内坐标用） */
  @State gridTop: number = 0;

  aboutToAppear(): void {
    this.date = formatDate(today());
    this.load();
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
    const overrides: SessionOverride[] = await TimetableRepo.listOverridesBetween(ctx, this.date, this.date);
    const d: Date = parseDate(this.date);
    this.sessions = sessionsOnDate(sem, this.courses, rules, overrides, times, d);
    this.blocks = await TodoRepo.listBlocksOn(ctx, this.date);
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
      return '#7C8AA0';
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

  private placeLesson(l: VirtualLesson, startMin: number, duration: number): void {
    this.doPlaceLesson(l, startMin, duration).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'place lesson failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doPlaceLesson(l: VirtualLesson, startMin: number, duration: number): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const block: PlanBlock = {
      id: 0,
      todoId: 0,
      lessonId: l.id,
      date: this.date,
      startMin: startMin,
      endMin: startMin + duration,
      done: false
    };
    await TodoRepo.insertBlock(ctx, block);
    this.hint = `已安排：${this.lessonTitle(l)}`;
    await this.reload();
  }

  private autoPlaceLesson(l: VirtualLesson): void {
    const weekday: number = weekdayOf(parseDate(this.date));
    const isToday: boolean = this.date === formatDate(today());
    const from: number = isToday ? this.nowMinute() : AXIS.startMin;
    const slot: number = findFreeSlot(AXIS, this.busyRanges(), this.restRanges(weekday), LESSON_MIN, from);
    if (slot < 0) {
      this.hint = '这天（或剩余时间）排不下了，换一天试试';
      return;
    }
    this.placeLesson(l, slot, normalizeDuration(LESSON_MIN));
    this.hint = `已排到 ${minToHHmm(slot)}`;
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

  /** 网格上的空白点击：若已选中待办，就在点击处落一个块；否则解除块的武装状态 */
  private onGridTap(event: ClickEvent): void {
    if (this.selectedTodoId === 0) {
      if (this.armedMoveId > 0 || this.armedResizeId > 0) {
        this.disarm();
        this.hint = '';
        return;
      }
      this.hint = '拖下面的待办到网格上放下；或先点选一条待办，再点空白处。';
      return;
    }
    const todo: Todo | undefined = this.selectedTodo();
    if (todo === undefined) {
      return;
    }
    const range: number[] = dropRange(AXIS, event.y, todo.estimateMin);
    this.place(todo, range[0], range[1] - range[0]);
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

    if (lessonId > 0) {
      const l: VirtualLesson | undefined = this.lessonOf(lessonId);
      if (l === undefined) {
        return;
      }
      const range: number[] = dropRange(AXIS, localY, LESSON_MIN);
      this.placeLesson(l, range[0], range[1] - range[0]);
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
    this.place(todo, range[0], range[1] - range[0]);
  }

  // ---- 拖拽改时间 ----

  /**
   * 拖动块时，触摸点进入距上/下边缘这么近的范围就自动滚时间轴。
   * 用户要求：「长按移动块的时候屏幕不应该滚动，除非我把块接近最上/下代表我想滚动时间」。
   */
  private static readonly EDGE_ZONE: number = 60;
  /** 自动滚动每一步的距离（vp） */
  private static readonly EDGE_STEP: number = 16;
  /** 自动滚动的重复间隔（ms） */
  private static readonly EDGE_INTERVAL: number = 50;

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
    this.pressActive = true;
    // ★ 滚动基准在**按下**时记录，且整个拖动期间**不再改**。
    //   块位移公式里的 touchDeltaY 是以按下点为基准的，
    //   若基准滚动位置改成"武装那一刻"，两者基准不一致 → 块会漂。
    this.dragStartScroll = this.gridScroller.currentOffset().yOffset;
    this.disarm();
  }

  /**
   * 武装移动（由 `parallelGesture` 的 LongPressGesture 调用）。
   *
   * ★ 为什么最后选了 `parallelGesture` 而不是 onTouch + 自己计时：
   *   自己计时的方案需要**判断用户是不是在滚动**才能取消长按，
   *   而实测"父级 Scroll 接管手势后，子组件的 onTouch 收不到后续 Move 事件"，
   *   于是无法区分"按住不动"和"正在滚动"，慢速滚动会白振一次。
   *   `parallelGesture` 让长按**和 Scroll 并行识别**，被 Scroll 抢走时系统直接 Cancel 它，
   *   取消逻辑由框架负责，不依赖我能否收到 Move 事件。
   */
  private armMove(b: PlanBlock): void {
    // 武装即禁用 Scroll 自己滚 —— 这样长按之后拖动块时，时间轴会被钉住，
    // 只有 updateEdgeScroll() 在边缘处用代码滚。
    this.gridScrollLocked = true;
    this.armedMoveId = b.id;
    this.armedResizeId = 0;
    hapticLongPress();
    this.hint = '已激活，上下拖动可以改时间；点空白处取消';
  }

  private armResize(b: PlanBlock): void {
    this.gridScrollLocked = true;
    this.armedResizeId = b.id;
    this.armedMoveId = 0;
    hapticLongPress();
    this.hint = '已激活，上下拖动底边可以改时长';
  }

  /**
   * 边缘自动滚动：拖动块/改时长时，触摸点靠近上/下边缘就让时间轴自己滚。
   *
   * 为什么需要它：移动块时屏幕是钉住的（用户要求），
   * 但如果块要挪到当前视口之外，没有自动滚动就根本挪不过去。
   */
  private updateEdgeScroll(): void {
    if (this.dragBlockId === 0 && this.resizeBlockId === 0) {
      this.stopEdgeScroll();
      return;
    }
    const span: number = this.gridViewBottom - this.gridViewTop;
    if (span <= 0) {
      this.stopEdgeScroll();
      return;
    }
    const dir: number = edgeScrollDirection(this.touchWinY, this.gridViewTop,
      this.gridViewBottom, PlanDayView.EDGE_ZONE);
    if (dir === 0) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeTimer !== -1) {
      return;   // 已经在滚了
    }
    this.edgeTimer = setInterval((): void => {
      const step: number = dir * PlanDayView.EDGE_STEP;
      this.gridScroller.scrollBy(0, step);
      // ★ 必须在这里重算 offsetY，而且要和 MOVE 用**同一个公式、同一个基准**。
      //
      //   为什么非在这里不可：**手指停住不动时不再产生 Move 事件**，
      //   而自动滚动还在继续。若不在这里重算，块就不会跟着补偿，
      //   它会留在网格坐标里、跟着视图一起跑 —— 用户实测：
      //   「手指停在 173.958 不动，offsetY 却从 -195 一路涨到 -50.79」，
      //   表现为块向下漂，而且**松手时 endMove 会用这个漂掉的 offsetY 落库**，
      //   块的时间会跳到约 2.4 小时之前（数据错误，不只是手感）。
      //
      //   曾经把它删掉过，理由是"和 MOVE 重复补偿"—— 那是错的：
      //   这两个地方是**同一个公式的两个执行时机**（手指动 / 手指停），
      //   不是两次叠加。删掉它反而把"手指停住"这个洞暴露出来。
      const dy: number = this.lastTouchY - this.pressStartY;
      const scrolled: number = this.gridScroller.currentOffset().yOffset - this.dragStartScroll;
      this.dragOffsetY = dragOffsetWithScroll(dy, scrolled);
      this.updateEdgeScroll();
    }, PlanDayView.EDGE_INTERVAL);
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
    const dy: number = this.lastTouchY - this.pressStartY;

    // 没被长按武装 → 什么都不做，让 Scroll 正常滚动。
    // （武装由 parallelGesture 的 LongPressGesture 负责，见 armMove 的注释）
    if (this.armedMoveId !== b.id) {
      return;
    }
    // 已武装：拦下事件，别让父级 Scroll 跟着滚（用户要求：
    // 移动块时屏幕不动，只有块接近上/下边缘才滚时间轴）
    event.stopPropagation();
    this.dragBlockId = b.id;
    // 补偿网格滚动：块要钉在手指下，就必须减去"网格自己滚掉的那部分"。
    // 否则网格一滚，块相对网格就跑了（等于块的开始时间被偷偷改掉）。
    const scrolled: number = this.gridScroller.currentOffset().yOffset - this.dragStartScroll;
    this.dragOffsetY = dragOffsetWithScroll(dy, scrolled);
    this.updateEdgeScroll();
  }

  /** 触摸抬起：位移落库、解除武装 */
  private onBlockTouchUp(b: PlanBlock): void {
    hilog.info(DOMAIN, TAG, 'DRAG up offsetY=%{public}d touched=%{public}s scrolled=%{public}d',
      this.dragOffsetY, `${this.armedMoveId > 0}`, this.gridScroller.currentOffset().yOffset);
    this.pressActive = false;
    this.stopEdgeScroll();
    if (this.dragBlockId === b.id) {
      this.endMove(b);
    }
  }

  private onBlockTouchCancel(): void {
    this.pressActive = false;
    this.stopEdgeScroll();
    this.dragBlockId = 0;
    this.dragOffsetY = 0;
  }

  /** 底边把手：与块同理，只是走改时长 */
  private onHandleTouchDown(b: PlanBlock, event: TouchEvent): void {
    this.pressStartY = event.touches.length > 0 ? event.touches[0].windowY : 0;
    this.lastTouchY = this.pressStartY;
    this.pressActive = true;
    this.dragStartScroll = this.gridScroller.currentOffset().yOffset;
    this.disarm();
  }

  private onHandleTouchMove(b: PlanBlock, event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    this.lastTouchY = event.touches[0].windowY;
    this.touchWinY = this.lastTouchY;
    const dy: number = this.lastTouchY - this.pressStartY;

    if (this.armedResizeId !== b.id) {
      return;
    }
    event.stopPropagation();
    this.resizeBlockId = b.id;
    const scrolled2: number = this.gridScroller.currentOffset().yOffset - this.dragStartScroll;
    this.resizeOffsetY = dragOffsetWithScroll(dy, scrolled2);
    this.updateEdgeScroll();
  }

  private onHandleTouchUp(b: PlanBlock): void {
    this.pressActive = false;
    this.stopEdgeScroll();
    if (this.resizeBlockId === b.id) {
      this.endResize(b);
    }
  }

  private onHandleTouchCancel(): void {
    this.pressActive = false;
    this.stopEdgeScroll();
    this.resizeBlockId = 0;
    this.resizeOffsetY = 0;
  }

  private disarm(): void {
    this.armedMoveId = 0;
    this.armedResizeId = 0;
    this.gridScrollLocked = false;
  }

  private beginMove(b: PlanBlock): void {
    // 守卫：没长按过就不给拖，否则想滚动时间轴的人会误拖色块
    if (this.armedMoveId !== b.id) {
      return;
    }
    this.dragBlockId = b.id;
    this.dragOffsetY = 0;
  }

  private updateMove(dy: number): void {
    this.dragOffsetY = dy;
  }

  private endMove(b: PlanBlock): void {
    if (this.dragBlockId === 0) {
      return;   // 没真正开始拖（没武装），别落库
    }
    const range: number[] = moveRange(AXIS, b.startMin, b.endMin, this.dragOffsetY);
    this.dragBlockId = 0;
    this.dragOffsetY = 0;
    this.disarm();
    b.startMin = range[0];
    b.endMin = range[1];
    this.persistBlock(b);
    this.hint = `挪到 ${minToHHmm(b.startMin)}-${minToHHmm(b.endMin)}`;
  }

  private beginResize(b: PlanBlock): void {
    // 守卫：必须先长按底边把手
    if (this.armedResizeId !== b.id) {
      return;
    }
    this.resizeBlockId = b.id;
    this.resizeOffsetY = 0;
  }

  private updateResize(dy: number): void {
    this.resizeOffsetY = dy;
  }

  private endResize(b: PlanBlock): void {
    if (this.resizeBlockId === 0) {
      return;   // 没真正开始拖（没武装），别落库
    }
    const range: number[] = resizeRange(AXIS, b.startMin, b.endMin, this.resizeOffsetY);
    this.resizeBlockId = 0;
    this.resizeOffsetY = 0;
    this.disarm();
    b.startMin = range[0];
    b.endMin = range[1];
    this.persistBlock(b);
    this.hint = `时长改为 ${b.endMin - b.startMin} 分钟`;
  }

  private persistBlock(b: PlanBlock): void {
    this.doPersist(b).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'persist block failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doPersist(b: PlanBlock): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TodoRepo.updateBlock(ctx, b);
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
      this.hint = '这天（或剩余时间）排不下了，换一天试试';
      return;
    }
    this.place(t, slot, normalizeDuration(t.estimateMin));
    this.hint = `已排到 ${minToHHmm(slot)}`;
  }

  private place(todo: Todo, startMin: number, duration: number): void {
    this.doPlace(todo, startMin, duration).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'place block failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doPlace(todo: Todo, startMin: number, duration: number): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const block: PlanBlock = {
      id: 0,
      todoId: todo.id,
      lessonId: 0,
      date: this.date,
      startMin: startMin,
      endMin: startMin + duration,
      done: false
    };
    await TodoRepo.insertBlock(ctx, block);
    this.hint = `已安排：${todo.title}`;
    await this.reload();
  }

  private adjustBlock(block: PlanBlock, deltaStart: number, deltaEnd: number): void {
    this.doAdjust(block, deltaStart, deltaEnd).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'adjust block failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doAdjust(block: PlanBlock, deltaStart: number, deltaEnd: number): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    let s: number = block.startMin + deltaStart;
    let e: number = block.endMin + deltaEnd;
    if (s < AXIS.startMin) {
      s = AXIS.startMin;
    }
    if (e > AXIS.endMin) {
      e = AXIS.endMin;
    }
    if (e - s < MIN_BLOCK_MIN) {
      return;
    }
    block.startMin = s;
    block.endMin = e;
    await TodoRepo.updateBlock(ctx, block);
    await this.reload();
  }

  private toggleBlockDone(block: PlanBlock): void {
    this.doToggle(block).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'toggle block failed: %{public}s', JSON.stringify(e));
    });
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
            this.hint = `「${this.lessonTitle(l)}」完成，已生成 ${created} 条待办，去『待办』确认`;
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
    await TodoRepo.deleteBlock(ctx, block.id);
    this.editingBlock = undefined;
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
    return durationToH(b.endMin - b.startMin) - 2;
  }

  private blockH(b: PlanBlock): number {
    const timed: number = durationToH(b.endMin - b.startMin) - 2;
    if (this.resizeBlockId === b.id) {
      const preview: number = timed + this.resizeOffsetY;
      return preview < MIN_VISIBLE_H ? MIN_VISIBLE_H : preview;
    }
    if (timed < compactThreshold()) {
      return Math.max(timed, compactMinH());
    }
    return timed;
  }

  // ---------------- UI ----------------

  @Builder
  HourLines() {
    Column() {
      ForEach(this.hourMarks(), (mark: number) => {
        Row() {
          Text(minToHHmm(mark))
            .fontSize(LAYOUT.hour)
            .fontColor('#B0B8C4')
            .width(40)
            .textAlign(TextAlign.End)
          Divider()
            .color('#EDEFF3')
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
  ClassBlock(s: CourseSession) {
    Column() {
      Text(s.course.shortName.length > 0 ? s.course.shortName : s.course.name)
        .fontSize(LAYOUT.title)
        .fontColor('#5A6478')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.hOf(s.startMin, s.endMin) > 40 && s.location.length > 0) {
        Text(s.location)
          .fontSize(LAYOUT.sub)
          .fontColor('#98A2B3')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height(this.hOf(s.startMin, s.endMin) - 2)
    .padding({ left: 6, right: 6, top: 2 })
    .backgroundColor('#E8ECF3')
    .borderRadius(6)
    .position({ x: 46, y: this.yOf(s.startMin) })
  }

  @Builder
  PlanBlockView(b: PlanBlock) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.blockTimedH(b) >= compactThreshold()) {
        // ---- 常规排版：完成圆圈 + 标题 + 时间（两行）----
        Row() {
          Text(b.done ? '●' : '○')
            .fontSize(LAYOUT.title)
            .fontColor(b.done ? '#2E6BE6' : '#FFFFFF')
            .margin({ right: 6 })
            .onClick((): void => this.toggleBlockDone(b))
          Column() {
            Text(this.blockTitle(b))
              .fontSize(LAYOUT.title)
              .fontWeight(FontWeight.Medium)
              .fontColor('#12161F')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${minToHHmm(b.startMin)}-${minToHHmm(b.endMin)}`)
              .fontSize(LAYOUT.sub)
              .fontColor('#3C4657')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 6, top: 3 })
        .backgroundColor(this.colorOf(this.blockCourseId(b)))
        .opacity(b.done ? 0.5 : 0.95)
        .borderRadius(6)
        .border({
          width: this.dragBlockId === b.id || this.resizeBlockId === b.id ? 2 : 0,
          color: '#12161F'
        })
        .onClick((): void => {
          this.disarm();
          this.editingBlock = b;
        })
      } else {
        // ---- 紧凑排版：单行「标题 + 时间」，字更小 ----
        // 15 分钟的块只有 13vp 高，两行放不下。这里不画完成圆圈
        //（点开面板也能标记完成），把空间留给标题和时间。
        Row() {
          Text(this.blockTitle(b))
            .fontSize(LAYOUT.compact)
            .fontWeight(FontWeight.Medium)
            .fontColor('#12161F')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          // 紧凑块只显示**开始时间**：块本身很窄放不下「12:00-12:15」整段，
          // 折行后下半会被块裁掉。结束时间由块高能看出来，点开面板也有完整区间。
          Text(minToHHmm(b.startMin))
            .fontSize(Math.max(9, LAYOUT.compact - 1))
            .fontColor('#3C4657')
            .margin({ left: 6 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 7, right: 5 })
        .backgroundColor(this.colorOf(this.blockCourseId(b)))
        .opacity(b.done ? 0.5 : 0.95)
        .borderRadius(6)
        .border({
          width: this.dragBlockId === b.id || this.resizeBlockId === b.id ? 2 : 0,
          color: '#12161F'
        })
        .onClick((): void => {
          this.disarm();
          this.editingBlock = b;
        })
      }

      // 底边把手：按住上下拖 = 改时长。
      // ★ 只有块够高才画它：13vp 的块再塞 12vp 的把手，会把正文挤出去。
      //   紧凑块的改时长走点开面板（面板里有 -15/+15 分钟那些按钮）。
      if (this.blockTimedH(b) >= compactThreshold()) {
        Row() {
          Text('⋯')
            .fontSize(LAYOUT.chip)
            .fontColor('#12161F')
        }
        .width('100%')
        .height(12)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#00000018')
        .borderRadius({ bottomLeft: 6, bottomRight: 6 })
        // 用 onTouch 而不是手势：挂 PanGesture 会和父级 Scroll 抢手势，
        // 抢到手后没武装又什么都不做 → 从把手/块上起手就滚不动（用户实测报过）。
        .parallelGesture(
          LongPressGesture({ repeat: false, duration: 400, fingers: 1 })
            .onAction((): void => this.armResize(b))
        )
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.onHandleTouchDown(b, event);
          } else if (event.type === TouchType.Move) {
            this.onHandleTouchMove(b, event);
          } else if (event.type === TouchType.Up) {
            this.onHandleTouchUp(b);
          } else {
            this.onHandleTouchCancel();
          }
        })
      }
    }
    .width('100%')
    .height(this.blockH(b))
    .position({ x: 46, y: this.blockY(b) })
    .zIndex(this.dragBlockId === b.id || this.resizeBlockId === b.id ? 10 : 1)
    // 同上：用 onTouch，**不注册任何手势**，所以完全不和父级 Scroll 竞争。
    // 手指落在块上立刻上划 → 位移超容差 → 判定为滑动 → Scroll 正常滚动。
    // 按住不动 400ms → 就地武装 → 之后上下拖才是移动这个块。
    // 长按武装：用 `parallelGesture` 而不是 `gesture`。
    // 关键区别：它**不参与父级 Scroll 的手势竞争** ——
    // 用户想滚动时 Scroll 照常接管（长按被系统 Cancel，不会白振），
    // 用户按住不动时它触发并把块武装成"可拖动"。
    .parallelGesture(
      LongPressGesture({ repeat: false, duration: 400, fingers: 1 })
        .onAction((): void => this.armMove(b))
    )
    // onTouch 只负责"已武装之后的位移"。它不注册手势，所以不抢占 Scroll。
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
            .fontColor('#C0392B')
        }
        .width('100%')
        .padding({ left: 6, top: 1, bottom: 1 })
        .backgroundColor('#FDECEA')
        .borderRadius(4)
        .position({ x: 46, y: this.yOf(this.ddlMinute(t)) })
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
          .fontColor('#12161F')
        Blank()
        if (this.selectedTodoId > 0) {
          Text('已选中，点网格空白处放下')
            .fontSize(LAYOUT.cardSub)
            .fontColor('#2E6BE6')
        } else {
          Text('拖动 / 点选 / ⚡ 一键找空档')
            .fontSize(LAYOUT.tray)
            .fontColor('#98A2B3')
        }
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.poolTodos().length === 0) {
        Text('没有待安排的事项。先去『待办』里确认几条。')
          .fontSize(LAYOUT.tray)
          .fontColor('#98A2B3')
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
                    .fontColor('#12161F')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`预计 ${t.estimateMin} 分钟`)
                    .fontSize(LAYOUT.cardSub)
                    .fontColor('#7A8598')
                    .margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .draggable(true)
                .onDragStart((event: DragEvent, extraParams: string): void => {
                  this.dragTodoId = t.id;
                  this.hint = '拖到网格上松手放下';
                })
                .onClick((): void => {
                  this.selectedTodoId = this.selectedTodoId === t.id ? 0 : t.id;
                  this.hint = this.selectedTodoId > 0 ? '现在点网格空白处放下它' : '';
                })

                Text('⚡ 找空档')
                  .fontSize(LAYOUT.cardSub)
                  .fontColor('#2E6BE6')
                  .margin({ top: 6 })
                  .onClick((): void => this.autoPlace(t))
              }
              .width(140)
              .padding(10)
              .backgroundColor(this.selectedTodoId === t.id ? '#E4EDFF' : '#FFFFFF')
              .borderRadius(10)
              .border({
                width: this.selectedTodoId === t.id ? 1.5 : 1,
                color: this.selectedTodoId === t.id ? '#2E6BE6' : '#E3E8F0'
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
          .fontColor('#8A5A00')
          .margin({ top: 12, bottom: 6 })
        Scroll() {
          Row() {
            ForEach(this.poolLessons(), (l: VirtualLesson) => {
              Column() {
                Column() {
                  Text(this.lessonTitle(l))
                    .fontSize(LAYOUT.tray)
                    .fontColor('#12161F')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${LESSON_MIN} 分钟`)
                    .fontSize(LAYOUT.cardSub)
                    .fontColor('#8A7A55')
                    .margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .draggable(true)
                .onDragStart((event: DragEvent, extraParams: string): void => {
                  this.dragLessonId = l.id;
                  this.hint = '拖到网格上松手放下这一讲';
                })

                Text('⚡ 找空档')
                  .fontSize(LAYOUT.cardSub)
                  .fontColor('#B26B00')
                  .margin({ top: 6 })
                  .onClick((): void => this.autoPlaceLesson(l))
              }
              .width(140)
              .padding(10)
              .backgroundColor('#FFF8EC')
              .borderRadius(10)
              .border({ width: 1, color: '#F0DFC0' })
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
  }

  @Builder
  BlockEditor(b: PlanBlock) {
    Column() {
      Column() {
        Text(this.blockTitle(b))
          .fontSize(LAYOUT.chip)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')
        Text(`${this.date} ${minToHHmm(b.startMin)} - ${minToHHmm(b.endMin)}（${b.endMin - b.startMin} 分钟）`)
          .fontSize(LAYOUT.tray)
          .fontColor('#7A8598')
          .margin({ top: 6 })

        Text('调整开始时间')
          .fontSize(LAYOUT.tray)
          .fontColor('#8A94A6')
          .margin({ top: 14, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ChipButton({
            text: '-30 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, -30, -30);
          }
          })
          ChipButton({
            text: '-15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, -15, -15);
          }
          })
          ChipButton({
            text: '+15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, 15, 15);
          }
          })
          ChipButton({
            text: '+30 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, 30, 30);
          }
          })
        }
        .width('100%')

        Text('调整时长')
          .fontSize(LAYOUT.tray)
          .fontColor('#8A94A6')
          .margin({ top: 8, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ChipButton({
            text: '-15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, 0, -15);
          }
          })
          ChipButton({
            text: '+15 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, 0, 15);
          }
          })
          ChipButton({
            text: '+30 分',
            selected: false,
            fontSize: LAYOUT.title,
            onTap: (): void => {
            this.doAdjustLocal(b, 0, 30);
          }
          })
        }
        .width('100%')

        Row() {
          Button(b.done ? '取消完成' : '标记完成')
            .backgroundColor(b.done ? '#EEF1F6' : '#2E6BE6')
            .fontColor(b.done ? '#4A5568' : '#FFFFFF')
            .layoutWeight(1)
            .onClick((): void => {
              this.editingBlock = undefined;
              this.toggleBlockDone(b);
            })
          Button('移除此块')
            .backgroundColor('#FDECEA')
            .fontColor('#C0392B')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.removeBlock(b))
        }
        .width('100%')
        .margin({ top: 18 })

        Button('完成')
          .backgroundColor('#EEF1F6')
          .fontColor('#4A5568')
          .width('100%')
          .margin({ top: 10 })
          .onClick((): void => {
            this.editingBlock = undefined;
          })
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#FFFFFF')
      .borderRadius(14)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .justifyContent(FlexAlign.Center)
  }

  private doAdjustLocal(b: PlanBlock, deltaStart: number, deltaEnd: number): void {
    this.adjustBlock(b, deltaStart, deltaEnd);
    this.editingBlock = b;
  }

  build() {
    Stack() {
      Column() {
        // 日期栏
        Row() {
          Text('‹')
            .fontSize(22)
            .fontColor('#2E6BE6')
            .padding({ left: 8, right: 8 })
            .onClick((): void => this.goDay(-1))
          Column() {
            Text(this.headerText())
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#12161F')
            Text(relativeDayText(parseDate(this.date)))
              .fontSize(LAYOUT.cardSub)
              .fontColor('#8A94A6')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          Text('›')
            .fontSize(22)
            .fontColor('#2E6BE6')
            .padding({ left: 8, right: 8 })
            .onClick((): void => this.goDay(1))
          Text('今天')
            .fontSize(LAYOUT.tray)
            .fontColor('#2E6BE6')
            .onClick((): void => this.goToday())
        }
        .width('100%')
        .padding({ left: 8, right: 12, top: 10, bottom: 8 })
        .backgroundColor('#FFFFFF')

        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(LAYOUT.cardSub)
            .fontColor('#2E6BE6')
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .backgroundColor('#EAF1FF')
        }

        // 时间网格
        Scroll(this.gridScroller) {
          Stack({ alignContent: Alignment.TopStart }) {
            this.HourLines()
            ForEach(this.sessions, (s: CourseSession) => {
              this.ClassBlock(s)
            }, (s: CourseSession) => `cls-${s.course.id}-${s.startSection}`)
            ForEach(this.blocks, (b: PlanBlock) => {
              this.PlanBlockView(b)
            }, (b: PlanBlock) => `blk-${b.id}-${b.startMin}-${b.endMin}-${b.done}`)
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
          if (typeof top === 'number') {
            this.gridViewTop = top;
          }
          if (typeof top === 'number' && typeof h === 'number') {
            this.gridViewBottom = top + h;
          }
        })

        this.TodoPool()
      }
      .width('100%')
      .height('100%')

      if (this.editingBlock !== undefined) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(12,18,28,0.45)')
          .onClick((): void => {
            this.editingBlock = undefined;
          })
        this.BlockEditor(this.editingBlock)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
