import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsStore } from '../services/SettingsStore';
import { Credentials } from '../services/Credentials';
import { SyncEngine, SyncOutcome } from '../services/SyncEngine';

const DOMAIN = 0x0000;
const TAG = 'ZhijianDavPage';

/**
 * 设置 › WebDAV 同步.
 *
 * Two things are deliberate here:
 *
 * - **The password is only ever written to Asset Store Kit**, never to
 *   `preferences` and never to source. The field starts empty even when a
 *   password is already stored — reading it back to prefill would put the secret
 *   in a UI node and in any screenshot of this page. A stored password is
 *   therefore shown as the placeholder 「已保存」, and leaving the field blank
 *   keeps the existing one.
 * - **Nothing syncs automatically on open.** A sync writes to both the vault and
 *   the server, so it stays an explicit tap until the conflict story has been
 *   exercised on real data.
 */
@ComponentV2
export struct WebDavPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Param accentColor: string = '#0A59F7';

  @Local url: string = '';
  @Local user: string = '';
  @Local password: string = '';
  @Local dnsIp: string = '';
  @Local proxy: string = '';
  @Local showDnsPin: boolean = false;
  @Local hasStoredPassword: boolean = false;
  @Local busy: boolean = false;
  /** 自动同步模式：0 = 关闭，1 = 打开时，2 = 定时。 */
  @Local autoSyncMode: number = 0;
  /** 自动同步间隔（分钟）。 */
  @Local autoSyncInterval: number = 15;
  @Local status: string = '';
  @Local statusOk: boolean = false;
  @Local lastSync: number = 0;

  aboutToAppear(): void {
    const settings = SettingsStore.instance;
    this.url = settings.davUrl;
    this.user = settings.davUser;
    this.dnsIp = settings.davDnsIp;
    this.proxy = settings.davProxy;
    this.showDnsPin = settings.davDnsIp.length > 0 || settings.davProxy.length > 0;
    this.lastSync = settings.syncFinishedAt;
    this.autoSyncMode = settings.autoSyncMode;
    this.autoSyncInterval = settings.autoSyncInterval;
    this.loadPasswordState();
  }

  build() {
    NavDestination() {
      // Two-layer split, same contract as `EditorPage`/`TrashPage`: the
      // backdrop expands into the system bands, the content does not. Expanding
      // the content column would drag the header under the status bar.
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_bg'))
          .hitTestBehavior(HitTestMode.None)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column() {
          this.Header()

          Scroll() {
            Column({ space: 12 }) {
              // The three inputs are written out inline rather than through a
              // `@Builder Field(...)` helper. A builder receives its arguments
              // by value, and a function-typed parameter passed that way did not
              // stay connected: the field rendered, but the `onChange` callback
              // never wrote back to `@Local`, so every submit saw an empty URL
              // while the TextInput's own buffer still displayed the text. The
              // duplication is the cheaper side of that trade.
              Column({ space: 6 }) {
                Text('服务器地址')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                TextInput({ text: this.url, placeholder: 'https://example.com/dav/' })
                  .type(InputType.Normal)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.glass_bg'))
                  .borderRadius(14)
                  .height(44)
                  .width('100%')
                  .padding({ left: 12, right: 12 })
                  .enabled(!this.busy)
                  .onChange((value: string) => {
                    this.url = value;
                  })
              }
              .width('100%')

              Column({ space: 6 }) {
                Text('用户名')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                TextInput({ text: this.user, placeholder: '用于基本认证' })
                  .type(InputType.Normal)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.glass_bg'))
                  .borderRadius(14)
                  .height(44)
                  .width('100%')
                  .padding({ left: 12, right: 12 })
                  .enabled(!this.busy)
                  .onChange((value: string) => {
                    this.user = value;
                  })
              }
              .width('100%')

              Column({ space: 6 }) {
                Text('密码')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                TextInput({
                  text: this.password,
                  placeholder: this.hasStoredPassword ? '已保存，留空则不修改' : '应用专用密码'
                })
                  .type(InputType.Password)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.glass_bg'))
                  .borderRadius(14)
                  .height(44)
                  .width('100%')
                  .padding({ left: 12, right: 12 })
                  .enabled(!this.busy)
                  .onChange((value: string) => {
                    this.password = value;
                  })
              }
              .width('100%')

              // Only needed when the network cannot resolve the server's name —
              // a LAN NAS without internal DNS, or any device whose resolver is
              // broken. TLS still validates the certificate against the
              // hostname above, so pinning an IP does not weaken security.
              if (this.showDnsPin) {
                Column({ space: 6 }) {
                  Text('直连 IP')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                  TextInput({ text: this.dnsIp, placeholder: '例如 192.0.2.1，留空则用系统 DNS' })
                    .type(InputType.Normal)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .placeholderColor($r('app.color.text_secondary'))
                    .backgroundColor($r('app.color.glass_bg'))
                    .borderRadius(14)
                    .height(44)
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                    .enabled(!this.busy)
                    .onChange((value: string) => {
                      this.dnsIp = value;
                    })
                }
                .width('100%')

                Column({ space: 6 }) {
                  Text('代理服务器')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                  TextInput({ text: this.proxy, placeholder: 'http://proxy:8080，留空则用系统设置' })
                    .type(InputType.Normal)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .placeholderColor($r('app.color.text_secondary'))
                    .backgroundColor($r('app.color.glass_bg'))
                    .borderRadius(14)
                    .height(44)
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                    .enabled(!this.busy)
                    .onChange((value: string) => {
                      this.proxy = value;
                    })
                }
                .width('100%')
              } else {
                Text('连不上？可设置「直连 IP」与「代理服务器」')
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: 2 })
                  .onClick(() => {
                    this.showDnsPin = true;
                  })
              }

              this.Hint()

              Row({ space: 10 }) {
                Button(this.busy ? '请稍候…' : '测试连接')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.chip_bg'))
                  .layoutWeight(1)
                  .height(44)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.runTest();
                  })
                Button(this.busy ? '同步中…' : '立即同步')
                  .fontSize(14)
                  .fontColor($r('app.color.on_accent'))
                  .backgroundColor(this.accentColor)
                  .layoutWeight(1)
                  .height(44)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.runSync();
                  })
              }
              .width('100%')
              .margin({ top: 4 })

              if (this.status.length > 0) {
                Text(this.status)
                  .fontSize(12)
                  .fontColor(this.statusOk ? $r('app.color.text_secondary') : $r('app.color.danger'))
                  .width('100%')
                  .padding(12)
                  .backgroundColor($r('app.color.glass_bg'))
                  .borderRadius(14)
              }

              if (this.lastSync > 0) {
                Text(`上次同步 · ${WebDavPage.formatTime(this.lastSync)}`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: 2 })
              }

              this.AutoSyncGroup()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 32 })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  Header() {
    Row({ space: 4 }) {
      Button('‹')
        .fontSize(28)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor(Color.Transparent)
        .width(44)
        .height(44)
        .accessibilityText('返回')
        .onClick(() => {
          this.pathStack.pop();
        })
      Text('WebDAV 同步')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text('zhijian/')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    // A compact 56 vp row with no top inset — `NavDestination` content already
    // starts below the status bar, so any `padding({ top })` here is dead space.
    .height(56)
    .padding({ left: 8, right: 16 })
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  AutoSyncGroup() {
    Column({ space: 10 }) {
      Text('自动同步')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Row({ space: 2 }) {
        this.AutoSyncChip('关闭', 0)
        this.AutoSyncChip('打开时', 1)
        this.AutoSyncChip('定时', 2)
      }
      .padding(3)
      .borderRadius(14)
      .backgroundColor($r('app.color.page_bg'))
      .width('100%')

      Text('间隔')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ top: 4, bottom: 0 })

      Row({ space: 2 }) {
        this.AutoSyncChip('5 分钟', 5, true)
        this.AutoSyncChip('15 分钟', 15, true)
        this.AutoSyncChip('30 分钟', 30, true)
        this.AutoSyncChip('60 分钟', 60, true)
      }
      .padding(3)
      .borderRadius(14)
      .backgroundColor($r('app.color.page_bg'))
      .width('100%')

      Text(this.autoSyncHint())
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ top: 2 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.glass_bg'))
    .borderRadius(16)
  }

  @Builder
  AutoSyncChip(label: string, value: number, isInterval: boolean = false) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.autoSyncSelected(value, isInterval) ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.autoSyncSelected(value, isInterval) ? this.accentColor : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(28)
      .borderRadius(14)
      .backgroundColor(this.autoSyncSelected(value, isInterval) ? $r('app.color.chip_bg') : Color.Transparent)
      .onClick(() => {
        if (isInterval) {
          SettingsStore.instance.setAutoSyncInterval(value);
          this.autoSyncInterval = value;
        } else {
          SettingsStore.instance.setAutoSyncMode(value);
          this.autoSyncMode = value;
        }
      })
      .accessibilityText(label)
  }

  private autoSyncSelected(value: number, isInterval: boolean): boolean {
    return isInterval ? this.autoSyncInterval === value : this.autoSyncMode === value;
  }

  /** 一句话说明当前这套自动同步到底会做什么。 */
  private autoSyncHint(): string {
    if (this.autoSyncMode === 0) {
      return '关闭：只有你手动同步（下拉笔记页，或点上面的「立即同步」）。';
    }
    const every: string = `每 ${this.autoSyncInterval} 分钟`;
    if (this.autoSyncMode === 1) {
      return `打开应用时同步一次；如果距上次同步不到 ${this.autoSyncInterval} 分钟就不重复同步。`;
    }
    return `应用在前台时${every}同步一次。退到后台就不再同步。`;
  }

  @Builder
  Hint() {
    Column({ space: 4 }) {
      Text('笔记以 Markdown 文件存放在服务器 zhijian/ 目录，首次同步会自动创建。')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
      Text('按笔记 ID 配对并按修改时间三方合并；两端同时修改时保留冲突副本，不会覆盖。')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
      Text('删除会同步到对端回收站并保留 30 天，不会直接销毁。')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 2, top: 2 })
  }

  /** Reads whether a password exists, without copying it into the UI. */
  private loadPasswordState(): void {
    Credentials.loadPassword()
      .then((value: string) => {
        this.hasStoredPassword = value.length > 0;
      })
      .catch((error: Error) => {
        hilog.warn(DOMAIN, TAG, 'password probe failed: %{public}s', error.message);
      });
  }

  /**
   * Persists the non-secret fields and, when the user typed one, the password.
   * A blank password means "keep what is stored" — the field is never prefilled,
   * so treating blank as "erase" would silently break sync on every edit.
   */
  private async saveSettings(): Promise<boolean> {
    const settings = SettingsStore.instance;
    const normalised = SyncEngine.normaliseBase(this.url);
    if (normalised.length === 0) {
      this.fail('请填写服务器地址');
      return false;
    }
    if (this.user.trim().length === 0) {
      this.fail('请填写用户名');
      return false;
    }
    settings.setDavUrl(normalised);
    settings.setDavUser(this.user.trim());
    settings.setDavHostAndIp(SyncEngine.hostOf(normalised), this.dnsIp.trim());
    settings.setDavProxy(this.proxy.trim());
    this.url = normalised;

    if (this.password.length > 0) {
      const stored = await Credentials.savePassword(this.password);
      if (!stored) {
        this.fail('密码保存失败');
        return false;
      }
      this.hasStoredPassword = true;
      this.password = '';
    } else if (!this.hasStoredPassword) {
      this.fail('请填写密码');
      return false;
    }

    const secret = await Credentials.loadPassword();
    SyncEngine.applySettings(settings, secret);
    return true;
  }

  private runTest(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = '';
    this.saveSettings()
      .then((ready: boolean) => {
        if (!ready) {
          return;
        }
        return SyncEngine.testConnection().then((outcome: SyncOutcome) => {
          this.applyOutcome(outcome);
        });
      })
      .catch((error: Error) => {
        hilog.error(DOMAIN, TAG, 'test failed: %{public}s', error.message);
        this.fail('连接失败，请检查网络');
      })
      .finally(() => {
        this.busy = false;
      });
  }

  private runSync(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = '';
    this.saveSettings()
      .then((ready: boolean) => {
        if (!ready) {
          return;
        }
        return SyncEngine.sync(SettingsStore.instance).then((outcome: SyncOutcome) => {
          this.applyOutcome(outcome);
          if (outcome.ok) {
            this.lastSync = outcome.finishedAt;
            promptAction.showToast({ message: outcome.message });
          }
        });
      })
      .catch((error: Error) => {
        hilog.error(DOMAIN, TAG, 'sync failed: %{public}s', error.message);
        this.fail('同步失败，请重试');
      })
      .finally(() => {
        this.busy = false;
      });
  }

  private applyOutcome(outcome: SyncOutcome): void {
    this.statusOk = outcome.ok;
    this.status = outcome.message;
  }

  private fail(message: string): void {
    this.statusOk = false;
    this.status = message;
  }

  private static formatTime(at: number): string {
    const date = new Date(at);
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hh = date.getHours().toString().padStart(2, '0');
    const mm = date.getMinutes().toString().padStart(2, '0');
    return `${month}-${day} ${hh}:${mm}`;
  }
}
