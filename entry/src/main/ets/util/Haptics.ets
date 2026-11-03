/**
 * 长按等交互的振动反馈。
 *
 * 权限：`ohos.permission.VIBRATE`，在 module.json5 里声明。
 * 该权限是 `availableLevel: normal` + `grantMode: system_grant`：
 * **安装即授予、不弹窗、不需要 ACL**，所以侧载应用可用。
 * （对比 §6.1 那个 PUBLISH_AGENT_REMINDER：也是 normal+system_grant，但配额被卡死。
 *  所以这里没有靠推断，而是在真机上实测确认过。）
 *
 * 设计要点：
 * - **失败一律静默**。这个 App 的核心价值是课表和待办，振动只是锦上添花；
 *   设备没有马达、权限被拒、或系统限制，都不该让长按失效，更不该抛异常。
 * - 只在**长按确认**时调一次，不在移动过程中连续调（那会变成嗡嗡嗡）。
 */

import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 长按触发时用的效果。soft 比 hard 轻，适合"已激活"这种提示 */
const LONG_PRESS_EFFECT: string = vibrator.HapticFeedback.EFFECT_SOFT;

/** 当前设备是否支持这个振动效果。undefined = 还没查过 */
let supported: boolean | undefined = undefined;

function isSupported(): boolean {
  if (supported === undefined) {
    try {
      supported = vibrator.isSupportEffectSync(LONG_PRESS_EFFECT);
    } catch (e) {
      // 14600101 设备操作失败、801 能力不支持等，都当作"不支持"
      const err: BusinessError = e as BusinessError;
      hilog.info(DOMAIN, TAG, 'vibrator probe failed: %{public}s', JSON.stringify(err));
      supported = false;
    }
  }
  return supported;
}

/** 上一次滚动到边的时刻：防止同一位置连续触发，变成嗡嗡嗡 */
let lastEdgeAt: number = 0;

/**
 * 滚动到顶/底时的轻反馈。调用方用 `onReachStart/onReachEnd` 触发；
 * 内部 500ms 节流，避免回弹/连续滑动时反复振。
 */
export function hapticScrollEdge(): void {
  // 设置 → 外观与启动 → 滚动震动（默认开）
  const enabled: boolean | undefined = AppStorage.get<boolean>('scrollHaptic');
  if (enabled === false) {
    return;
  }
  const now: number = Date.now();
  if (now - lastEdgeAt < 500) {
    return;
  }
  lastEdgeAt = now;
  hilog.info(DOMAIN, TAG, 'haptic: scroll edge requested');
  if (!isSupported()) {
    hilog.info(DOMAIN, TAG, 'haptic: scroll edge unsupported');
    return;
  }
  const effect: vibrator.VibrateEffect = {
    type: 'preset',
    effectId: LONG_PRESS_EFFECT,
    count: 1
  };
  const attribute: vibrator.VibrateAttribute = {
    id: 0,
    usage: 'physicalFeedback'
  };
  vibrator.startVibration(effect, attribute)
    .then((): void => {
      hilog.info(DOMAIN, TAG, 'haptic: scroll edge vibration fired');
    })
    .catch((e: BusinessError): void => {
      hilog.info(DOMAIN, TAG, 'haptic skipped: %{public}s', JSON.stringify(e));
    });
}

/**
 * 长按反馈。**可以直接调，不用先判断支持与否** —— 不支持时它自己会返回。
 */
export function hapticLongPress(): void {
  if (!isSupported()) {
    // 记一条日志：振动是"看不见的反馈"，出问题时只有日志能告诉我们为什么没振
    hilog.info(DOMAIN, TAG, 'haptic: device does not support %{public}s', LONG_PRESS_EFFECT);
    return;
  }
  const effect: vibrator.VibrateEffect = {
    type: 'preset',
    effectId: LONG_PRESS_EFFECT,
    count: 1
  };
  const attribute: vibrator.VibrateAttribute = {
    id: 0,
    usage: 'physicalFeedback'
  };
  vibrator.startVibration(effect, attribute)
    .then((): void => {
      hilog.info(DOMAIN, TAG, 'haptic: long-press vibration fired');
    })
    .catch((e: BusinessError): void => {
      // 静默：振动失败不影响任何功能
      hilog.info(DOMAIN, TAG, 'haptic skipped: %{public}s', JSON.stringify(e));
    });
}
