import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsStore } from './SettingsStore';

const DOMAIN = 0x0000;
const TAG = 'HMStartAutoSync';

/** 自动同步的模式。 */
export enum AutoSyncMode {
  /** 关闭：只有用户手动同步（下拉或 WebDAV 页面里的按钮）。 */
  Off = 0,
  /** 打开应用时同步一次（距上次尝试超过间隔才会真的同步）。 */
  OnOpen = 1,
  /** 定时同步：应用在前台时每隔一段时间同步一次。 */
  Interval = 2
}

/** 心跳间隔。它只做「该不该同步」的判断，本身不发请求。 */
const TICK_MS = 30000;

/**
 * 自动同步的调度与策略。
 *
 * ## 机制
 *
 * 一个**前台心跳**加一条策略。心跳每 30 秒醒一次，判断「现在该不该同步」，
 * 该就同步，不该就什么都不做——不发请求、不碰网络。空闲时的开销可以忽略。
 *
 * ## 为什么只在前台
 *
 * 后台同步需要申请后台任务权限（`backgroundMode` + 长期任务），系统还要让用户
 * 授权，而且一个本地优先的笔记应用**不应该在用户不知情时把内容发到服务器**。
 * 所以这里明确只做前台同步：应用退到后台就停表，回到前台再补一次判断。
 * 心跳因此由 Ability 的 `onForeground` / `onBackground` 驱动。
 *
 * ## 什么时候**不**同步
 *
 * 1. 没配 WebDAV（地址或用户名为空）。
 * 2. 上一次同步还没结束——同步是串行的，重叠会互相踩基线。
 * 3. **详情页开着**（阅读器、编辑器、WebDAV 页面都在 `NavPathStack` 里）。
 *    这条最要紧：阅读器里可能有未提交的草稿，同步会把文件改掉，随后草稿写回
 *    就会把同步下来的内容覆盖掉。宁可晚点同步。
 * 4. 距上次尝试不足间隔时间。连续失败时按指数退避，避免服务器被反复敲。
 *
 * ## 与手动同步的关系
 *
 * 手动（下拉）走同一条路径，只是跳过间隔与退避判断——用户明确要求了，就不该被
 * 策略拦下。
 */
export class AutoSync {
  static readonly instance: AutoSync = new AutoSync();

  /**
   * 真正跑一次同步。由外壳注入：只有页面层才知道同步完要刷新哪个列表。
   * 返回 true 表示成功。
   */
  runner: (() => Promise<boolean>) | null = null;

  /** 同步结束后的回调，用于刷新「上次同步 · …」。 */
  onDone: ((ok: boolean) => void) | null = null;

  /**
   * 详情页是否开着。同步期间有详情页就跳过——见类注释第 3 条。
   */
  detailOpen: boolean = false;

  private timer: number = -1;
  private running: boolean = false;
  private lastAttempt: number = 0;
  private failures: number = 0;

  /** 应用进入前台。 */
  start(): void {
    this.stop();
    this.timer = setInterval(() => {
      this.trigger(false);
    }, TICK_MS);
    // 回到前台时立刻判断一次：「打开时同步」就该在这一刻发生，而不是等
    // 第一个心跳（那会晚 30 秒）。
    this.trigger(false);
  }

  /** 应用退到后台：停表，不再有任何自动同步。 */
  stop(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  /**
   * 跑一次同步。
   *
   * `manual` 为真时跳过间隔与退避判断——用户明确要求了。
   */
  async trigger(manual: boolean): Promise<boolean> {
    if (this.running) {
      return false;
    }
    if (!manual && !this.shouldRun()) {
      return false;
    }
    if (this.runner === null) {
      return false;
    }
    this.running = true;
    this.lastAttempt = Date.now();
    let ok = false;
    try {
      ok = await this.runner();
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, 'auto sync failed: %{public}s', err.message);
      ok = false;
    }
    this.running = false;
    if (ok) {
      this.failures = 0;
    } else {
      this.failures++;
    }
    if (this.onDone !== null) {
      this.onDone(ok);
    }
    return ok;
  }

  /** 同步是否正在进行（供界面显示进度）。 */
  get busy(): boolean {
    return this.running;
  }

  /**
   * 策略判断：这个时刻该不该同步。
   *
   * 间隔不足时不跑。连续失败时把间隔按 2 的幂放大，最多 4 倍——服务器连着失败时
   * 不该继续敲它。
   */
  private shouldRun(): boolean {
    const settings = SettingsStore.instance;
    if (settings.autoSyncMode === AutoSyncMode.Off) {
      return false;
    }
    if (settings.davUrl.length === 0 || settings.davUser.length === 0) {
      return false;
    }
    if (this.detailOpen) {
      return false;
    }
    const intervalMs = settings.autoSyncInterval * 60 * 1000;
    const backoff = Math.min(Math.pow(2, this.failures), 4);
    const elapsed = Date.now() - this.lastAttempt;
    return elapsed >= intervalMs * backoff;
  }
}
