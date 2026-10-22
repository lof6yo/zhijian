import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const STORE_NAME = 'hmstart_settings';
const KEY_THEME = 'themeMode';
const KEY_BACKGROUND = 'backgroundStyle';
const KEY_ACCENT = 'accentMode';
const KEY_FONT_SIZE = 'editorFontSize';
const KEY_LINE_HEIGHT = 'editorLineHeight';
const KEY_GLASS = 'glassLevel';
const KEY_DAV_URL = 'davUrl';
const KEY_DAV_USER = 'davUser';
const KEY_DAV_HOST = 'davDnsHost';
const KEY_DAV_IP = 'davDnsIp';
const KEY_DAV_PROXY = 'davProxy';
const KEY_SYNC_BASE = 'syncBase';
const KEY_SYNC_SCOPE = 'syncBaseScope';
const KEY_SYNC_AT = 'syncFinishedAt';

export const FONT_SIZE_MIN = 14;
export const FONT_SIZE_MAX = 22;
export const LINE_HEIGHT_MIN = 140;
export const LINE_HEIGHT_MAX = 220;

/**
 * 沉浸光感挡位, following the platform's own vocabulary rather than an invented
 * scale. The official model has two independent axes and it matters that they
 * stay independent:
 *
 *  - **算力等级** (`uiMaterial.MaterialLevel` = EXQUISITE/GENTLE/SMOOTH, i.e.
 *    高/中/低) is a property of the *device*. `uiMaterial` only exposes it
 *    read-only (`getGlobalMaterialLevel()`); the platform docs are explicit that
 *    it "不支持设置". `hdsMaterial.MaterialLevel` can be forced, but the docs
 *    warn that pinning EXQUISITE/GENTLE on a low-power device causes jank and
 *    heat, and recommend `ADAPTIVE`.
 *  - **厚度** (`uiMaterial.ImmersiveStyle` = ULTRA_THIN…ULTRA_THICK) is the knob a
 *    designer legitimately exposes.
 *
 * So the persisted gear encodes a *policy*, not a strength: `GEAR_ADAPTIVE`
 * defers to the device (the official default), and the other three are explicit
 * overrides for users who want to pin a look regardless of hardware.
 *
 * The numeric values are contiguous indices 0-3 — deliberately *not* the
 * `hdsMaterial.MaterialLevel` values (ADAPTIVE is 10 there, which would leave a
 * gap) — and `Index.glassGearLevel()` does the translation. Keep that mapping and
 * the per-gear tables in `Index` aligned.
 */
export const GEAR_ADAPTIVE = 0;
export const GEAR_HIGH = 1;
export const GEAR_MEDIUM = 2;
export const GEAR_LOW = 3;

export const GLASS_LEVEL_MIN = GEAR_ADAPTIVE;
export const GLASS_LEVEL_MAX = GEAR_LOW;
export const GLASS_LEVEL_DEFAULT = GEAR_ADAPTIVE;

/**
 * Small key-value settings store. Uses Preferences (not PersistenceV2) because
 * these values must be readable before the first frame and are not UI object
 * graphs.
 */
export class SettingsStore {
  static readonly instance: SettingsStore = new SettingsStore();

  themeMode: number = 0;
  backgroundStyle: number = 2;
  accentMode: number = 0;
  /** Editor body font size in px (web side uses px, not vp). */
  editorFontSize: number = 17;
  /** Editor line height as a percentage of the font size, e.g. 175 = 1.75. */
  editorLineHeight: number = 175;
  /** Immersive glass strength gear, 0 = restrained … 2 = deepest. */
  glassLevel: number = GLASS_LEVEL_DEFAULT;
  /** WebDAV base URL, normalised with a trailing slash. Not a secret. */
  davUrl: string = '';
  /** WebDAV username. The password lives in Asset Store, never here. */
  davUser: string = '';
  /** Hostname that the static DNS rule applies to; empty = use system DNS. */
  davDnsHost: string = '';
  /** IP that `davDnsHost` resolves to, for networks without working DNS. */
  davDnsIp: string = '';
  /** Optional CONNECT proxy URL; empty follows the device setting. */
  davProxy: string = '';
  /**
   * Last-sync baseline: one line per note, `id<TAB>updatedAt<TAB>relPath`.
   *
   * Three-way sync needs to know what the note looked like at the end of the
   * previous run, not just "what is on disk now". Without this baseline, a note
   * edited on both devices since the last sync is indistinguishable from one
   * edited on only one, and the engine would have to guess by timestamp —
   * silently destroying whichever edit happened first. A flat text blob keeps
   * the shape ArkTS handles comfortably: no index signatures, no untyped
   * `JSON.parse` result.
   */
  syncBase: string = '';
  /**
   * Which server the baseline belongs to: `<baseUrl>\t<username>`.
   *
   * The baseline is a set of *facts about one server*. Point the app at a
   * different URL and those facts become lies — every row claims "the server
   * held this id", the new server's listing does not contain it, and the merge
   * concludes the whole vault was deleted and files it all into 回收站. Scoping
   * the baseline keeps a server change on the safe side: an unrecognised scope
   * means "no baseline", which re-uploads instead of trashing.
   */
  syncBaseScope: string = '';
  /** Epoch ms of the last successful sync, 0 when never synced. */
  syncFinishedAt: number = 0;

  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;

