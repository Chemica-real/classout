import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { Course, COURSE_COLORS, CourseSession, OverrideKind, SectionTime, Semester,
  SessionOverride, SessionRule } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { Db } from '../data/Db';
import { Seeder } from '../data/Seeder';
import { computeWeekSessions, dateOfWeekday, mergeRoomOverrides, weekOfDate } from '../domain/Timetable';
import { generateMissedTodos, GenerationOutcome } from '../domain/TodoGenerator';
import { ReminderPlan, syncReminders } from '../domain/ReminderScheduler';
import { formatDate, minToHHmm, today, WEEKDAY_CN, weekdayOf } from '../util/DateUtil';
import { TodoInbox } from '../view/TodoInbox';
import { PlanDayView } from '../view/PlanDayView';
import { CourseManager } from '../view/CourseManager';
import { SettingsPage } from '../view/SettingsPage';
import { backStack } from '../util/BackStack';
import { GLASS_BLUR, GLASS_EDGE_STRONG, GLASS_RADIUS, GLASS_SHADOW_SHEET, GLASS_TINT_PANEL,
  GLASS_TINT_SHEET, PAGE_GRADIENT_A, PAGE_GRADIENT_B, PAGE_GRADIENT_C, PageBackground,
  SCRIM_COLOR } from '../view/Glass';
import { PrivacySection, privacySections, privacyUpdatedAt } from '../domain/Privacy';
import { FLOAT_GAP, FLOAT_SIDE, FLOAT_TOP, H_HEADER, H_TABBAR, H_WEEKROW } from '../view/Float';
import { BOOT_EXTRA_CAP_MS, BOOT_STEP_MS, DUR_BALL_DWELL, DUR_COLLAPSE, DUR_EXPAND,
  DUR_SPRAY, TYPE_MS, collapseCurve, curveOrLinear, dur, expandCurve, isMotionOn,
  loadMotionSetting, motionCurve } from '../view/Motion';
import { WallpaperRepo } from '../data/WallpaperRepo';
import { MOTTO_DEFAULT, NOTE_EXPANDED_KEY, PLAN_END_KEY, PLAN_START_KEY, SYNC_INTERVAL_KEY,
  TODO_CATEGORIES_KEY, loadCustomCategories, loadMotto, loadNoteExpanded, loadPlanWindow,
  loadPrivacyAgreed, loadSyncInterval, savePrivacyAgreed } from '../data/Prefs';
import { TimeWindow } from '../domain/PlanMath';
import { SYNC_INTERVAL_DEFAULT, isSyncBoundary } from '../domain/SyncCadence';
import { serializeCustomCategories } from '../domain/Categories';
import { GuideStep, guideStepAt, guideStepCount, isLastGuideStep, nextGuideStep,
  prevGuideStep } from '../domain/Guide';
import { GuideRepo } from '../data/GuideRepo';

import { ChipButton } from '../view/ChipButton';
import { SectionPicker } from '../view/SectionPicker';

// 文件内 @Styles（Glass.ets 顶部说明了为什么不能跨文件 export）
// 深色版：**模糊用 `backdropBlur`（糊背景），不用 `.blur()`（会糊掉自己的文字）**
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

/** 每节的行高（vp） */
const SECTION_H: number = 52;
/** 机动节次（第 9、12 节）的行高 */
const FLEX_SECTION_H: number = 36;
/**
 * 课表网格的时间轴宽度、以及网格左右内边距（vp）。
 *
 * ⚠️ 抽成常量是因为**悬浮周条要和网格的 7 列严格对齐**：周条走的是
 * 「满宽内容层 + 左右留边的玻璃背景层」，内容层必须用**和网格一模一样**的
 * 这两个数 + 同样的列宽算法，否则越往右边偏得越多。
 */
const TT_AXIS_W: number = 38;
const TT_GRID_PAD: number = 4;

/**
 * 启动清单的阶段名（**和 `init()` 里的真实顺序一一对应**）。
 * 加载页把"正在干什么"逐条标出来 —— 既是科技感，也是真的有用：
 * 冷启动要重排提醒，过去只有一行会变的文案，用户不知道还要等多久。
 */
/**
 * 小球停留时向外喷射的白色粒子：12 颗，方向均分一圈、半径长短交替
 * （全一样长会像个"爆炸"，长短交替才像"喷射"）。
 * 半径写死成表，省得每帧算三角函数。
 */
const SPRAY_N: number = 12;
const SPRAY_R: number[] = [40, 66, 34, 74, 46, 62, 38, 70, 44, 68, 32, 58];

