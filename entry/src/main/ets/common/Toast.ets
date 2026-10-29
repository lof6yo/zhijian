/**
 * 统一 Toast 封装。
 *
 * 为什么需要这一层：
 * 1. 写法不统一 —— 现在代码里有 `getPromptAction().showToast(...)`、`promptAction.showToast(...)`、
 *    以及各自包 try/catch 的三种版本，时长也有 1600/2000/无显式值等差异。
 * 2. Toast 是纯提示，失败不能打断业务流 —— 所以必须吞异常。
 * 3. 2000 ms 是「看得完一句短句」的最低时长；1600 ms 在深色模式下容易还没读完就消失。
 */
export class Toast {
  static show(ui: UIContext, message: string): void {
    try {
      ui.getPromptAction().showToast({ message, duration: 2000 });
    } catch (_error) {
      // Toast 失败静默处理，不影响主流程。
    }
  }
}
