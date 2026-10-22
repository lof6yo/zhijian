import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

/**
 * Owns the single main window so system-bar colors can be updated from both
 * the ability (system theme changes) and the UI (manual theme changes).
 */
export class WindowService {
  private static mainWindow: window.Window | null = null;

  static setMainWindow(value: window.Window): void {
    WindowService.mainWindow = value;
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
}