const BOOT_STEPS: string[] = [
  '初始化本地数据',
  '载入课表与节次',
  '补生成下课待办',
  '同步系统日历提醒',
  '就绪'
];

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
  /**
   * 首启「隐私政策」弹窗开着吗（**同意之前什么都不做**）。
   *
   * 上架要求（华为/工信部）：首次运行必须先用弹窗告知隐私政策、取得同意，
   * 之后才能初始化数据、申请权限（日历读写）、写系统日历。
   * 所以 `aboutToAppear` 先只读"同意过没有"，同意了才走 `bootstrap()`。
   */
  @State privacyGate: boolean = false;
  /** 弹窗里"查看完整隐私政策"那一层开着吗 */
  @State privacyTextOpen: boolean = false;
  /** 正在落盘同意状态（防连点；用 @State 是为了让按钮文字跟着变"正在保存…"） */
  @State privacyAgreeing: boolean = false;
  /** 启动流程是否真的开始了（没同意之前不许开"连续使用计时"，见 onPageShow） */
  private bootStarted: boolean = false;
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
  /** 被点的这节是不是**补课**（`extra`）—— 「换教室」要改的是它自己那条覆盖，见 `applyRoom()` */
  @State selIsExtra: boolean = false;
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

  /**
   * 本周的课时（`computeWeekSessions` 的产物）—— 课表网格里那些块就是它。
   *
   * ⚠️ **必须是 `@State`**：在「管理课程」里改了课程属性（名字/简称/颜色/教师/时段规则）
   * 之后，`refresh()` 会把这份数组整个换掉；如果它只是个普通字段，ArkUI 根本不知道
   * 网格的 ForEach 依赖它，就不会重新求值 —— 用户回到课表看到的还是旧块
   * （实测反馈：「更改课程属性之后不会及时更新」）。
   */
  @State weekSessions: CourseSession[] = [];
  private readonly days: number[] = [1, 2, 3, 4, 5, 6, 7];

  // ---------------- 悬浮浮窗（见 view/Float.ets 的文件头注释）----------------
  /** 顶部浮窗栈（页头）量出来的真实高度；默认值只够撑第一帧 */
  @State headerBlockH: number = FLOAT_TOP + H_HEADER;
  /** 底部悬浮导航栏量出来的真实高度 */
  @State tabbarH: number = H_TABBAR;
  /**
   * 页面内部是否开着全屏浮层（计划页的块属性窗 / 待办页的编辑窗）。
   *
   * ★ 为什么要有这个状态：页头 / 待安排货架 / 导航栏是**悬浮浮窗**，画在本文件的
   * **浮窗层**里；而页面自己的编辑窗画在**页面内部**，层级天生比浮窗层低 ——
   * 编辑窗的上下两头会被浮窗盖住（用户实测：「页头所在悬浮窗与最下面的导航栏
   * 会遮挡计划界面双击某待办展开的属性界面，应该让属性界面在最上方」）。
   *
   * ArkUI 没有 portal、`zIndex` 也只对同一父容器的兄弟生效，所以走最省的路：
   * **编辑窗开着时，把浮窗层改画到内容层之下**（见 build() 里的两处
   * `this.FloatingBars()`）—— 编辑窗就在最上方了，浮窗被编辑窗那层全屏深色遮罩
   * 一起压暗（仍然是"模态盖住整屏"的观感，不会突然少两块玻璃）。
   *
   * 页面通过 `onModalChange` 回调把它报上来（和 `CourseManager.close` 同一套路）。
   */
  @State pageModalOpen: boolean = false;
  /**
   * 「请打开这条待办」的跨页请求（计划页的截止列表点进来的）。
   *
   * 计划页自己不造第二份待办编辑窗（编辑入口只该有一处），所以它把 id 报上来，
   * Index 切到「待办」标签并把 id 传下去，由 TodoInbox 打开自己的编辑窗。
   * TodoInbox 执行完通过 `onOpenTodoConsumed` 把它清 0 —— 否则每次 reload 都会再开一次窗。
   */
  @State pendingTodoId: number = 0;

  // ---------------- 新手演练（沙箱引导，见 data/GuideRepo + domain/Guide）----------------
  /** 演练进行中？ */
  @State guideActive: boolean = false;
  /** 当前第几步（下标，见 domain/Guide.guideSteps） */
  @State guideStep: number = 0;
  /** 引导条量出来的高度（内容层要让出这段） */
  @State guideBarH: number = 0;
  /** 首次启动那句询问开着吗 */
  @State guidePrompt: boolean = false;
  /** 正在切库/灌演示数据（挡一下输入，免得中途点进半截状态） */
  @State guideBusy: boolean = false;

  // ---------------- 日历同步节奏（用户 2026-10-16）----------------
  /**
   * `n`（分钟）：连续使用到 n 的整数倍就自动同步一次；闲置超过 n 回到前台就重新启动。
   * 设置页可改，默认 10。
   */
  @StorageLink('syncIntervalMin') syncIntervalMin: number = SYNC_INTERVAL_DEFAULT;
  /**
   * `EntryAbility` 判定"闲置太久、该重启动"时自增它；
   * `@Watch` 收到就重放一遍启动流程（见 `restartAfterIdle`）。
   */
  @StorageLink('restartToken') @Watch('onRestartRequested') restartToken: number = 0;
  /** 「正在与日历同步」提示条开着吗 */
  @State syncing: boolean = false;
  /** 提示条里的点阵动画开着吗（关掉动画时保持静止） */
  @State syncPulse: boolean = false;
  /** 连续使用了多少分钟（每分钟 +1；进后台就停） */
  private activeMin: number = 0;
  /** 上面那个计时器（-1 = 没在跑） */
  private useTimer: number = -1;
  /** 切到「待办」时补生成完，用它让 TodoInbox 重新读库 */
  @State todoReloadToken: number = 0;

  // ---------------- 动画相关状态（见 view/Motion.ets）----------------
  /** 打字机：已经"打"出来的那部分启动文案 */
  @State typedStatus: string = '';
  /** 启动清单：已经完成的阶段数（== 当前正在做的那个下标） */
  @State bootStep: number = 0;
  /** 加载页的常驻动效（外圈旋转 / 底部进度条）—— 关掉动画时保持静止 */
  @State bootSpin: boolean = false;
  @State bootBar: boolean = false;
  /** 进场：字标/标语/清单面板从"略小略透明"到就位（一次性） */
  @State bootIn: boolean = false;
  /** 已经为"放慢启动"额外等掉的时间（受 BOOT_EXTRA_CAP_MS 封顶） */
  private bootExtra: number = 0;
  /**
   * 就绪过场的相位：0=没开始 1=就绪停顿 2=向内浓缩 3=小球停顿 4=扩张+渐隐
   * （时间线见 `playBootExit()`）
   */
  @State bootExit: number = 0;
  /** 小球喷射：false = 粒子还贴在球心（不可见），true = 已飞出去并淡掉 */
  @State ballSpray: boolean = false;
  private bootTimers: number[] = [];
  @StorageLink('motionOn') @Watch('onMotionChanged') motionOn: boolean = true;
  /** 首页标语（设置页可改，见 data/Prefs.ets）。加载页第一帧就用它 */
  @StorageLink('bootMotto') motto: string = MOTTO_DEFAULT;
  private typeTimer: number = -1;
  /** 内容层上方要让出的高度（设置页没有页头，所以是 0） */
  private topInset(): number {
    return this.tab === 3 ? 0 : this.headerBlockH;
  }

  /** 内容层下方要让出的高度（悬浮导航栏 + 间距；演练时再加一条引导条） */
  private bottomInset(): number {
    const guide: number = this.guideActive ? this.guideBarH + FLOAT_GAP : 0;
    return this.tabbarH + FLOAT_GAP + guide;
  }

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
  aboutToDisappear(): void {
    if (this.typeTimer !== -1) {
      clearInterval(this.typeTimer);
      this.typeTimer = -1;
    }
    for (const t of this.bootTimers) {
      clearTimeout(t);
    }
    this.bootTimers = [];
  }

  onBackPress(): boolean {
    // 隐私弹窗开着时：返回只用来关"完整政策"那一层，**不能绕过同意**（也不退出）
    if (this.privacyGate) {
      if (this.privacyTextOpen) {
        this.privacyTextOpen = false;
      }
      return true;
    }
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
    // ⚠️ 第一件事**只读"隐私政策同意过没有"**，别的什么都不做
    //（不建库、不读壁纸、不补生成、不同步日历、不请求权限）。
    this.checkPrivacyGate().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'privacy gate check failed: %{public}s', JSON.stringify(e));
      // 读不出来就当成"没同意"：宁可多问一次，也不能默认同意。
      this.privacyGate = true;
    });
  }

  /** 同意过（且是对当前这一版政策）就直接进启动流程，否则弹窗 */
  private async checkPrivacyGate(): Promise<void> {
    const agreed: string = await loadPrivacyAgreed(this.context());
    if (agreed === privacyUpdatedAt()) {
      this.beginBoot();
      return;
    }
    this.privacyGate = true;
    this.loading = true;
  }

  /** 真正开始启动（首启弹窗点同意之后 / 已同意过的冷启动） */
  private beginBoot(): void {
    this.privacyGate = false;
    this.privacyTextOpen = false;
    this.bootStarted = true;
    this.loading = true;
    // 加载页的常驻动效（关掉动画时不启动，见 startBootMotion）
    this.startBootMotion();
    this.startUseTicker();
    this.bootstrap();
  }

  /** 同意并继续：落盘"同意的是哪一版政策"，然后开始启动 */
  private acceptPrivacy(): void {
    if (this.privacyAgreeing) {
      return;
    }
    this.privacyAgreeing = true;
    const version: string = privacyUpdatedAt();
    savePrivacyAgreed(this.context(), version).then((): void => {
      this.privacyAgreeing = false;
      this.beginBoot();
    }).catch((e: Object): void => {
      // 写库失败也让这一次用起来（否则用户被卡死在弹窗上）；
      // 代价是下次启动会再问一遍 —— 比"同意了却进不去"好。
      this.privacyAgreeing = false;
      hilog.error(DOMAIN, TAG, 'save privacy consent failed: %{public}s', JSON.stringify(e));
      this.beginBoot();
    });
  }

  /** 不同意：退出应用（不留任何数据、不进启动流程） */
  private refusePrivacy(): void {
    this.context().terminateSelf().catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'terminateSelf failed: %{public}s', JSON.stringify(e));
    });
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

  /**
   * 打字机：把 `statusText` 一个字一个字地"打"出来。
   *
   * 只用在**启动加载文案**上（`正在重排提醒…` 这类）—— 它本来就是"正在做事"的语气，
   * 逐字出现比整句跳出更有"在跑"的感觉。动画关掉时直接整句显示。
   */
  private typeStatus(full: string): void {
    if (this.typeTimer !== -1) {
      clearInterval(this.typeTimer);
      this.typeTimer = -1;
    }
    if (!isMotionOn() || full.length === 0) {
      this.typedStatus = full;
      return;
    }
    this.typedStatus = '';
    let i: number = 0;
    this.typeTimer = setInterval((): void => {
      i++;
      this.typedStatus = full.substring(0, i);
      if (i >= full.length) {
        clearInterval(this.typeTimer);
        this.typeTimer = -1;
      }
    }, TYPE_MS);
  }

  /**
   * 加载页的常驻动效：外圈缓慢自转 + 底部不定量进度条。
   *
   * 用的是**隐式动画**（`.animation({iterations: -1})`）+ 一个翻转一次的 state：
   * 这样只挂两个节点、只动 rotate/translate，开销可以忽略。
   * ⚠️ 动画总开关关掉时**不启动**（用户要求"一次性关闭"要覆盖到加载页）。
   */
  private startBootMotion(): void {
    if (!this.motionOn) {
      // 关掉动画：直接到"就位"的终态（其它动效的时长都是 dur()=0，等于没有过渡）
      this.bootIn = true;
      this.bootSpin = false;
      this.bootBar = false;
      return;
    }
    // 先渲染一帧"未就位"，再翻过去 —— 否则进场动画会直接从终点开始
    setTimeout((): void => {
      this.bootIn = true;
      this.bootSpin = true;
      this.bootBar = true;
    }, 16);
  }

  /**
   * 让启动清单的每一步**至少停留 `BOOT_STEP_MS`**（用户要求"人为放慢一点"）。
   *
   * ⚠️ 这不是把真活儿变慢：只是真实耗时不足时补一段等待，而且**总量封顶**
   * （`BOOT_EXTRA_CAP_MS`）。关掉动画时直接返回 —— 那时用户要的就是最快启动。
   */
  private async dwellBootStep(startedAt: number): Promise<void> {
    if (!this.motionOn || this.bootExtra >= BOOT_EXTRA_CAP_MS) {
      return;
    }
    const wait0: number = BOOT_STEP_MS - (Date.now() - startedAt);
    if (wait0 <= 0) {
      return;
    }
    const wait: number = Math.min(wait0, BOOT_EXTRA_CAP_MS - this.bootExtra);
    this.bootExtra += wait;
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, wait);
    });
  }

  private onMotionChanged(): void {
    this.startBootMotion();
  }

  /** 启动文案变了 → 重新打一遍 */
  private onStatusChanged(): void {
    this.typeStatus(this.statusText);
  }

  private async init(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    // 冷启动第一件事：清掉上次演练可能留下的沙箱库。
    // `.db` 默认连的是真实库，所以进程重启后沙箱文件一定是垃圾（哪怕上次是"演练中"被杀掉的）。
    await GuideRepo.cleanupDemoFile(ctx);
    // 冷启动恢复自定义背景（没有就用渐变兜底）。AppStorage 是内存态，所以每次启动都要读回来；
    // 设置页选完图会直接写 AppStorage，PageBackground 靠 @StorageLink 立刻跟着换。
    AppStorage.setOrCreate('wallpaper', await WallpaperRepo.load(ctx));
    // 背景的位置/缩放（'fx,fy,zoom'）也要冷启动读回来 —— AppStorage 是内存态
    AppStorage.setOrCreate('wallpaperFocus', await WallpaperRepo.loadFocus(ctx));
    // 首页标语：也在第一帧之前读回来（加载页字标下面那行就是它）
    AppStorage.setOrCreate('bootMotto', await loadMotto(ctx));
    // 计划页时间范围（上下限）：同样是内存态，每次冷启动都要读回来
    const planWin: TimeWindow = await loadPlanWindow(ctx);
    AppStorage.setOrCreate(PLAN_START_KEY, planWin.startMin);
    AppStorage.setOrCreate(PLAN_END_KEY, planWin.endMin);
    // 自定义待办类型：设置页与待办编辑窗共用这一份（存 '\n' 分隔的字符串）
    AppStorage.setOrCreate(TODO_CATEGORIES_KEY, serializeCustomCategories(await loadCustomCategories(ctx)));
    // 备注区是单行还是大文本框：用户要求记住（待办编辑窗与计划编辑窗共用）
    AppStorage.setOrCreate(NOTE_EXPANDED_KEY, await loadNoteExpanded(ctx));
    // 日历同步/闲置重启的间隔 n（分钟）
    AppStorage.setOrCreate(SYNC_INTERVAL_KEY, await loadSyncInterval(ctx));
    // 动画总开关：AppStorage 是内存态，每次冷启动都要从 kv 读回来
    await loadMotionSetting(ctx);
    this.bootStep = 0;
    let stepAt: number = Date.now();
    const sem: Semester = await Seeder.ensureSemester(ctx);
    this.semester = sem;
    await Seeder.ensureRestWindows(ctx);
    const migrated: number = await Seeder.migrateData(ctx);
    if (migrated > 0) {
      hilog.info(DOMAIN, TAG, 'migrated %{public}d rows (estimates / categories)', migrated);
    }
    await this.dwellBootStep(stepAt);   // 让人看清"初始化本地数据"这一步
    stepAt = Date.now();
    this.bootStep = 1;      // 学期/节次/旧数据都就绪了
    this.statusText = '正在排课…';
    const now: Date = today();
    const w: number = weekOfDate(sem, now);
    this.week = w < 1 ? 1 : (w > sem.totalWeeks ? sem.totalWeeks : w);
    await this.reloadData();
    await this.dwellBootStep(stepAt);
    stepAt = Date.now();
    this.bootStep = 2;      // 课表载入完成
    this.statusText = '正在补生成下课待办…';
    const outcome: GenerationOutcome = await generateMissedTodos(ctx, sem);
    if (outcome.created > 0) {
      hilog.info(DOMAIN, TAG, 'backfilled %{public}d todos', outcome.created);
    }
    await this.dwellBootStep(stepAt);
    stepAt = Date.now();
    this.bootStep = 3;      // 待办补生成完成
    this.statusText = '正在重排提醒…';
    const plan: ReminderPlan = await syncReminders(ctx, sem);
    hilog.info(DOMAIN, TAG, 'reminder plan: %{public}s', JSON.stringify(plan));
    await this.writeRunReport(ctx, sem, outcome, plan, migrated);
    // ⚠️ 最后一步（日历提醒）是真·耗时的大头，它本来就看得见；
    // 这里**不再补等待**，别让"本来就慢的那一步"更慢。
    this.bootStep = 4;      // 提醒同步完成 → 就绪
    // 第一次用（或升级后第一次）问一句要不要走一遍演练。它是**非模态**的：
    // 用户点「先自己用用」之前照样能用 App（只是那张卡浮在最上面）。
    this.guidePrompt = !(await GuideRepo.guidePrompted(ctx));
    // 不直接切界面，而是播完"浓缩成小球 → 扩张淡出"这段过场（见 playBootExit）
    this.playBootExit();
  }

  /** 浓缩结束：小球停留 + **即刻**往外喷射粒子 */
  private onCollapseDone(): void {
    this.bootExit = 3;
    this.ballSpray = false;
    // 先渲染一帧"粒子都贴在球心"，再让它们飞出去（否则会直接跳到终点）
    this.bootAfter(16, (): void => { this.ballSpray = true; });
    this.bootAfter(DUR_BALL_DWELL, (): void => {
      // 停留结束 → 挂载应用界面，并开始扩张；扩张完成再收尾
      this.loading = false;
      this.getUIContext().animateTo({
        duration: dur(DUR_EXPAND),
        curve: curveOrLinear(expandCurve),
        onFinish: (): void => { this.bootExit = 0; }
      }, (): void => { this.bootExit = 4; });
    });
  }

  /** 第 i 颗粒子的水平位移（方向均分一圈，半径取自 SPRAY_R） */
  private sprayDx(i: number): number {
    return Math.cos((i / SPRAY_N) * 2 * Math.PI) * SPRAY_R[i];
  }

  /** 第 i 颗粒子的垂直位移 */
  private sprayDy(i: number): number {
    return Math.sin((i / SPRAY_N) * 2 * Math.PI) * SPRAY_R[i];
  }

  private bootAfter(ms: number, action: () => void): void {
    this.bootTimers.push(setTimeout(action, ms));
  }

  /**
   * 就绪过场（用户设计原话）：
   *   「在加载彻底就绪的时候，先停顿一下，然后整个加载界面逐渐往内浓缩成一个小白圆球（1s），
   *     简单停顿，并即刻扩张至全屏幕，同时逐渐透明消失，显露出应用界面。整个过程优雅 Q 弹、
   *     流畅丝滑（速度不突变）。」
   *
   * 时间线（相位存 `bootExit`；时长都是常量，见 `view/Motion.ets`）：
   * ```
   *   相位1  就绪停顿 320ms（让最后一步的 ✓ 被看清）
   *   相位2  animateTo DUR_COLLAPSE：整页缩向中心 + 淡出；白球同时从 0 成形
   *   相位3  小球停留 DUR_BALL_DWELL，**喷射即刻开始**（球自身大小不变）
   *   相位4  **此刻才挂载应用界面**（loading=false），
   *          并 animateTo DUR_EXPAND：白球扩张到全屏 + 淡出 → 露出应用
   *   收尾    过场层整个卸掉
   * ```
   * ⚠️ 相位 3 是挂在浓缩动画的 **`onFinish`** 上的，不是按固定毫秒数估的 ——
   *    弹簧曲线"看起来缩完了"和"名义时长走完"不是一回事，按固定时间估会留一段空档
   *    （用户实测："喷射效果没有在浓缩完成之后即刻开始"）。同理，扩张完成也走 `onFinish`。
   *
   * ⚠️ 全程只动 `scale` / `opacity`（不重排）；曲线用两端速度为 0 的弹簧
   *    （`collapseCurve` / `expandCurve`）—— 这就是"速度不突变"的来源。
   * ⚠️ **关掉动画时整段跳过**：直接 `loading=false`，不给用户白等两秒。
   */
  private playBootExit(): void {
    if (!this.motionOn) {
      this.loading = false;
      return;
    }
    this.bootExit = 1;
    // ① 向内浓缩 → 结束后立刻进入相位 3（**靠 onFinish，不靠估时间**）
    this.bootAfter(320, (): void => {
      this.getUIContext().animateTo({
        duration: dur(DUR_COLLAPSE),
        curve: curveOrLinear(collapseCurve),
        onFinish: (): void => this.onCollapseDone()
      }, (): void => { this.bootExit = 2; });
    });
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
    // 老数据修复：补课/调课 + 单独一条「换教室」会显示成两条（用户实测报的 bug）。
    // 合并是幂等的，正常数据下 deleteIds 为空、不写库。
    const merge = mergeRoomOverrides(this.overrides);
    if (merge.deleteIds.length > 0) {
      await TimetableRepo.deleteOverrides(ctx, merge.deleteIds);
      this.overrides = merge.list;
    }
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
   * （初始化成没成、补生成几条、提醒写了几条、有没有超预算）。
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
        lines.push(`数据迁移: ${migratedCount} 行（时长对齐 5 分钟 / 旧类型「其他」→「无」）`);
      }
      lines.push(`通知权限: ${plan.enabled ? '已开' : '未开（提醒不会响）'}`);
      lines.push(`提醒发布: ${plan.published} 条 → 上课 ${plan.classes} / 截止 ${plan.ddl} / 计划块 ${plan.blocks} / 简报 ${plan.briefs}`);
      if (plan.calendarEvents > 0) {
        lines.push(`提醒已写入系统日历：${plan.calendarEvents} 个事件`);
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

  // ---------------- 新手演练 ----------------

  /** 某天落在第几周（夹在学期范围内） */
  private clampWeek(d: Date): number {
    const w: number = weekOfDate(this.semester, d);
    return w < 1 ? 1 : (w > this.semester.totalWeeks ? this.semester.totalWeeks : w);
  }

  private guideStepOf(index: number): GuideStep {
    return guideStepAt(index);
  }

  /** 首次启动的询问：先自己用用 */
  private dismissGuidePrompt(): void {
    this.guidePrompt = false;
    GuideRepo.markPrompted(this.context()).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'mark guide prompted failed: %{public}s', JSON.stringify(e));
    });
  }

  private startGuide(): void {
    this.doStartGuide().catch((e: Object): void => {
      this.guideBusy = false;
      hilog.error(DOMAIN, TAG, 'start guide failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 进入演练：**先记下"问过了"（写真实库）**，再切到沙箱库、灌演示数据。
   * 顺序不能反 —— 切库之后写 kv 写的就成沙箱了。
   */
  private async doStartGuide(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    this.guideBusy = true;
    this.guidePrompt = false;
    await GuideRepo.markPrompted(ctx);
    const demo: Semester = await GuideRepo.startDemo(ctx);
    this.semester = demo;
    this.week = this.clampWeek(today());
    this.sessionSheet = false;
    this.adjustSheet = false;
    this.extraSheet = false;
    this.showManager = false;
    this.guideStep = 0;
    this.tab = this.guideStepOf(0).tab;
    await this.reloadData();
    this.guideActive = true;
    this.guideBusy = false;
    hilog.info(DOMAIN, TAG, 'guide started (sandbox db)');
  }

  private exitGuide(): void {
    this.doExitGuide().catch((e: Object): void => {
      this.guideBusy = false;
      hilog.error(DOMAIN, TAG, 'exit guide failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 退出演练：切回真实库 → **把偏好从真实库读回来**（演练里可能改过标语/时间范围/类型）
   * → 删掉沙箱文件 → 回到课表。
   *
   * `this.tab = 0` 是刻意的：待办/计划/设置三个页面都是按 `tab` 条件渲染的，
   * 切到 0 会把它们卸载，下次进去时重新 mount、重新读真实库 ——
   * 否则它们手里还攥着沙箱里的数据（而且沙箱学期 id 常常和真实学期撞号，@Watch 也不会触发）。
   */
  private async doExitGuide(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    this.guideBusy = true;
    this.guideActive = false;
    this.tab = 0;
    await GuideRepo.exitDemo(ctx);
    await this.reloadPrefsFromDb(ctx);
    const real: Semester = await Seeder.ensureSemester(ctx);
    this.semester = real;
    this.week = this.clampWeek(today());
    await this.reloadData();
    this.guideBusy = false;
    hilog.info(DOMAIN, TAG, 'guide finished, back to real db');
  }

  /** 从**当前库**把偏好读回 AppStorage（进出沙箱后都要对齐） */
  private async reloadPrefsFromDb(ctx: common.UIAbilityContext): Promise<void> {
    AppStorage.setOrCreate('wallpaper', await WallpaperRepo.load(ctx));
    AppStorage.setOrCreate('wallpaperFocus', await WallpaperRepo.loadFocus(ctx));
    AppStorage.setOrCreate('bootMotto', await loadMotto(ctx));
    const w: TimeWindow = await loadPlanWindow(ctx);
    AppStorage.setOrCreate(PLAN_START_KEY, w.startMin);
    AppStorage.setOrCreate(PLAN_END_KEY, w.endMin);
    AppStorage.setOrCreate(TODO_CATEGORIES_KEY,
      serializeCustomCategories(await loadCustomCategories(ctx)));
    await loadMotionSetting(ctx);
  }

  /** 跳到第 i 步：顺带切到该步的标签页、关掉挡路的浮层 */
  private setGuideStep(i: number): void {
    this.guideStep = i;
    this.sessionSheet = false;
    this.adjustSheet = false;
    this.extraSheet = false;
    this.showManager = false;
    this.tab = this.guideStepOf(i).tab;
  }

  private guidePrev(): void {
    this.setGuideStep(prevGuideStep(this.guideStep));
  }

  /** 下一步；已经是最后一步就当成"完成演练" */
  private guideNext(): void {
    if (isLastGuideStep(this.guideStep)) {
      this.exitGuide();
      return;
    }
    this.setGuideStep(nextGuideStep(this.guideStep));
  }

  // ---------------- 日历同步 / 闲置重启 / 切页补生成（用户 2026-10-16）----------------

  /** 页面显示（含从后台回来）：开始累计"连续使用时间" */
  onPageShow(): void {
    // 还没同意隐私政策时不计时（那会计出"连续使用"并在 n 分钟后自动同步日历）
    if (!this.bootStarted) {
      return;
    }
    this.startUseTicker();
  }

  /** 页面隐藏（切后台 / 锁屏）：停止累计 —— 只有"真的在用"才该触发自动同步 */
  onPageHide(): void {
    this.stopUseTicker();
  }

  private startUseTicker(): void {
    if (this.useTimer >= 0) {
      return;
    }
    // 每分钟 +1；到 n 的整数倍就同步一次（n = 设置里的间隔）
    this.useTimer = setInterval((): void => {
      this.activeMin++;
      if (isSyncBoundary(this.activeMin, this.syncIntervalMin)) {
        this.runCalendarSync(false);
      }
    }, 60000);
  }

  private stopUseTicker(): void {
    if (this.useTimer >= 0) {
      clearInterval(this.useTimer);
      this.useTimer = -1;
    }
  }

  /**
   * 与系统日历同步一次（把上课 / 截止提醒重排一遍）。
   *
   * `manual = true` 来自页头的「立即与日历同步」；`false` 是"连续使用到 n 的整数倍"自动触发。
   * ⚠️ **演练沙箱期间绝不同步** —— 那会把演示课写进用户的系统日历（真实数据被污染）。
   */
  private runCalendarSync(manual: boolean): void {
    if (this.syncing || this.guideActive || this.semester.id === 0) {
      return;
    }
    this.doCalendarSync(manual).catch((e: Object): void => {
      this.syncing = false;
      this.syncPulse = false;
      hilog.error(DOMAIN, TAG, 'calendar sync failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doCalendarSync(manual: boolean): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    this.syncing = true;
    this.syncPulse = this.motionOn;
    const startedAt: number = Date.now();
    try {
      const plan: ReminderPlan = await syncReminders(ctx, this.semester);
      hilog.info(DOMAIN, TAG, 'calendar sync (%{public}s): %{public}s',
        manual ? 'manual' : 'auto', JSON.stringify(plan));
    } finally {
      // 同步很快时动画会一闪而过，至少让它亮 1.2 秒
      const wait: number = 1200 - (Date.now() - startedAt);
      if (wait > 0) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, wait);
        });
      }
      this.syncing = false;
      this.syncPulse = false;
    }
  }

  /** `EntryAbility` 判定"闲置太久"→ 重放启动流程（用户看到的 = 重新启动） */
  private onRestartRequested(): void {
    this.restartAfterIdle();
  }

  private restartAfterIdle(): void {
    // 隐私弹窗还开着 / 启动压根没开始 —— 绝不重放启动流程（那会绕过同意）
    if (this.privacyGate || !this.bootStarted) {
      return;
    }
    // 正在启动 / 在切库 / 还在播过场 —— 都别插队
    if (this.loading || this.guideBusy || this.bootExit > 0) {
      return;
    }
    // 演练沙箱里不重启：会把用户从演练里踢出去，而且 init 会跑到沙箱库上
    if (this.guideActive) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'idle restart skipped: guide active');
      return;
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'idle restart: replay boot sequence');
    this.stopUseTicker();
    this.activeMin = 0;
    this.guidePrompt = false;
    this.syncing = false;
    this.syncPulse = false;
    this.sessionSheet = false;
    this.adjustSheet = false;
    this.extraSheet = false;
    this.showManager = false;
    this.pageModalOpen = false;
    this.tab = 0;
    this.statusText = '正在重新启动…';
    this.typedStatus = '';
    this.bootStep = 0;
    this.bootExtra = 0;
    this.bootExit = 0;
    this.loading = true;
    // ⚠️ 计时器要**重新开**：`onPageShow` 不会因为这次重放而再触发一次
    // （页面一直是"显示中"），只停不开的话，这一整个前台会话都不会再自动同步。
    this.startUseTicker();
    this.init().catch((e: Object): void => {
      this.loading = false;
      hilog.error(DOMAIN, TAG, 'replay init failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 用户：「每次切换到待办列时，立即补生成下课列表，确保不会有遗漏」。
   * 生成完自增 `todoReloadToken` 让待办页重读库 —— 它是按 `tab` 条件渲染的，
   * 刚挂载时列表还是旧的，补生成出来的新条目要靠这个刷新才会出现。
   */
  private refreshMissedTodos(): void {
    this.doRefreshMissedTodos().catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'refresh missed todos failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doRefreshMissedTodos(): Promise<void> {
    if (this.semester.id === 0) {
      return;
    }
    const ctx: common.UIAbilityContext = this.context();
    const outcome: GenerationOutcome = await generateMissedTodos(ctx, this.semester);
    hilog.info(DOMAIN, TAG, 'todo tab: backfilled %{public}d todos', outcome.created);
    this.todoReloadToken = this.todoReloadToken + 1;
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

  /**
   * 课表网格里每个课时块的 `ForEach` key。
   *
   * ⚠️ 块是用 `@Builder SessionBlock(s)` 渲染的，而 **`@Builder` 的参数按值传入、
   * 首次渲染后固化**：key 不变时 ArkUI 直接复用旧节点、连 builder 都不再执行 ——
   * 于是"在管理课程里改了课程颜色 / 简称 / 教师，回到课表还是旧的"（用户实测反馈）。
   * 所以**块上会显示、或会影响块的字段统统要进 key**（HANDOFF §21.6d 同一条规矩）：
   * 课程名/简称/教师/配色、地点、习题课虚线框，以及由作息表算出来的位置与高度
   *（改了「上课节次时间」也要重画）。
   */
  private sessionKey(s: CourseSession): string {
    return `s-${s.course.id}-${s.date}-${s.originDate}-${s.weekday}`
      + `-${s.startSection}-${s.endSection}-${this.sectionOffset(s.startSection)}-${this.blockHeight(s)}`
      + `-${s.location}-${s.isQuiz}-${s.fromOverride}`
      + `-${s.course.name}-${s.course.shortName}-${s.course.teacher}-${s.course.colorIndex}`;
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
    this.selIsExtra = s.isExtra;
    this.selAdjusted = this.hasOverrideFor(s.course.id, s.originDate, s.isExtra);
    this.roomDraft = s.location;
    this.moveWeekday = s.weekday;
    this.moveStart = s.startSection;
    this.moveEnd = s.endSection;
    this.sessionSheet = true;
  }

  /**
   * 这节有没有"可撤销的调整"。
   *
   * ⚠️ 要区分补课和规则课：`date` 相同不代表是同一件事 ——
   * 「某门课本来就在那天有课，又补了一节」时，规则课不该因为旁边那条 extra
   * 就显示「撤销这节课的调整」（撤销会把补课一起删掉）。
   */
  private hasOverrideFor(courseId: number, originDate: string, isExtra: boolean): boolean {
    for (const o of this.overrides) {
      if (o.courseId !== courseId || o.date !== originDate) {
        continue;
      }
      if (isExtra) {
        if (o.kind === OverrideKind.Extra) {
          return true;
        }
      } else if (o.kind !== OverrideKind.Extra) {
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
      const loc: string = o.newLocation.length > 0 ? ` · 换到 ${o.newLocation}` : '';
      return `${name} · ${o.date} 挪到 ${o.newDate} 第 ${o.newStartSection}-${o.newEndSection} 节${loc}`;
    }
    const extraLoc: string = o.newLocation.length > 0 ? ` · 地点 ${o.newLocation}` : '';
    return `${name} · ${o.newDate} 补课 第 ${o.newStartSection}-${o.newEndSection} 节${extraLoc}`;
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
      if (o.courseId !== this.selCourseId || o.date !== this.selOriginDate) {
        continue;
      }
      // 同 `hasOverrideFor`：补课与规则课各自撤各自的，别互相误删
      if (this.selIsExtra !== (o.kind === OverrideKind.Extra)) {
        continue;
      }
      await TimetableRepo.deleteOverride(ctx, o.id);
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
    // 补课那节没有"规则"可停 —— 它本身就是一个 extra 覆盖，"停课"= 取消这次补课（删掉它）
    if (this.selIsExtra) {
      const extra: SessionOverride | undefined = this.extraOverrideForSel();
      if (extra !== undefined) {
        this.sessionSheet = false;
        this.dropOverride(extra);
        return;
      }
    }
    this.addOverride(this.blankOverride(this.selCourseId, this.selOriginDate, OverrideKind.Cancel));
  }

  /** 被点的这节如果是补课，取它那条 `extra` 覆盖（否则 undefined） */
  private extraOverrideForSel(): SessionOverride | undefined {
    for (const o of this.overrides) {
      if (o.courseId === this.selCourseId && o.date === this.selOriginDate
        && o.kind === OverrideKind.Extra) {
        return o;
      }
    }
    return undefined;
  }

  private applyRoom(): void {
    const loc: string = this.roomDraft.trim();
    if (loc.length === 0) {
      return;
    }
    this.doApplyRoom(loc).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'apply room failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 「换教室（只改这一周）」。
   *
   * ⚠️ 这里**不能**无脑 `insertOverride(room)`：补课（extra）/ 调课（move）本身已经是一条
   * 覆盖记录，再插一条 room 就变成两条 —— 用户实测报的正是这个：
   * 「如果是补课，再加上改了补课的地点，那么应该在补课详情里面只显示一条，而不应该显示成两条」，
   * 而且补课那条地点**根本没变**（计算补课时只读 extra 自己的地点），看着像"课表没刷新"。
   *
   * 正确做法：优先改**产生这节的那条覆盖**（extra → move → 已有的 room），
   * 都没有才新建一条 room。
   */
  private async doApplyRoom(loc: string): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const target: SessionOverride | undefined = this.roomTargetOverride();
    if (target !== undefined) {
      target.newLocation = loc;
      await TimetableRepo.updateOverride(ctx, target);
    } else {
      const o: SessionOverride = this.blankOverride(this.selCourseId, this.selOriginDate,
        OverrideKind.Room);
      o.newLocation = loc;
      await TimetableRepo.insertOverride(ctx, o);
    }
    this.sessionSheet = false;
    this.refresh();
  }

  /**
   * 「换教室」该改哪条覆盖：补课 > 调课 > 已有的换教室。
   *
   * `selIsExtra` 是关键 —— 光看 `date === originDate` 会把"同一门课那天本来就有课、
   * 又补了一节"的规则课误判成补课，从而改错记录。
   */
  private roomTargetOverride(): SessionOverride | undefined {
    let room: SessionOverride | undefined = undefined;
    for (const o of this.overrides) {
      if (o.courseId !== this.selCourseId || o.date !== this.selOriginDate) {
        continue;
      }
      if (this.selIsExtra && o.kind === OverrideKind.Extra) {
        return o;
      }
      if (!this.selIsExtra && o.kind === OverrideKind.Move) {
        return o;
      }
      if (o.kind === OverrideKind.Room) {
        room = o;
      }
    }
    return room;
  }

  private applyMove(): void {
    const newDate: string = formatDate(dateOfWeekday(this.semester, this.week, this.moveWeekday));
    const newStart: number = this.moveStart;
    const newEnd: number = this.moveEnd < this.moveStart ? this.moveStart : this.moveEnd;
    // 补课那节要挪，就改它自己那条 extra；新建 move 对补课是**无效**的
    //（computeWeekSessions 的补课分支只认 extra），点了会像"没反应"。
    if (this.selIsExtra) {
      const extra: SessionOverride | undefined = this.extraOverrideForSel();
      if (extra !== undefined) {
        this.doMoveExtra(extra, newDate, newStart, newEnd).catch((e: Object): void => {
          hilog.error(DOMAIN, TAG, 'move extra failed: %{public}s', JSON.stringify(e));
        });
        return;
      }
    }
    const o: SessionOverride = this.blankOverride(this.selCourseId, this.selOriginDate,
      OverrideKind.Move);
    o.newDate = newDate;
    o.newStartSection = newStart;
    o.newEndSection = newEnd;
    this.addOverride(o);
  }

  private async doMoveExtra(extra: SessionOverride, newDate: string, start: number,
    end: number): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    extra.newDate = newDate;
    extra.newStartSection = start;
    extra.newEndSection = end;
    await TimetableRepo.updateOverride(ctx, extra);
    this.sessionSheet = false;
    this.refresh();
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
            .fontColor('#F2F5FA')
          Text(this.weekRangeText())
            .fontSize(12)
            .fontColor('#94A0B5')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text('‹')
            .fontSize(22)
            .fontColor('#7FA8FF')
            .padding({ left: 10, right: 10 })
            .onClick((): void => this.goWeek(-1))
          Text(`第 ${this.week} 周`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
          Text('›')
            .fontSize(22)
            .fontColor('#7FA8FF')
            .padding({ left: 10, right: 10 })
            .onClick((): void => this.goWeek(1))
        }
      }
      .width('100%')

      Row() {
        Blank()
        Text('＋补课')
          .fontSize(12)
          .fontColor('#7FA8FF')
          .padding({ left: 8, right: 10 })
          .onClick((): void => {
            this.extraCourseId = this.courses.length > 0 ? this.courses[0].id : 0;
            this.extraSheet = true;
          })
        if (this.overrides.length > 0) {
          Text(`本周调整 ${this.overrides.length}`)
            .fontSize(12)
            .fontColor('#E8B25C')
            .padding({ right: 10 })
            .onClick((): void => {
              this.adjustSheet = true;
            })
        }
        Text('管理课程')
          .fontSize(12)
          .fontColor('#7FA8FF')
          .padding({ right: 12 })
          .onClick((): void => {
            this.showManager = true;
          })
        Text(this.inSemester() ? '今天' : '回到本周')
          .fontSize(12)
          .fontColor('#7FA8FF')
          .onClick((): void => this.goToday())
      }
      .width('100%')
      .padding({ top: 8 })

      // 第三行：左边还是那句"离线"声明，右边是**手动同步日历**（用户 2026-10-16 要求）。
      // 点它 = 走和"用到 n 分钟自动同步"完全相同的那套：页面上方弹出同步提示 + 真的重排。
      Row() {
        Text('本地生成 · 无需联网')
          .fontSize(11)
          .fontColor('#8FC9A0')
        Blank()
        Text('⟳ 立即与日历同步')
          .fontSize(12)
          .fontColor('#8FC9A0')
          .padding({ left: 8, right: 2, top: 2, bottom: 2 })
          .onClick((): void => this.runCalendarSync(true))
      }
      .width('100%')
      .padding({ top: 6 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 10 })
    .glassSheet()
  }

  /**
   * 课表的周条（周一…周日 + 日期）。
   *
   * ⚠️ **它不做成悬浮浮窗**（用户 2026-10-14 明确："周一到周日不要做成悬浮窗了，会出去"）：
   * 它必须和网格的 7 列严格对齐，而悬浮面板要左右留边、还会被外层 padding 再缩一次，
   * 列宽对不上就会越往右偏得越多。现在它回到**滚动内容里**，作为表格自己的表头，
   * 和网格用同一套几何（同一个 `Row` 结构、同样的 `TT_AXIS_W` / `TT_GRID_PAD`），
   * 上下滚时跟着表格一起走 —— 这也是用户选的方案 B。
   */
  @Builder
  WeekHeaderRow() {
    Row() {
      Column()
        .width(TT_AXIS_W)
      ForEach(this.days, (wd: number) => {
        Column() {
          Text(`周${WEEKDAY_CN[wd - 1]}`)
            .fontSize(12)
            .fontColor(this.isToday(wd) ? '#7FA8FF' : '#A9B5C9')
            .fontWeight(this.isToday(wd) ? FontWeight.Bold : FontWeight.Normal)
          Text(`${dateOfWeekday(this.semester, this.week, wd).getMonth() + 1}/${dateOfWeekday(this.semester, this.week, wd).getDate()}`)
            .fontSize(10)
            .fontColor(this.isToday(wd) ? '#7FA8FF' : '#8B97AC')
            .margin({ top: 1 })
        }
        .layoutWeight(1)
      }, (wd: number) => `hdr-${wd}`)
    }
    .width('100%')
    .padding({ left: TT_GRID_PAD, right: TT_GRID_PAD, top: 6, bottom: 6 })
    .glassPanel()
  }

  @Builder
  SessionBlock(s: CourseSession) {
    Column() {
      Column() {
        Text(s.course.shortName.length > 0 ? s.course.shortName : s.course.name)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF0FA')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (s.location.length > 0) {
          Text(s.location)
            .fontSize(9)
            .fontColor('#CBD6E8')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        if (s.course.teacher.length > 0 && this.blockHeight(s) > SECTION_H + 10) {
          Text(s.course.teacher)
            .fontSize(9)
            .fontColor('#CBD6E8')
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
              // ⚠️ 时间轴是"要读准时间"的地方（HANDOFF §18.8），深色下不能走"提示文字"那档灰：
              // 用户实测"时间轴的时间看不清"，所以这里比 §18.5 的通用映射**再提亮一档**
              .fontColor('#CBD6E8')
            Text(minToHHmm(st.startMin))
              .fontSize(9)
              .fontColor('#A9B5C9')
          }
          .width('100%')
          .height(this.sectionHeight(st.section))
          .justifyContent(FlexAlign.Start)
          .padding({ top: 2 })
        }, (st: SectionTime) => `t-${st.section}-${st.startMin}-${st.endMin}-${st.flexible}`)
      }
      .width(TT_AXIS_W)

      // 7 天
      ForEach(this.days, (wd: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            ForEach(this.sectionTimes, (st: SectionTime) => {
              Row()
                .width('100%')
                .height(this.sectionHeight(st.section))
                .border({ width: { bottom: 1 }, color: 'rgba(255,255,255,0.12)' })
            }, (st: SectionTime) => `g-${wd}-${st.section}-${st.startMin}-${st.endMin}-${st.flexible}`)
          }
          .width('100%')

          ForEach(this.sessionsOfDay(wd), (s: CourseSession) => {
            this.SessionBlock(s)
          }, (s: CourseSession) => this.sessionKey(s))
        }
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(this.isToday(wd) ? 'rgba(255,255,255,0.10)' : Color.Transparent)
      }, (wd: number) => `col-${wd}`)    }
    .width('100%')
    .height(this.gridHeight())
    .alignItems(VerticalAlign.Top)
    .padding({ left: TT_GRID_PAD, right: TT_GRID_PAD })
  }

  /**
   * 底部导航栏 —— **悬浮浮窗**。
   *
   * 导航栏也是"大面"，所以用 `glassSheet`（模糊 + 大圆角 + 浮起阴影）。
   * 高度在这里量出来给内容层留 padding（见 `view/Float.ets`）。
   */
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
    .height(H_TABBAR)
    .glassSheet()
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const h: Length | undefined = newArea.height;
      if (typeof h === 'number' && h > 0) {
        this.tabbarH = h;
      }
    })
  }

  @Builder
  TabItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(13)
        // 用户要求：「把菜单栏的字体调成加粗的白色，以便看清」。
        // 导航栏是半透明玻璃，深灰字压在上面确实发虚；改成**加粗 + 白字**。
        // 选中态靠**不透明度**区分（选中的是纯白，其余 72% 白）——
        // 两边都还是"加粗的白"，同时一眼看得出在哪个标签上。
        .fontColor(this.tab === index ? '#FFFFFF' : 'rgba(255,255,255,0.72)')
        .fontWeight(FontWeight.Bold)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      // ⚠️ 切标签**不做任何过渡**：用户实测反馈"切菜单的动画太丑太鸡肋"。
      // 页面直接换掉最干净 —— 别在这里加淡入/位移/扫光。
      const was: number = this.tab;
      this.tab = index;
      // 用户 2026-10-16：「每次切换到待办列时，立即补生成下课列表，确保不会有遗漏」。
      // 补生成是异步的，完成后自增 token 让待办页重读库（见 refreshMissedTodos）。
      if (index === 1 && was !== 1) {
        this.refreshMissedTodos();
      }
    })
  }

  @Builder
  Placeholder(title: string, hint: string) {
    Column() {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F2F5FA')
      Text(hint)
        .fontSize(13)
        .fontColor('#94A0B5')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SessionSheet() {
    Column() {
      Column() {
        Text(this.selCourseName)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
        Text(`${this.selDate} 周${WEEKDAY_CN[this.selWeekday - 1]} · 第 ${this.selStart}-${this.selEnd} 节${this.selIsQuiz ? ' · 习题课' : ''}${this.selIsExtra ? ' · 补课' : ''}`)
          .fontSize(12)
          .fontColor('#9BA7BD')
          .margin({ top: 4 })
        Text(this.selLocation.length > 0 ? this.selLocation : '地点待定')
          .fontSize(12)
          .fontColor('#9BA7BD')
          .margin({ top: 2 })
        if (this.selDate !== this.selOriginDate) {
          Text(`（原定 ${this.selOriginDate}，被调过）`)
            .fontSize(11)
            .fontColor('#E8B25C')
            .margin({ top: 2 })
        }

        Text(this.selIsExtra ? '改这次补课的地点' : '换教室（只改这一周）')
          .fontSize(12)
          .fontColor('#94A0B5')
          .width('100%')
          .margin({ top: 16, bottom: 6 })
        Row() {
          TextInput({ text: this.roomDraft, placeholder: '教学楼 101' })
            .fontColor('#F2F5FA')
            .placeholderColor('#8B97AC')
            .caretColor('#7FA8FF')
            .layoutWeight(1)
            .onChange((v: string): void => {
              this.roomDraft = v;
            })
          Button('换到这儿')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#7FA8FF')
            .fontSize(13)
            .margin({ left: 8 })
            .onClick((): void => this.applyRoom())
        }
        .width('100%')

        Text(this.selIsExtra ? '改到哪一天' : '调到哪一天')
          .fontSize(12)
          .fontColor('#94A0B5')
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
          .fontColor('#94A0B5')
          .width('100%')
          .margin({ top: 6, bottom: 6 })
        SectionPicker({
          from: this.moveStart,
          to: this.moveStart,
          onPick: (sec: number): void => {
            this.moveStart = sec;
            if (this.moveEnd < sec) {
              this.moveEnd = sec;
            }
          }
        })
        SectionPicker({
          from: this.moveEnd,
          to: this.moveEnd,
          onPick: (sec: number): void => {
            this.moveEnd = sec < this.moveStart ? this.moveStart : sec;
          }
        })

        Row() {
          Button(this.selIsExtra ? '改到这一天' : '只挪这一天')
            .backgroundColor('rgba(46,107,230,0.22)')
            .fontColor('#7FA8FF')
            .fontSize(13)
            .layoutWeight(1)
            .onClick((): void => this.applyMove())
          Button(this.selIsExtra ? '取消这次补课' : '本周停课')
            .backgroundColor('rgba(214,69,69,0.18)')
            .fontColor('#FF8A8A')
            .fontSize(13)
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.applyCancel())
        }
        .width('100%')
        .margin({ top: 8 })

        if (this.selAdjusted) {
          Button('撤销这节课的调整')
            .backgroundColor('rgba(178,107,0,0.20)')
            .fontColor('#E8B25C')
            .fontSize(13)
            .width('100%')
            .margin({ top: 10 })
            .onClick((): void => this.clearOverridesForSel())
        }
        Button('关闭')
          .backgroundColor('rgba(255,255,255,0.14)')
          .fontColor('#C3CDDE')
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
          .fontColor('#F2F5FA')
        Text(`${this.semester.name} · 第 ${this.week} 周`)
          .fontSize(12)
          .fontColor('#9BA7BD')
          .margin({ top: 4, bottom: 12 })

        if (this.overrides.length === 0) {
          Text('本周没有调整。点课表格子里的课就能停课 / 换教室 / 调课。')
            .fontSize(12)
            .fontColor('#8B97AC')
            .width('100%')
        }

        ForEach(this.overrides, (o: SessionOverride) => {
          Row() {
            Text(this.overrideText(o))
              .fontSize(12)
              .fontColor('#C3CDDE')
              .layoutWeight(1)
            Text('撤销')
              .fontSize(12)
              .fontColor('#FF8080')
              .padding({ left: 10, right: 4 })
              .onClick((): void => this.dropOverride(o))
          }
          .width('100%')
          .padding(10)
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(8)
          .margin({ bottom: 6 })
        }, (o: SessionOverride) =>
              `ov-${o.id}-${o.kind}-${o.date}-${o.newDate}-${o.newStartSection}-${o.newEndSection}-${o.newLocation}-${o.courseId}`)

        Button('关闭')
          .backgroundColor('rgba(255,255,255,0.14)')
          .fontColor('#C3CDDE')
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
          .fontColor('#F2F5FA')
        Text('给某一周临时加一节（调休补课就用这个）')
          .fontSize(11)
          .fontColor('#9BA7BD')
          .margin({ top: 4 })

        Text('哪门课')
          .fontSize(12)
          .fontColor('#94A0B5')
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
          }, (c: Course) => `ec-${c.id}-${c.name}-${c.shortName}-${c.colorIndex}`)
        }
        .width('100%')

        Text('哪一天')
          .fontSize(12)
          .fontColor('#94A0B5')
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
          .fontColor('#94A0B5')
          .width('100%')
          .margin({ top: 6, bottom: 6 })
        SectionPicker({
          from: this.extraStart,
          to: this.extraStart,
          onPick: (sec: number): void => {
            this.extraStart = sec;
            if (this.extraEnd < sec) {
              this.extraEnd = sec;
            }
          }
        })
        SectionPicker({
          from: this.extraEnd,
          to: this.extraEnd,
          onPick: (sec: number): void => {
            this.extraEnd = sec < this.extraStart ? this.extraStart : sec;
          }
        })

        Row() {
          Button('取消')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
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

  /**
   * 启动加载页（用户要求："进入时的加载首页再高档大气有科技感一点"）。
   *
   * 结构与理由：
   *   ① 极淡的网格底纹 —— 课表本身就是一张网格，用它当"科技感"的底纹最贴题；
   *   ② 两层同心圆环（一实一虚）**反向缓慢自转** —— 只动 rotate，两个节点；
   *   ③ 中央字标：拉开字距的 ClassOUT + 一条渐变细线 + 一行小字；
   *   ④ **启动清单**：5 条真实阶段（见 `init()`），完成的打勾、当前的用强调蓝，
   *      比一行"正在…"信息量大得多（冷启动要重排提醒，用户知道还要等多久）；
   *   ⑤ 底部不定量进度条：一段渐变在轨道上来回滑。
   *
   * ⚠️ ③④ 是**信息**，动画关掉也照常显示；①②⑤ 是**装饰**，关掉动画时静止不动
   * （`bootSpin` / `bootBar` 不会被启动）。
   */
  @Builder
  LoadingScreen() {
    Stack() {
      // ① 网格底纹：横 7 竖 5，极淡（0.05），只用来"透气"
      ForEach([0, 1, 2, 3, 4, 5, 6], (i: number) => {
        Row()
          .width('100%')
          .height(1)
          .backgroundColor('rgba(255,255,255,0.05)')
          .position({ x: 0, y: 120 + i * 82 })
      }, (i: number) => `bg-h-${i}`)
      ForEach([0, 1, 2, 3, 4], (i: number) => {
        Column()
          .width(1)
          .height('100%')
          .backgroundColor('rgba(255,255,255,0.04)')
          .position({ x: 60 + i * 92, y: 0 })
      }, (i: number) => `bg-v-${i}`)

      // ② 圆环：两层反向自转 + 一圈"雷达脉冲"（由内向外扩散并淡出，无限循环）
      //    转得比第一版快一档（9s/16s → 5.2s/9s），用户要"更有动感"
      Column()
        .width(300)
        .height(300)
        .borderRadius(150)
        .border({ width: 1.5, color: 'rgba(127,168,255,0.30)' })
        .rotate({ angle: this.bootSpin ? 360 : 0 })
        .animation({ duration: 5200, curve: Curve.Linear, iterations: -1 })
      Column()
        .width(360)
        .height(360)
        .borderRadius(180)
        .border({ width: 1, color: 'rgba(255,255,255,0.14)', style: BorderStyle.Dashed })
        .rotate({ angle: this.bootSpin ? -360 : 0 })
        .animation({ duration: 9000, curve: Curve.Linear, iterations: -1 })
      Column()
        .width(300)
        .height(300)
        .borderRadius(150)
        .border({ width: 1, color: 'rgba(176,139,232,0.55)' })
        .scale({ x: this.bootSpin ? 1.45 : 0.72, y: this.bootSpin ? 1.45 : 0.72 })
        .opacity(this.bootSpin ? 0 : 0.75)
        .animation({ duration: 2400, curve: Curve.EaseOut, iterations: -1 })

      // ③④⑤ 主体
      Column() {
        // ③ 字标：进场时从 0.93 放大到 1 + 淡入（只动 scale/opacity）
        Text('ClassOUT')
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F5FA')
          // 用户："ClassOUT 字母之间不要空那么大" → 7 → 2
          .letterSpacing(2)
          .scale({ x: this.bootIn ? 1 : 0.93, y: this.bootIn ? 1 : 0.93 })
          .opacity(this.bootIn ? 1 : 0)
          .animation({ duration: dur(560), curve: curveOrLinear(motionCurve) })
        // 渐变细线：从中间展开（scaleX 0 → 1）
        Row()
          .width(96)
          .height(3)
          .borderRadius(2)
          .linearGradient({
            angle: 90,
            colors: [['#7FA8FF', 0.0], ['#B08BE8', 0.5], ['#1F7A73', 1.0]]
          })
          .margin({ top: 14 })
          .scale({ x: this.bootIn ? 1 : 0, y: 1 })
          .animation({ duration: dur(620), curve: curveOrLinear(motionCurve), delay: dur(160) })
        // 首页标语：用户可在设置里改（有字数上限，见 data/Prefs.ets）。
        // 空的时候整行不占位 —— 有人就想要一个干净的 logo。
        if (this.motto.length > 0) {
          Text(this.motto)
            .fontSize(11)
            .fontColor('#8B97AC')
            .letterSpacing(3)
            // 上限是"显示宽度"，最宽那一档（32 个英文字母）刚好贴边，留个省略号兜底
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 14 })
            .opacity(this.bootIn ? 1 : 0)
            .translate({ y: this.bootIn ? 0 : 10 })
            .animation({ duration: dur(520), curve: curveOrLinear(motionCurve), delay: dur(300) })
        }

        // ④ 启动清单（放在一块玻璃面板上：压在照片壁纸上也能读清，而且和全 App 的语言一致）
        Column() {
        Column() {
          ForEach(BOOT_STEPS, (name: string, i: number) => {
            Row() {
              Text(i < this.bootStep ? '✓' : (i === this.bootStep ? '▸' : '·'))
                .fontSize(12)
                .fontColor(i < this.bootStep ? '#7BD69A'
                  : (i === this.bootStep ? '#7FA8FF' : '#5A6478'))
                .width(18)
              Text(name)
                .fontSize(12)
                .fontColor(i < this.bootStep ? '#A9B5C9'
                  : (i === this.bootStep ? '#F2F5FA' : '#5A6478'))
              Blank()
              if (i === this.bootStep) {
                Text('进行中')
                  .fontSize(10)
                  .fontColor('#7FA8FF')
              }
            }
            .width('100%')
            .padding({ top: 5, bottom: 5 })
          }, (name: string) => `boot-${name}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 打字机那行（"正在重排提醒…"）—— 保留，它是细粒度进度
        Text(this.typedStatus)
          .fontSize(11)
          .fontColor('#8B97AC')
          .width('100%')
          .margin({ top: 12 })

        // ⑤ 开机点：**模仿 Ubuntu 的开机显示**（用户点名）。
        //    5 个点依次亮起 —— 每个点的动画同长、`delay` 依次错开，
        //    于是"亮点"会从左边跑到右边，一直循环。只动 opacity / scale。
        //    ⚠️ 原来这里是一条"滑块进度条"，滑块靠 translate 跑，
        //    没裁干净会从面板**两侧爆出去**（用户实测看到过）。
        //    换成点阵之后这个问题从根上没有了（`.clip(true)` 仍然留着兜底）。
        Row() {
          ForEach([0, 1, 2, 3, 4], (i: number) => {
            Column()
              .width(9)
              .height(9)
              .borderRadius(5)
              .backgroundColor('#7FA8FF')
              // 关掉动画时五个点都保持"半亮"的静止样子，而不是全灭
              .opacity(this.bootBar ? 1 : (this.motionOn ? 0.18 : 0.55))
              .scale({
                x: this.bootBar ? 1.18 : 0.85,
                y: this.bootBar ? 1.18 : 0.85
              })
              .animation({
                duration: dur(660),
                curve: Curve.EaseInOut,
                iterations: -1,
                playMode: PlayMode.Alternate,
                delay: dur(i * 140)
              })
              .margin({ right: i < 4 ? 12 : 0 })
          }, (i: number) => `boot-dot-${i}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 18 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 16 })
        .glassPanel()
        .margin({ top: 34 })
        .opacity(this.bootIn ? 1 : 0)
        .translate({ y: this.bootIn ? 0 : 16 })
        .animation({ duration: dur(560), curve: curveOrLinear(motionCurve), delay: dur(220) })
      }
      .width('78%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 浮窗层（页头 / 待安排货架 / 导航栏）：**不参与内容布局**。
   *
   * ⚠️ 它在 `build()` 里被调用两次，位置由 `pageModalOpen` 决定 —— 这是为了
   * 让页面内部的编辑窗能盖住它（ArkUI 没有 portal，跨层 zIndex 也不生效，
   * 详见 `pageModalOpen` 的注释）。
   */
  @Builder
  FloatingBars() {
    // ================= 浮窗层（完全不参与内容布局）=================
    if (!this.loading) {
      // 顶部浮窗栈：页头（课表页再加一条周条）。
      // 设置页不显示课表那套头部 —— 那些是课表页的导航控件，摆在设置页只会干扰；
      // 它自己的「设置」标题栏在 SettingsPage 内部浮。
      if (this.tab !== 3) {
        // ⚠️ 定位壳：根 Stack 默认**居中**排子节点，所以浮窗必须靠一层
        // "满屏 + 顶到上边"的壳钉住；量高度的是里面那层（它的高度才是浮窗的真实占位）。
        Column() {
          Column() {
            this.Header()
          }
          .width('100%')
          .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, top: FLOAT_TOP })
          // 量出这一叠浮窗的总高度，内容层用它留 padding
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const h: Length | undefined = newArea.height;
            if (typeof h === 'number' && h > 0) {
              this.headerBlockH = h;
            }
          })
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 底部浮窗：引导条（演练时）+ 导航栏
      Column() {
        if (this.guideActive) {
          this.GuideBar()
        }
        this.TabBar()
      }
      .width('100%')
      .height('100%')
      .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, bottom: FLOAT_GAP })
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  /**
   * 新手演练的**引导条**（浮在导航栏上方）。
   *
   * 用户拍定的形态：不遮罩、不高亮，就在真实界面底部挂一条"第 n/N 步 + 要做什么"，
   * 每一步自动切到对应标签页，用户照着做（做的每一下都真实写进沙箱库）。
   */
  @Builder
  GuideBar() {
    Column() {
      Row() {
        Text(`第 ${this.guideStep + 1}/${guideStepCount()} 步`)
          .fontSize(10)
          .fontColor('#E8B25C')
        Text(this.guideStepOf(this.guideStep).title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
          .layoutWeight(1)
          .margin({ left: 8 })
        Text('退出演练')
          .fontSize(11)
          .fontColor('#FF8A8A')
          .padding({ left: 10, top: 2, bottom: 2 })
          .onClick((): void => this.exitGuide())
      }
      .width('100%')

      Text(this.guideStepOf(this.guideStep).body)
        .fontSize(12)
        .fontColor('#C3CDDE')
        .width('100%')
        .margin({ top: 4 })

      Row() {
        Button('上一步')
          .backgroundColor('rgba(255,255,255,0.14)')
          .fontColor('#C3CDDE')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .enabled(this.guideStep > 0)
          .opacity(this.guideStep > 0 ? 1 : 0.4)
          .onClick((): void => this.guidePrev())
        Button(isLastGuideStep(this.guideStep) ? '完成演练' : '下一步')
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .margin({ left: 10 })
          .onClick((): void => this.guideNext())
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .glassSheet()
    .margin({ bottom: FLOAT_GAP })
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const h: Length | undefined = newArea.height;
      if (typeof h === 'number' && h > 0) {
        this.guideBarH = h;
      }
    })
  }

  /** 首次启动的那句询问（沙箱说明 + 两个按钮） */
  @Builder
  GuidePromptCard() {
    Column() {
      Column() {
        Text('第一次用 ClassOUT？')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
        Text('可以在「演练」里走一遍：会建一个沙箱（里面有几门演示课和演示待办），'
          + '你随便改、随便删；退出时整个沙箱删掉，你自己的课表一点都不会动。')
          .fontSize(12)
          .fontColor('#C3CDDE')
          .margin({ top: 8 })
        Text(`共 ${guideStepCount()} 步，大约两分钟。`)
          .fontSize(11)
          .fontColor('#8B97AC')
          .margin({ top: 6 })

        Button('开始演练')
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .width('100%')
          .margin({ top: 14 })
          .onClick((): void => this.startGuide())
        Button('先自己用用')
          .backgroundColor('rgba(255,255,255,0.14)')
          .fontColor('#C3CDDE')
          .width('100%')
          .margin({ top: 10 })
          .onClick((): void => this.dismissGuidePrompt())
      }
      .width('100%')
      .padding(18)
      .glassSheet()
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(12,18,28,0.55)')
  }

  /**
   * 「正在与日历同步」提示条 —— **在页面靠上方**弹出（用户 2026-10-16）。
   *
   * 动画沿用首页那套 **Ubuntu 开机点阵**（5 个点依次亮起、循环）：
   * 只动 opacity / scale，关掉动画时保持"半亮"的静止样子。
   * `HitTestMode.None`：它只是提示，绝不吞点击。
   */
  @Builder
  SyncToast() {
    Column() {
      Column() {
        Row() {
          ForEach([0, 1, 2, 3, 4], (i: number) => {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor('#7FA8FF')
              .opacity(this.syncPulse ? 1 : (this.motionOn ? 0.18 : 0.55))
              .scale({ x: this.syncPulse ? 1.18 : 0.85, y: this.syncPulse ? 1.18 : 0.85 })
              .animation({
                duration: dur(660),
                curve: Curve.EaseInOut,
                iterations: -1,
                playMode: PlayMode.Alternate,
                delay: dur(i * 140)
              })
              .margin({ right: i < 4 ? 9 : 0 })
          }, (i: number) => `sync-dot-${i}`)
        }
        .justifyContent(FlexAlign.Center)

        Text('正在与系统日历同步…')
          .fontSize(12)
          .fontColor('#F2F5FA')
          .margin({ top: 8 })
        Text('把上课与截止提醒重排一遍，避免漏提醒')
          .fontSize(10)
          .fontColor('#8B97AC')
          .margin({ top: 2 })
      }
      .padding(14)
      .glassSheet()
    }
    .width('100%')
    .height('100%')
    .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, top: this.topInset() + FLOAT_GAP })
    .justifyContent(FlexAlign.Start)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 切库/灌演示数据时挡一下（那一瞬间数据是半截的） */
  @Builder
  GuideBusyLayer() {
    Column() {
      Text(this.guideActive ? '正在准备演练…' : '正在恢复你的课表…')
        .fontSize(13)
        .fontColor('#F2F5FA')
        .padding(18)
        .glassSheet()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(12,18,28,0.55)')
  }

  /**
   * 首启「隐私政策」弹窗。
   *
   * ⚠️ 它是**不可绕过**的：全屏、吞掉所有手势（`HitTestMode.Block`）、返回键也不关；
   * 只有「同意并继续」（落盘后进启动流程）或「不同意并退出」（terminateSelf）。
   * ⚠️ 弹窗出现时**启动流程还没开始**：不建库、不读壁纸、不补生成、不同步日历、不申请权限。
   */
  @Builder
  PrivacyGateCard() {
    Column() {
      Column() {
        Text('隐私政策')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F5FA')
          .width('100%')
        Text('使用 ClassOUT 前，请阅读并同意以下说明')
          .fontSize(12)
          .fontColor('#A9B5C9')
          .width('100%')
          .margin({ top: 6 })

        Text('ClassOUT 完全离线运行：不收集、不上传、不共享你的任何个人信息。'
          + '没有账号、没有登录、没有统计、没有广告，也没有任何第三方 SDK。')
          .fontSize(13)
          .fontColor('#C3CDDE')
          .width('100%')
          .margin({ top: 18 })
        Text('为了把上课与截止提醒写进系统日历，应用会申请日历读写权限；'
          + '长按拖动时会用振动反馈。课程、待办、计划等数据只保存在这台手机里，卸载即删除。')
          .fontSize(13)
          .fontColor('#C3CDDE')
          .width('100%')
          .margin({ top: 10 })

        Text('查看完整隐私政策')
          .fontSize(13)
          .fontColor('#7FA8FF')
          .width('100%')
          .margin({ top: 16 })
          .onClick((): void => {
            this.privacyTextOpen = true;
          })

        Button(this.privacyAgreeing ? '正在保存…' : '同意并继续')
          .width('100%')
          .height(46)
          .margin({ top: 22 })
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .fontSize(15)
          .enabled(!this.privacyAgreeing)
          .onClick((): void => this.acceptPrivacy())
        Button('不同意并退出')
          .width('100%')
          .height(42)
          .margin({ top: 10 })
          .backgroundColor('rgba(255,255,255,0.10)')
          .fontColor('#A9B5C9')
          .fontSize(13)
          .onClick((): void => this.refusePrivacy())

        Text('开发者 Chemica_ · harvapps@qq.com')
          .fontSize(11)
          .fontColor('#8B97AC')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 16 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 24, bottom: 20 })
      .borderRadius(20)
      .backgroundColor('rgba(255,255,255,0.10)')
      .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
      .backdropBlur(GLASS_BLUR)
    }
    .width('100%')
    .height('100%')
    .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE })
    .justifyContent(FlexAlign.Center)
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [[PAGE_GRADIENT_A, 0.0], [PAGE_GRADIENT_B, 0.5], [PAGE_GRADIENT_C, 1.0]]
    })
    // ⚠️ **不能用 `HitTestMode.Block`**：它会把**子节点**（两个按钮、查看全文）也一起屏蔽，
    //    弹窗里点什么都没反应（真机踩过）。这里用默认命中测试 + 外层 onClick 吞掉
    //    "点在卡片外面"的那一下，按钮自己的 onClick 照常生效。
    .onClick((): void => {})
  }

  /**
   * 「查看完整隐私政策」：全屏正文，内容和设置页那份**同源**（`domain/Privacy.ets`）。
   * 只盖在弹窗上面，关掉后还回到「同意 / 不同意」，不会绕过同意。
   */
  @Builder
  PrivacyTextView() {
    Column() {
      Row() {
        Text('隐私政策')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
          .layoutWeight(1)
        Text('✕')
          .fontSize(14)
          .fontColor('#A9B5C9')
          .padding({ left: 14, top: 4, bottom: 4 })
          .onClick((): void => {
            this.privacyTextOpen = false;
          })
      }
      .width('100%')

      Text(`更新日期：${privacyUpdatedAt()}`)
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 6, bottom: 8 })

      Scroll() {
        Column() {
          ForEach(privacySections(), (s: PrivacySection) => {
            Text(s.heading)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
              .width('100%')
              .margin({ top: 12 })
            Text(s.body)
              .fontSize(12)
              .fontColor('#C3CDDE')
              .width('100%')
              .margin({ top: 4 })
          }, (s: PrivacySection) => `pv-${s.heading}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .width('100%')

      Button('关闭')
        .width('100%')
        .height(42)
        .margin({ top: 10 })
        .backgroundColor('rgba(255,255,255,0.14)')
        .fontColor('#C3CDDE')
        .fontSize(13)
        .onClick((): void => {
          this.privacyTextOpen = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 28, bottom: 20 })
    .backgroundColor('#0F0C29')
    // 同 PrivacyGateCard：Block 会屏蔽子节点，用"默认 + 吞点击"代替
    .onClick((): void => {})
  }

  build() {
    Stack() {
      // 玻璃态的"可透物"：铺在所有内容之下。
      // 各页面根容器都不再设不透明底色，否则会把这一层挡掉、玻璃白做。
      PageBackground()

      // ⚠️ 浮窗层画两处，位置由 `pageModalOpen` 决定（见该 state 的注释）：
      //   - 页面内编辑窗**开着**：画在**内容层之前** → 被编辑窗那层全屏遮罩一起压暗，
      //     编辑窗始终在最上方（用户要求「属性界面要在最上方」）；
      //   - **没开**：画在内容层之后（见下面那处）→ 浮在最上面，内容钻到它们下面。
      if (this.pageModalOpen) {
        this.FloatingBars()
      }

      // ================= 内容层（铺满整屏）=================
      // 页头 / 导航栏改成**悬浮浮窗**之后，内容层不再被它们挤占：
      // 它从屏幕顶一直铺到底，靠**自己的上下 padding** 给浮窗让位
      // （padding 加在滚动内容上，所以往上滑时内容会钻到浮窗下面，见 view/Float.ets）。
      // ⚠️ 加载页**只在过场层里渲染一次**（见下面的 BootLayer）：
      // 以前这里也渲染一份，结果"浓缩"只缩了过场层那一份、这一份还按原尺寸留在屏幕上，
      // 看上去就是"文字/边框没跟着缩进小球"（用户实测反馈）。
      // 所以这里只管"应用界面"，加载期间什么都不画。
      if (!this.loading) {
        Column() {
          if (this.tab === 0) {
            Scroll() {
              Column() {
                // 表格自己的表头行：跟着网格一起滚（不是浮窗）
                this.WeekHeaderRow()
                this.Grid()
              }
              .width('100%')
              // 上方让出「页头 + 周条」两条浮窗，下方让出悬浮导航栏
              // ⚠️ `+ FLOAT_GAP`：用户要求「多个玻璃矩形相连时中间要有空行」，
              // 不留缝的话页头浮窗会和下面那条周条贴在一起
              .padding({ top: this.topInset() + FLOAT_GAP, bottom: this.bottomInset() })
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .align(Alignment.TopStart)
            // 切标签：淡入 + 轻微上移（只动 opacity/translate，不重排）
          } else if (this.tab === 1) {
            Column() {
              TodoInbox({
                semesterId: this.semester.id,
                topInset: this.topInset(),
                bottomInset: this.bottomInset(),
                // 切到「待办」时 Index 会先补生成下课待办，完成后自增它让这里重读库
                reloadToken: this.todoReloadToken,
                openTodoId: this.pendingTodoId,
                onOpenTodoConsumed: (): void => {
                  this.pendingTodoId = 0;
                },
                onModalChange: (open: boolean): void => {
                  this.pageModalOpen = open;
                }
              })
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.tab === 2) {
            Column() {
              PlanDayView({
                semesterId: this.semester.id,
                topInset: this.topInset(),
                bottomInset: this.bottomInset(),
                onOpenTodo: (id: number): void => {
                  // 计划页的截止列表点了一条 → 切到待办页并让它打开那条
                  this.pendingTodoId = id;
                  this.tab = 1;
                },
                onModalChange: (open: boolean): void => {
                  this.pageModalOpen = open;
                }
              })
            }
            .width('100%')
            .layoutWeight(1)
          } else {
            // 设置页。⚠️ 原来是 else 兜底给 PlanDayView，加第 4 个标签后必须
            // 把计划页改成显式 `tab === 2`，否则「设置」会显示成计划页。
            // 设置页没有课表那套页头（学期名 / 第几周 / ＋补课 / 管理课程 / 今天），
            // 它自己的标题栏在页面内部浮，所以这里 topInset 传 0。
            Column() {
              SettingsPage({
                semesterId: this.semester.id,
                topInset: this.topInset(),
                bottomInset: this.bottomInset(),
                // 设置页的「新手引导」入口 → 由 Index 负责建沙箱、切库、挂引导条
                onStartGuide: (): void => this.startGuide(),
                // 设置页的「调整背景」是全屏浮层，开着时也要把浮窗层挪到内容层之下
                onModalChange: (open: boolean): void => {
                  this.pageModalOpen = open;
                }
              })
            }
            .width('100%')
            .layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')
        // 底色交给 PageBackground（见 Glass.ets）
        .backgroundColor(Color.Transparent)
      }

      if (!this.pageModalOpen) {
        this.FloatingBars()
      }

      // 「正在与日历同步」提示条：靠上方浮着（不吞点击，几秒后自己消失）
      if (this.syncing) {
        this.SyncToast()
      }

      // ---- 加载页 + 就绪过场层（见 playBootExit）----
      // 它压在应用界面与浮窗**之上**：白球扩张淡出的过程中，应用是被"露出来"的。
      // `bootExit === 0` 时它就是**常态的加载页**（整页 scale=1、球不可见）；
      // `bootExit` 推进时，**同一份**加载页整体缩向中心并淡出 —— 文字、边框、清单、圆环
      // 一起变小消失（它们是同一个节点的子树，随父节点缩放）。
      // ⚠️ 正因为如此，加载页**不能**在内容层再渲染一份（那会留下一个不缩的副本）。
      // `HitTestMode.Block` 让这段时间的手势全部吞掉，免得球还在飞就被点开了什么。
      if (this.loading || this.bootExit > 0) {
        Stack() {
          // 加载页本体：相位 ≥2 时**整棵子树**（字标、渐变线、清单、圆环、开机点）
          // 一起缩向中心并淡出 —— 所以看上去是"全都被吸进小球里"
          Column() {
            this.LoadingScreen()
          }
          .width('100%')
          .height('100%')
          .scale({
            x: this.bootExit >= 2 ? 0.06 : 1,
            y: this.bootExit >= 2 ? 0.06 : 1
          })
          .opacity(this.bootExit >= 2 ? 0 : 1)

          // 喷射的白色粒子：从相位 3 开始出现，**延续到相位 4**（扩张期间慢慢淡掉）。
          // 只挂在相位 3 的话，360ms 一到粒子就被卸掉、喷射看不完整（实测抓不稳）。
          // 它们**不属于**小球节点，所以球的自身大小完全不受影响（用户要求"自身不变"）；
          // 每颗 `delay` 依次错开 → 连起来是一股"慢速喷射"，而不是一次爆炸。
          if (this.bootExit >= 3) {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], (i: number) => {
              Column()
                .width(4 + (i % 3) * 2)
                .height(4 + (i % 3) * 2)
                .borderRadius(8)
                .backgroundColor('#FFFFFF')
                // 一圈柔光：压在照片壁纸上也能看清，观感也更"科技"
                .shadow({ radius: 8, color: 'rgba(255,255,255,0.85)', offsetX: 0, offsetY: 0 })
                .translate({
                  x: this.ballSpray ? this.sprayDx(i) : 0,
                  y: this.ballSpray ? this.sprayDy(i) : 0
                })
                .scale({
                  x: this.ballSpray ? 1.35 : 0.4,
                  y: this.ballSpray ? 1.35 : 0.4
                })
                .opacity(this.ballSpray ? 0 : 1)
                .animation({
                  duration: dur(DUR_SPRAY),
                  curve: Curve.EaseOut,
                  delay: dur(i * 46)
                })
                .hitTestBehavior(HitTestMode.None)
            }, (i: number) => `spray-${i}`)
          }

          // 那颗"小白圆球"：相位 2 成形 → 相位 4 扩张到全屏并淡出
          // （尺寸是用户要求"改成现在的两倍"：18 → 36）
          Column()
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor('#FFFFFF')
            .shadow({ radius: 40, color: 'rgba(255,255,255,0.55)', offsetX: 0, offsetY: 0 })
            .scale({
              x: this.bootExit >= 4 ? 70 : (this.bootExit >= 2 ? 1 : 0.01),
              y: this.bootExit >= 4 ? 70 : (this.bootExit >= 2 ? 1 : 0.01)
            })
            .opacity(this.bootExit >= 4 ? 0 : (this.bootExit >= 2 ? 1 : 0))
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Block)
      }

      if (this.showManager) {
        // 管理课程原来**直接盖在课表上**（没有遮罩）。玻璃化的正解不是"把背景盖掉"，
        // 而是**把模糊做够**——让底下的课表变成"磨砂玻璃后面的柔和色块"：
        // **既保留背景信息（若隐若现），又不干扰前景**（这就是玻璃态说明里的第 ② 条）。
        // 深色主题下这层薄纱是**压暗**（`SCRIM_COLOR`）而不是提亮：
        // 白玻璃在深色 App 里会把底下照得发灰、白字反而读不清。
        // 薄纱太浓就变成"把背景抹掉"（那是错的），太淡则底下的字还能读（看着像渲染故障）。
        Column()
          .width('100%')
          .height('100%')
          .backdropBlur(GLASS_BLUR)
          .backgroundColor(SCRIM_COLOR)
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

      // ---- 新手演练的两层（都在最上面）----
      // 首次启动的询问：等加载页/过场彻底结束再出现，别叠在启动动画上
      if (this.guidePrompt && !this.loading && this.bootExit === 0 && !this.guideBusy) {
        this.GuidePromptCard()
      }
      // 切库那一两秒挡一下输入
      if (this.guideBusy) {
        this.GuideBusyLayer()
      }

      // ---- 首启隐私政策弹窗（**最顶层**；同意之前 App 什么都不做）----
      if (this.privacyGate) {
        this.PrivacyGateCard()
        if (this.privacyTextOpen) {
          this.PrivacyTextView()
        }
      }
    }
    .width('100%')
    .height('100%')
  }
}
