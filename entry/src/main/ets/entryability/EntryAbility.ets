import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { rememberAbilityContext } from '../util/Ctx';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 先把 context 存下来：后面所有页面取数据库连接都要用它
    rememberAbilityContext(this.context);
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
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onBackground');
  }
}
