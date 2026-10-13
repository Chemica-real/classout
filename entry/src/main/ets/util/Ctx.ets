import { common } from '@kit.AbilityKit';

const KEY: string = 'abilityContext';

/**
 * 在 EntryAbility.onCreate 里把 UIAbilityContext 存起来。
 *
 * 这是最可靠的一条路：onCreate 一定在 loadContent 之前执行，
 * 所以页面/组件里再取必然拿得到，既不受 UI 上下文时序影响，也不用已废弃的 getContext()。
 */
export function rememberAbilityContext(ctx: common.UIAbilityContext): void {
  AppStorage.setOrCreate(KEY, ctx);
}

/**
 * 取 EntryAbility 存好的那份，取不到返回 undefined。
 *
 * 注意：调用方必须**先**判断它有没有值，再决定要不要回退到已废弃的 getContext()。
 * 写成 `abilityContext(getContext(this))` 是错的 —— 实参会被无条件求值，
 * 等于把废弃 API 又变成了主路径。
 */
export function storedAbilityContext(): common.UIAbilityContext | undefined {
  return AppStorage.get<common.UIAbilityContext>(KEY);
}
