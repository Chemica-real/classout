/**
 * 「系统返回」处理器注册表 —— 鸿蒙手势导航支持的核心。
 *
 * 问题：ArkUI 的 `onBackPress` **只能定义在 `@Entry` 组件上**，本项目只有
 * `pages/Index.ets` 一个页面；可是"当前最上层开着什么"全在子组件里 ——
 * 计划页的块编辑窗、待办页的编辑窗、管理课程的弹窗与子页。
 *
 * 没有它会发生什么（真机现象）：开着编辑窗时，从屏幕左右边缘内滑（手势导航的"返回"）
 * 或者按返回键，**不会关掉那一层，而是把整个 App 切走/退回桌面**。
 *
 * 做法：子组件在 `aboutToAppear` 注册、`aboutToDisappear` 注销；
 * `Index.onBackPress()` 调 `handleBack()`。
 * **后注册的先问（LIFO）** —— 浮层总是比它盖住的页面后挂载，
 * 所以"从最上面那层开始关"这条顺序是天然的，不需要额外的层级管理。
 *
 * 每个处理器自己判断"我现在有没有东西可以关"：关了就返回 true，
 * 没什么可关的返回 false，让下一个（更下层）去处理。
 */

/** 返回处理器：true = 我处理掉了（事件到此为止）；false = 我这儿没东西可关 */
export type BackHandler = () => boolean;

class BackStackImpl {
  private handlers: BackHandler[] = [];

  register(h: BackHandler): void {
    this.handlers.push(h);
  }

  /** 注销。组件 `aboutToDisappear` 时必须调，否则会留下指向已销毁组件的处理器 */
  unregister(h: BackHandler): void {
    for (let i = 0; i < this.handlers.length; i++) {
      if (this.handlers[i] === h) {
        this.handlers.splice(i, 1);
        return;
      }
    }
  }

  /**
   * 从栈顶（最后注册的）往下问；谁处理了返回 true 就停。
   *
   * ⚠️ 先**拷贝一份**再遍历：处理器里可能顺带把自己注销掉
   *（例如管理课程的"关闭"会让组件卸载 → aboutToDisappear → unregister），
   * 边遍历边 splice 会跳过元素。虽然当前实现里卸载发生在下一次渲染、不会同步发生，
   * 但依赖那个时机太脆，快照一下最省心。
   */
  handleBack(): boolean {
    const snapshot: BackHandler[] = this.handlers.slice();
    for (let i = snapshot.length - 1; i >= 0; i--) {
      if (snapshot[i]()) {
        return true;
      }
    }
    return false;
  }

  /** 仅供诊断/测试看当前注册了几个 */
  size(): number {
    return this.handlers.length;
  }
}

/** 全局唯一实例（模块级单例，和 Db 的 store 一个路子） */
export const backStack: BackStackImpl = new BackStackImpl();
