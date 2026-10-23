import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { SettingsStore } from '../services/SettingsStore';
import { TagStore } from '../services/TagStore';
import { AutoSync } from '../services/AutoSync';
import { WindowService } from '../common/WindowService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    SettingsStore.instance.init(this.context);
    TagStore.instance.init(this.context);
    this.applyStoredTheme();    // Warm the ArkWeb engine during ability creation so the first editor open
    // does not pay the full WebView cold-start cost on top of the 2.7 MB bundle.
    try {
      webview.WebviewController.initializeWebEngine();
    } catch (error) {
      hilog.error(DOMAIN, 'testTag', 'Web engine init failed: %{public}s', JSON.stringify(error));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      this.mainWindow = windowStage.getMainWindowSync();
      WindowService.setMainWindow(this.mainWindow);
      // Do NOT call setWindowLayoutFullScreen(true) here. Re-confirmed on this
      // build: with fullscreen layout the HDS title bar collapses from 168 px to
      // 51 px (17 vp) — `HdsTitleBar` measured `[0,117][1320,168]` — because HDS
      // sizes itself from the status-bar inset. Immersion is achieved by letting
      // the *backdrop* bleed into the system bands with `expandSafeArea` (see
      // `Index.build()`), which paints under the status bar and gesture bar
      // without changing any layout.
      this.applySystemBars();
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.applySystemBars();
  }

  /**
   * 0 = follow system, 1 = light, 2 = dark.
   * EntryAbility owns this so a manual choice survives a cold start without a
   * first-frame light flash.
   */
  private applyStoredTheme(): void {
    const mode = SettingsStore.instance.themeMode;
    try {
      if (mode === 1) {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (mode === 2) {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (error) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(error));
    }
  }

  private applySystemBars(): void {
    WindowService.applySystemBars(this.isDarkNow());
  }

  private isDarkNow(): boolean {
    const mode = SettingsStore.instance.themeMode;
    if (mode === 2) {
      return true;
    }
    if (mode === 1) {
      return false;
    }
    return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  /**
   * 回到前台：起自动同步的心跳。
   *
   * 心跳只判断「该不该同步」，本身不发请求。它由 Ability 的前后台回调驱动，
   * 而不是由页面驱动——应用退到后台后页面还活着，继续自动同步就意味着在用户
   * 不知情时把内容发到服务器。
   */
  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    AutoSync.instance.start();
  }

  /** 退到后台：停表。 */
  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    AutoSync.instance.stop();
  }
}
