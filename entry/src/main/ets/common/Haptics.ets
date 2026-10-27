import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'ZhijianHaptic';

/**
 * 触觉反馈，集中一处。
 *
 * ## 为什么不是一个 `toggle` 就完事
 *
 * 触觉只在**离散的状态切换**上有意义：跨过滑动判定线、菜单弹出、笔记被归档。
 * 挂在连续量上（每一帧位移）会让手机变成按摩棒。所以这里只暴露两个强度，
 * 且都由调用方在「已经发生了一件事」的那一刻调一次。
 *
 * ## 为什么失败必须吞掉
 *
 * `startVibration` 需要 `ohos.permission.VIBRATE`（normal 级，安装即授予），
 * 但设备可能没有马达、系统可能把触觉关掉、模拟器根本没有这个能力。
 * 任何一次失败都只是「这次没有震动」，绝不能让归档或删除因为震动失败而回滚。
 * 所以这里全部 `catch` 掉，只在 debug 级别记一行。
 *
 * ## 两个强度
 *
 * `soft` 用于「轻档动作成立」（归档 / 收藏），`hard` 用于「重档或菜单出现」
 * ——用户需要确认「我确实滑到位了 / 菜单确实开了」，重一档才有区分。
 * 用系统预设 `haptic.effect.soft/hard` 而不是自定义时长：预设会跟着系统的
 * 触觉强度设置走，自定义时长不会。
 */
export class Haptics {
  /** 轻档：滑过判定线的归档 / 收藏。 */
  static soft(): void {
    Haptics.fire(vibrator.HapticFeedback.EFFECT_SOFT);
  }

  /** 重档：删除档成立、长按菜单弹出、AI 面板展开。 */
  static hard(): void {
    Haptics.fire(vibrator.HapticFeedback.EFFECT_HARD);
  }

  private static fire(effect: string): void {
    try {
      const attr: vibrator.VibrateAttribute = { usage: 'touch' };
      const preset: vibrator.VibratePreset = { type: 'preset', effectId: effect };
      vibrator.startVibration(preset, attr).catch((err: BusinessError) => {
        hilog.debug(DOMAIN, TAG, 'vibration skipped: %{public}d', err.code);
      });
    } catch (err) {
      // 设备没有马达 / 触觉被系统关闭 / API 不可用：都不是错误，只是没有反馈。
      const error = err as BusinessError;
      hilog.debug(DOMAIN, TAG, 'vibration unavailable: %{public}d', error.code);
    }
  }
}
