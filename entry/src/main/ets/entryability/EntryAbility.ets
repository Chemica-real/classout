import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { rememberAbilityContext } from '../util/Ctx';
import { Db } from '../data/Db';
import { LAST_BG_KV, SYNC_INTERVAL_KEY, loadSyncInterval } from '../data/Prefs';
import { shouldRestartAfterIdle } from '../domain/SyncCadence';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';
/** 页面用 `@StorageLink` 订阅它（字面量），自增一次 = 请页面重放一次启动流程 */
const RESTART_TOKEN_KEY: string = 'restartToken';

export default class EntryAbility extends UIAbility {
  /**
   * 冷启动时 `onForeground` 也会被调一次 —— 那一次不该算"闲置太久回来"
   * （冷启动本来就要整套初始化 + 重排日历）。所以第一次跳过。
   */
  private coldStart: boolean = true;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 先把 context 存下来：后面所有页面取数据库连接都要用它
    rememberAbilityContext(this.context);
    this.coldStart = true;
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading the content.');
      // ⚠️ **必须在 loadContent 之后调**：窗口还在创建过程里时 `setWindowBackgroundColor`
      // 会抛 1300002（abnormal window state），一次异常就把后面的系统栏配色全带走了 ——
      // 实测就是这么踩的：状态栏一直白着，日志里躺着一条 1300002。
      this.applyDarkSystemBars(windowStage);
    });
  }

  /**
   * 深色主题：**系统栏也得跟着深色**。
   *
   * 窗口底色默认是白的，而"状态栏"那块区域不属于页面内容，页面自己的
   * 深色背景铺不到那儿 —— 结果就是「深色 App 顶上顶着一条白色状态栏 + 黑图标」，
   * 一眼就看得出没做完。
   *
   * ⚠️ 两次调用**各包各的 try/catch**：它们互不依赖，一个失败不该连累另一个
   * （第一版包在一起，`setWindowBackgroundColor` 抛异常直接把系统栏配色也吞了）。
   *
   * ⚠️ 只改**系统栏配色与窗口底色**，**不做沉浸式全屏**：
   * 让内容延伸到状态栏下面就得自己处理上下 inset（HANDOFF §15.5 明确不做，风险大收益小）。
   */
  private applyDarkSystemBars(windowStage: window.WindowStage): void {
    let win: window.Window | undefined = undefined;
    try {
      win = windowStage.getMainWindowSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', JSON.stringify(e));
      return;
    }
    try {
      win.setWindowBackgroundColor('#0F0C29');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(e));
    }
    win.setWindowSystemBarProperties({
      statusBarColor: '#0F0C29',
      statusBarContentColor: '#FFFFFF',
      navigationBarColor: '#0F0C29',
      navigationBarContentColor: '#FFFFFF'
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'set system bar properties failed: %{public}s', JSON.stringify(e));
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onForeground');
    if (this.coldStart) {
      // 冷启动这一次不算"闲置回来"：页面自己会跑完整的 init（含重排日历）
      this.coldStart = false;
      return;
    }
    this.checkIdleRestart();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onBackground');
    // 记下"进入后台的时刻"—— 回到前台时用它算闲置了多久。
    // ⚠️ 写的是**真实库**的 kv；演练沙箱期间不该覆盖它（`Db.currentName()` 判断）。
    if (Db.currentName() !== 'classout.db') {
      return;
    }
    Db.setKv(this.context, LAST_BG_KV, `${Date.now()}`).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'record background time failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 用户 2026-10-16：「让应用在未使用超过 n min 后下次点开必定重新启动应用」。
   *
   * 这台机器的 SDK 里 `UIAbilityContext` **没有 restart**（只有 terminateSelf），
   * 而且真把进程杀掉会让用户"点了图标却回到桌面"。所以走**页面重放启动流程**：
   * 自增一个 AppStorage 计数，`Index` 收到后把界面切回加载页、重跑 init
   *（补生成待办 + 重排日历）再播一遍就绪过场 —— 用户看到的就是"重新启动"。
   */
  private checkIdleRestart(): void {
    this.doCheckIdleRestart().catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'idle restart check failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doCheckIdleRestart(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context;
    const raw: string = await Db.getKv(ctx, LAST_BG_KV);
    if (raw.length === 0) {
      return;
    }
    const last: number = parseInt(raw, 10);
    const idleMs: number = Date.now() - (isNaN(last) ? 0 : last);
    // 间隔优先用内存里那份（设置页改完立刻就生效），没有就现读库
    const cached: number | undefined = AppStorage.get<number>(SYNC_INTERVAL_KEY);
    const interval: number = cached === undefined ? await loadSyncInterval(ctx) : cached;
    if (!shouldRestartAfterIdle(idleMs, interval)) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'idle %{public}d ms > %{public}d min, asking page to restart',
      idleMs, interval);
    const token: number | undefined = AppStorage.get<number>(RESTART_TOKEN_KEY);
    AppStorage.setOrCreate(RESTART_TOKEN_KEY, (token === undefined ? 0 : token) + 1);
  }
}
