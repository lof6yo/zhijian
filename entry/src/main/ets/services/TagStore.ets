import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const STORE_NAME = 'hmstart_tags';
const KEY_EXTRA = 'extraTags';
/**
 * 已废弃：标签置顶的字面量键。
 *
 * 「置顶」这个功能已经整体拆掉了，但**名字要留着**：安装过的机器上偏好文件里
 * 仍然存着 `pinnedTags`，Preferences 从不回收键，谁再拿这个名字去读，就会读到
 * 一份和现有功能对不上的旧数据。留在这里是为了让下一个人搜到它时知道它已停用，
 * 而不是认领它去存别的东西。
 */
const KEY_PINNED_RETIRED = 'pinnedTags';

/**
 * 标签本身的状态。
 *
 * ## 为什么需要它
 *
 * 标签是**长在笔记 frontmatter 里的字段**，「有哪些标签」可以从笔记推出来。但
 * **刚创建、还没有任何笔记使用的标签**推不出来——它不在任何一份 frontmatter 里，
 * 所以「创建标签」这个动作无处落地。
 *
 * 标签的**增删改**仍然作用在笔记的 frontmatter 上（`NoteStore.renameTag` /
 * `NoteStore.removeTag`），这里只保存「标签目录」这类笔记里放不下的状态。
 *
 * （此前这里还存过「置顶的标签」。置顶已整体移除，见 `KEY_PINNED_RETIRED`。）
 *
 * ## 存储格式
 *
 * 换行分隔的纯文本。标签名里不会出现换行，所以一行一个就够，也便于人肉查看；
 * 同步基线那套 `id \t updatedAt \t relPath` 的扁平文本格式也是同一个理由。
 */
export class TagStore {
  static readonly instance: TagStore = new TagStore();

  /** 已创建但还没有任何笔记使用的标签。 */
  extra: string[] = [];

  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;

  init(context: common.Context): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      this.extra = this.readList(KEY_EXTRA);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, 'HMStartTags', 'init failed code=%{public}d', err.code);
    }
  }

  /**
   * 创建一个标签。
   *
   * 名字重复时直接返回 false：同名标签就是同一个标签，再建一份只会让列表里出现
   * 两个一模一样的条目。
   */
  addTag(tag: string): boolean {
    const name = tag.trim();
    if (name.length === 0 || this.extra.includes(name)) {
      return false;
    }
    this.extra = this.extra.concat([name]);
    this.writeList(KEY_EXTRA, this.extra);
    return true;
  }

  /** 删除标签：连同名录一起清掉。笔记侧由 `NoteStore.removeTag` 处理。 */
  removeTag(tag: string): void {
    this.extra = this.extra.filter((item: string) => item !== tag);
    this.writeList(KEY_EXTRA, this.extra);
  }

  /** 重命名：旧名从名录里退场，新名接替它的位置。 */
  renameTag(oldTag: string, newTag: string): void {
    const name = newTag.trim();
    if (name.length === 0 || name === oldTag) {
      return;
    }
    const extra: string[] = [];
    for (const item of this.extra) {
      extra.push(item === oldTag ? name : item);
    }
    this.extra = extra;
    this.writeList(KEY_EXTRA, this.extra);
  }

  /**
   * 名录里的全部标签 = 笔记里出现过的 + 单独创建过的。
   *
   * 调用方负责把「笔记里出现过的」传进来，因为那部分只有它知道。
   */
  knownTags(fromNotes: string[]): string[] {
    const result: string[] = fromNotes.slice();
    for (const item of this.extra) {
      if (!result.includes(item)) {
        result.push(item);
      }
    }
    return result;
  }

  private readList(key: string): string[] {
    if (this.prefs === null) {
      return [];
    }
    const value = this.prefs.getSync(key, '');
    if (typeof value !== 'string' || value.length === 0) {
      return [];
    }
    const items: string[] = [];
    for (const line of value.split('\n')) {
      const item = line.trim();
      if (item.length > 0) {
        items.push(item);
      }
    }
    return items;
  }

  private writeList(key: string, items: string[]): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(key, items.join('\n'));
      this.prefs.flush().catch((error: BusinessError) => {
        hilog.error(DOMAIN, 'HMStartTags', 'flush failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.error(DOMAIN, 'HMStartTags', 'write failed: %{public}s', JSON.stringify(error));
    }
  }
}
