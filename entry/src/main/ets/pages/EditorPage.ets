import { webview } from '@kit.ArkWeb';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { SettingsStore } from '../services/SettingsStore';
import { Palette } from '../common/Palette';

const DOMAIN = 0x0000;
const TAG = 'HMStartEditor';

/**
 * How long a freshly created note stays discardable. Five seconds, per the
 * product request: long enough to swallow an accidental 新建笔记 tap, short
 * enough that it never surprises someone who paused to think.
 */
const DISCARD_WINDOW_MS: number = 5000;

/** The heading `NoteStore.createNote()` writes; a note still carrying it is empty. */
const UNTITLED_TITLE: string = '无标题';

/**
 * True when a body carries no user content: only the auto H1 and whitespace.
 *
 * This is deliberately a *semantic* test, not a byte comparison against the
 * skeleton. Crepe normalises the document it is handed (`'# 无标题\n\n'` echoes
 * back as `'# 无标题\n'`), so comparing bytes reports every freshly created note
 * as "edited" and the discard never fires. Stripping the heading and checking
 * for nothing left is immune to that normalisation, and it also treats
 * type-then-delete-everything as empty, which is the behaviour a user expects.
 */
function isBlankBody(body: string): boolean {
  const lines: string[] = body.split('\n');
  const rest: string[] = [];
  let skippedHeading: boolean = false;
  for (const line of lines) {
    const trimmed: string = line.trim();
    if (!skippedHeading && trimmed.startsWith('#')) {
      const heading: string = trimmed.replace(/^#+\s*/, '').trim();
      if (heading.length === 0 || heading === UNTITLED_TITLE) {
        skippedHeading = true;
        continue;
      }
    }
    rest.push(trimmed);
  }
  return rest.join('').length === 0;
}

class EditorBridge {
  onSave: (markdown: string) => void = () => {};
  onReady: () => void = () => {};

  save(markdown: string): void {
    this.onSave(markdown);
  }

  ready(): void {
    this.onReady();
  }
}

@ComponentV2
export struct EditorPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Event onChanged: () => void = () => {};
  @Local note: Note = new Note();
  @Local ready: boolean = false;
  @Local webReady: boolean = false;
  @Local status: string = '已保存';

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: EditorBridge = new EditorBridge();
  private saveTimer: number = -1;
  private pendingMarkdown: string = '';
  /**
   * True once the user has actually changed the document. The initial
   * `__setMarkdown` echo from the web bridge does not count — see
   * `handleMarkdown`.
   */
  private edited: boolean = false;
  /** When this editor was entered, for the mis-tap window. */
  private openedAt: number = 0;
  /**
   * A note created by 新建笔记 is disposable until the user touches it. Notes
   * opened from the list are never disposable — they always pre-date this page.
   */
  private disposable: boolean = false;

  aboutToAppear(): void {
    this.openedAt = systemDateTime.getTime();
    this.bridge.onSave = (markdown: string) => {
      this.handleMarkdown(markdown);
    };
    this.bridge.onReady = () => {
      this.webReady = true;
      this.status = '已就绪';
      setTimeout(() => {
        if (this.status === '已就绪') {
          this.status = '已保存';
        }
      }, 900);
    };
  }

  aboutToDisappear(): void {
    // `leaveEditor()` normally runs first (back button or back gesture). This
    // covers any other exit path — but it must only save, never discard: the
    // discard decision belongs to one explicit place so a note cannot be purged
    // after a save already wrote it.
    this.saveNow();
  }

  build() {
    NavDestination() {
      // Two layers, and the split matters: the backdrop expands into the system
      // bands, the content does not. Expanding the content `Column` instead would
      // drag the header up under the status bar; expanding nothing leaves the
      // status-bar band filled by the *window* background (measured `(0,0,0)`
      // against a `(16,16,18)` page in dark mode — the "editor is cut off from
      // the status bar" report). `NavDestination` is a full-bleed page, so it
      // owes this itself; the shell's `PageBackdrop` is not behind it.
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_bg'))
          .hitTestBehavior(HitTestMode.None)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column() {
          Row({ space: 8 }) {
          Button('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .width(44)
            .height(44)
            .onClick(() => {
              this.leaveEditor();
            })
          Column({ space: 1 }) {
            Text(this.note.title.length > 0 ? this.note.title : '无标题')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.status)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('本地笔记')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        // A compact 56 vp bar flush to the top. It previously used
        // `height(96)` + `padding({ top: 40 })` to clear the status bar, which
        // pushed the row 40 vp down and left 56 vp of dead space above it — the
        // "header sinks too far" defect. `NavDestination` content already begins
        // below the status bar (fullscreen layout is not used), so no top inset
        // is owed here.
        .height(56)
        .padding({ left: 8, right: 16 })
        .backgroundColor($r('app.color.page_bg'))

        Divider()
          .color($r('app.color.divider'))

        if (this.ready) {
          Stack({ alignContent: Alignment.Center }) {
            Web({ src: $rawfile('editor/index.html'), controller: this.controller })
              .javaScriptProxy({
                object: this.bridge,
                name: 'native',
                methodList: ['save', 'ready'],
                controller: this.controller
              })
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .onlineImageAccess(false)
              .fileAccess(false)
              .keyboardAvoidMode(WebKeyboardAvoidMode.RESIZE_VISUAL)
              .backgroundColor($r('app.color.page_bg'))
              .onPageBegin(() => {
                hilog.info(0x0000, 'HMStartWeb', 'page begin');
              })
              .onPageEnd(() => {
                hilog.info(0x0000, 'HMStartWeb', 'page end');
                const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                const isDark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
                const theme = isDark ? 'dark' : 'light';
                const settings = SettingsStore.instance;
                const accent = Palette.scheme(settings.accentMode).accent(isDark);
                const script = `window.__setTheme('${theme}');` +
                  `window.__setTypography(${settings.editorFontSize},${settings.editorLineHeight / 100});` +
                  `window.__setAccent('${accent}');` +
                  `window.__setMarkdown(${JSON.stringify(this.note.body)})`;
                this.controller.runJavaScript(script)
                  .then((value: string) => {
                    hilog.info(0x0000, 'HMStartWeb', 'setMarkdown result: %{public}s', value);
                  })
                  .catch((error: Error) => {
                    hilog.error(0x0000, 'HMStartWeb', 'setMarkdown failed: %{public}s', error.message);
                  });
              })
              .onConsole((event: OnConsoleEvent) => {
                hilog.info(0x0000, 'HMStartWeb', 'console: %{public}s', event.message.getMessage());
                return false;
              })
              .onErrorReceive((event: OnErrorReceiveEvent) => {
                hilog.error(0x0000, 'HMStartWeb', 'resource error %{public}d: %{public}s',
                  event.error.getErrorCode(), event.error.getErrorInfo());
              })
              .width('100%')
              .height('100%')

            if (!this.webReady) {
              Column({ space: 10 }) {
                LoadingProgress()
                  .width(32)
                  .height(32)
                  .color($r('app.color.accent'))
                Text('正在打开编辑器…')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.page_bg'))
              .hitTestBehavior(HitTestMode.Block)
            }
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
            Text('加载笔记…')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        }
        .height('100%')
        .width('100%')
      }
      .height('100%')
      .width('100%')
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.leaveEditor();
      return true;
    })
    .onReady((context: NavDestinationContext) => {
      const id = context.pathInfo.param as string;
      this.loadNote(id);
    })
  }

  private loadNote(id: string): void {
    const found = NoteStore.instance.find(id);
    if (found === undefined) {
      this.ready = false;
      return;
    }
    this.note = found;
    this.pendingMarkdown = found.body;
    // `aboutToAppear` normally stamps this. Guard anyway: a zero here would
    // silently disable the mis-tap discard, which is exactly the failure mode
    // that is hardest to notice.
    if (this.openedAt <= 0) {
      this.openedAt = systemDateTime.getTime();
    }
    // A note is disposable when it was created moments ago and still has no user
    // content. `createNote()` stamps `createdAt`, so a note opened from the list
    // can never satisfy this window.
    const age = this.openedAt - found.createdAt;
    this.disposable = age >= 0 && age < DISCARD_WINDOW_MS && isBlankBody(found.body);
    hilog.info(DOMAIN, TAG, 'load %{public}s age=%{public}d disposable=%{public}s',
      found.relPath, age, this.disposable ? 'true' : 'false');
    this.ready = true;
  }

  private handleMarkdown(markdown: string): void {
    // Crepe echoes the document back once after `__setMarkdown`, normalised
    // (trailing blank line dropped). A byte comparison against the loaded body
    // therefore flags every freshly created note as edited, which silently
    // defeated the mis-tap discard. `isBlankBody` is the invariant that survives
    // normalisation: the note is "touched" only once real content exists.
    if (!this.edited && isBlankBody(markdown)) {
      return;
    }
    this.edited = true;
    this.pendingMarkdown = markdown;
    this.status = '编辑中…';
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      this.persist();
    }, 500);
  }

  /**
   * Drops a note the user never actually wrote into, then pops.
   *
   * The user asked for a five-second window so that a mis-tapped 新建笔记 does not
   * leave an empty 无标题 note behind. The window alone is not enough: it would
   * also delete a note the user *did* start typing and then left quickly. So the
   * condition is both — created within the window **and** never edited. Time is
   * measured from when the note was created, not from the last write, so idling
   * in an untouched note still counts as a mis-tap.
   */
  private leaveEditor(): void {
    this.saveNow();
    if (this.disposable && !this.edited && this.withinDiscardWindow()) {
      NoteStore.instance.purgeNote(this.note);
      hilog.info(DOMAIN, TAG, 'discarded untouched note %{public}s', this.note.id);
      this.onChanged();
    }
    this.pathStack.pop({ saved: true });
  }

  private withinDiscardWindow(): boolean {
    if (this.openedAt <= 0) {
      return false;
    }
    return systemDateTime.getTime() - this.openedAt < DISCARD_WINDOW_MS;
  }

  private saveNow(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    this.persist();
  }

  private persist(): void {
    if (!this.ready || this.note.id.length === 0) {
      return;
    }
    const body = this.pendingMarkdown.length > 0 ? this.pendingMarkdown : this.note.body;
    // Opening and closing a note must not touch the file: a redundant write
    // bumps `updatedAt`, reorders the list and invalidates the `ForEach` key.
    if (body === this.note.body) {
      this.status = '已保存';
      return;
    }
    NoteStore.instance.saveNote(this.note, body);
    this.status = '已保存';
    this.onChanged();
  }
}