  init(context: common.Context): void {
    if (this.initialized) {
      return;
    }
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      this.themeMode = this.readNumber(KEY_THEME, this.themeMode);
      this.backgroundStyle = this.readNumber(KEY_BACKGROUND, this.backgroundStyle);
      this.accentMode = this.readNumber(KEY_ACCENT, this.accentMode);
      this.editorFontSize = this.clamp(this.readNumber(KEY_FONT_SIZE, this.editorFontSize),
        FONT_SIZE_MIN, FONT_SIZE_MAX);
      this.editorLineHeight = this.clamp(this.readNumber(KEY_LINE_HEIGHT, this.editorLineHeight),
        LINE_HEIGHT_MIN, LINE_HEIGHT_MAX);
      this.glassLevel = this.clamp(this.readNumber(KEY_GLASS, this.glassLevel),
        GLASS_LEVEL_MIN, GLASS_LEVEL_MAX);
      this.davUrl = this.readString(KEY_DAV_URL, this.davUrl);
      this.davUser = this.readString(KEY_DAV_USER, this.davUser);
      this.davDnsHost = this.readString(KEY_DAV_HOST, this.davDnsHost);
      this.davDnsIp = this.readString(KEY_DAV_IP, this.davDnsIp);
      this.davProxy = this.readString(KEY_DAV_PROXY, this.davProxy);
      this.syncBase = this.readString(KEY_SYNC_BASE, this.syncBase);
      this.syncBaseScope = this.readString(KEY_SYNC_SCOPE, this.syncBaseScope);
      this.syncFinishedAt = this.readNumber(KEY_SYNC_AT, this.syncFinishedAt);
      this.initialized = true;
    } catch (error) {
      hilog.error(DOMAIN, 'SettingsStore', 'init failed: %{public}s', JSON.stringify(error));
    }
  }

  setThemeMode(mode: number): void {
    this.themeMode = mode;
    this.writeNumber(KEY_THEME, mode);
  }

  setBackgroundStyle(style: number): void {
    this.backgroundStyle = style;
    this.writeNumber(KEY_BACKGROUND, style);
  }

  setAccentMode(mode: number): void {
    this.accentMode = mode;
    this.writeNumber(KEY_ACCENT, mode);
  }

  setEditorFontSize(size: number): void {
    this.editorFontSize = this.clamp(Math.round(size), FONT_SIZE_MIN, FONT_SIZE_MAX);
    this.writeNumber(KEY_FONT_SIZE, this.editorFontSize);
  }

  setEditorLineHeight(percent: number): void {
    this.editorLineHeight = this.clamp(Math.round(percent), LINE_HEIGHT_MIN, LINE_HEIGHT_MAX);
    this.writeNumber(KEY_LINE_HEIGHT, this.editorLineHeight);
  }

  setGlassLevel(level: number): void {
    this.glassLevel = this.clamp(Math.round(level), GLASS_LEVEL_MIN, GLASS_LEVEL_MAX);
    this.writeNumber(KEY_GLASS, this.glassLevel);
  }

  setDavUrl(url: string): void {
    this.davUrl = url;
    this.writeString(KEY_DAV_URL, url);
  }

  setDavUser(user: string): void {
    this.davUser = user;
    this.writeString(KEY_DAV_USER, user);
  }

  setDavDnsHost(host: string): void {
    this.davDnsHost = host;
    this.writeString(KEY_DAV_HOST, host);
  }

  setDavDnsIp(ip: string): void {
    this.davDnsIp = ip;
    this.writeString(KEY_DAV_IP, ip);
  }

  /** Writes the host/IP pair in one flush; both halves are useless alone. */
  setDavHostAndIp(host: string, ip: string): void {
    this.davDnsHost = host;
    this.davDnsIp = ip;
    this.writeString(KEY_DAV_HOST, host);
    this.writeString(KEY_DAV_IP, ip);
  }

  setDavProxy(proxy: string): void {
    this.davProxy = proxy;
    this.writeString(KEY_DAV_PROXY, proxy);
  }

  setSyncBase(base: string): void {
    this.syncBase = base;
    this.writeString(KEY_SYNC_BASE, base);
  }

  /** Stores the baseline together with the server it describes. */
  setSyncState(base: string, scope: string): void {
    this.syncBase = base;
    this.syncBaseScope = scope;
    this.writeString(KEY_SYNC_BASE, base);
    this.writeString(KEY_SYNC_SCOPE, scope);
  }

  setSyncFinishedAt(at: number): void {
    this.syncFinishedAt = at;
    this.writeNumber(KEY_SYNC_AT, at);
  }

  private readNumber(key: string, fallback: number): number {
    if (this.prefs === null) {
      return fallback;
    }
    const value = this.prefs.getSync(key, fallback);
    return typeof value === 'number' ? value : fallback;
  }

  private clamp(value: number, min: number, max: number): number {
    return value < min ? min : (value > max ? max : value);
  }

  private readString(key: string, fallback: string): string {
    if (this.prefs === null) {
      return fallback;
    }
    const value = this.prefs.getSync(key, fallback);
    return typeof value === 'string' ? value : fallback;
  }

  private writeString(key: string, value: string): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(key, value);
      this.prefs.flush().catch((error: BusinessError) => {
        hilog.error(DOMAIN, 'SettingsStore', 'flush failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.error(DOMAIN, 'SettingsStore', 'write failed: %{public}s', JSON.stringify(error));
    }
  }

  private writeNumber(key: string, value: number): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(key, value);
      this.prefs.flush().catch((error: BusinessError) => {
        hilog.error(DOMAIN, 'SettingsStore', 'flush failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.error(DOMAIN, 'SettingsStore', 'write failed: %{public}s', JSON.stringify(error));
    }
  }
}
