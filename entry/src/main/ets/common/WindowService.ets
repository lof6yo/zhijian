import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

/**
 * Owns the single main window so system-bar colors can be updated from both
 * the ability (system theme changes) and the UI (manual theme changes).
 */
export class WindowService {
  private static mainWindow: window.Window | null = null;
  /**
   * 状态栏高度（vp）。
   *
   * 页面用 `ignoreLayoutSafeArea` 做沉浸，内容原点就是**窗口顶端**，而不是状态栏
   * 下沿——所以「顶栏让开之后内容顶上去了」时，顶上那一块正好落在状态栏底下。
   * 顶栏收起后筛选胶囊要贴到状态栏下沿而不是窗口上沿，就得知道这个数。
   *
   * 从 `getWindowAvoidArea(TYPE_SYSTEM)` 读，不写死：这个值随机型和状态栏
   * 显示内容（灵动通知）变化。读不到时退回 0，那时胶囊会贴窗口上沿——难看，
   * 但不至于错位到别的区域。
   */
  private static statusBarVp: number = 0;

  static setMainWindow(value: window.Window): void {
    WindowService.mainWindow = value;
    WindowService.measureStatusBar();
  }

  /** 状态栏高度（vp）；未知时为 0。 */
  static statusBarHeightVp(): number {
    return WindowService.statusBarVp;
  }

  static applySystemBars(isDark: boolean): void {
    if (WindowService.mainWindow === null) {
      return;
    }
    WindowService.mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: isDark ? '#FFFFFF' : '#1A1A1A',
      navigationBarContentColor: isDark ? '#FFFFFF' : '#1A1A1A',
      isStatusBarLightIcon: isDark,
      isNavigationBarLightIcon: isDark
    }).catch((error: BusinessError) => {
      hilog.error(DOMAIN, 'WindowService', 'System bar failed: %{public}s', JSON.stringify(error));
    });
  }

  private static measureStatusBar(): void {
    if (WindowService.mainWindow === null) {
      return;
    }
    try {
      const area = WindowService.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const density = display.getDefaultDisplaySync().densityPixels;
      if (density > 0) {
        WindowService.statusBarVp = area.topRect.height / density;
      }
    } catch (error) {
      const e = error as BusinessError;
      hilog.warn(DOMAIN, 'WindowService', 'avoid area failed: %{public}d', e.code);
    }
  }
}
