import { common } from '@kit.AbilityKit';
import { BusinessError, systemDateTime, zlib } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NoteStore } from './NoteStore';
import { FrontmatterCodec } from './Frontmatter';
import { Note } from '../models/Note';

const DOMAIN = 0x0000;
const TAG = 'HMStartTransfer';
const NOTES_DIR = 'notes';
const ATTACH_DIR = 'attachments';
const EXPORT_ZIP_NAME = 'zhijian-notes.zip';

/**
 * Local import/export of notes through the system document picker.
 * Export: `notes/*.md` (+ `attachments/`) are staged in the cache dir, zipped
 * with `zlib.compressFile`, then written to the URI the user picks.
 * Import: `.md` files are decoded as UTF-8; `.zip` archives are decompressed
 * into the cache dir and searched for markdown up to one level deep.
 */
export class TransferResult {
  ok: boolean = false;
  cancelled: boolean = false;
  count: number = 0;
  message: string = '';
}

/** One note staged for export: the file name to offer and the full `.md` text. */
export class ExportItem {
  name: string = '';
  content: string = '';
  constructor(name: string, content: string) {
    this.name = name;
    this.content = content;
  }
}

export class NoteTransfer {
  /** Exports all notes as a single zip chosen through the save picker. */
  static async exportZip(context: common.UIAbilityContext): Promise<TransferResult> {
    const result = new TransferResult();
    const stamp = systemDateTime.getTime();
    const cacheDir = context.cacheDir;
    const stagingDir = `${cacheDir}/zhijian-export-${stamp}`;
    const zipPath = `${cacheDir}/zhijian-notes-${stamp}.zip`;
    try {
      const notesDir = `${context.filesDir}/${NOTES_DIR}`;
      NoteTransfer.ensureDir(stagingDir);
      const count = NoteTransfer.stageNotes(notesDir, stagingDir);
      if (count === 0) {
        result.message = '没有可导出的笔记';
        return result;
      }
      await zlib.compressFile(stagingDir, zipPath,
        { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });

      const documentPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [EXPORT_ZIP_NAME];
      const uris = await documentPicker.save(options);
      if (uris.length === 0 || uris[0].length === 0) {
        result.cancelled = true;
        result.message = '已取消导出';
        return result;
      }
      NoteTransfer.copyToUri(zipPath, uris[0]);
      result.ok = true;
      result.count = count;
      result.message = `已导出 ${count} 篇笔记`;
      hilog.info(DOMAIN, TAG, 'export ok notes=%{public}d', count);
      return result;
    } catch (error) {
      NoteTransfer.logError('export failed', error);
      result.ok = false;
      result.message = '导出失败，请重试';
      return result;
    } finally {
      NoteTransfer.removeTree(stagingDir);
      NoteTransfer.removeFile(zipPath);
    }
  }

  /** Imports `.md` files and `.zip` archives selected by the user. */
  static async importFiles(context: common.UIAbilityContext): Promise<TransferResult> {
    const result = new TransferResult();
    const stamp = systemDateTime.getTime();
    const cacheDir = context.cacheDir;
    try {
      const documentPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['Markdown (.md)|.md', 'ZIP (.zip)|.zip'];
      options.maxSelectNumber = 20;
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        result.cancelled = true;
        result.message = '已取消导入';
        return result;
      }

      const notesDir = `${context.filesDir}/${NOTES_DIR}`;
      NoteTransfer.ensureDir(notesDir);
      let imported = 0;
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const lower = uri.toLowerCase();
        if (lower.endsWith('.md')) {
          if (NoteTransfer.importMarkdown(uri, notesDir)) {
            imported++;
          }
        } else if (lower.endsWith('.zip')) {
          const zipPath = `${cacheDir}/import-${stamp}-${i}.zip`;
          const outDir = `${cacheDir}/import-unzip-${stamp}-${i}`;
          try {
            NoteTransfer.copyToLocal(uri, zipPath);
            NoteTransfer.ensureDir(outDir);
            await zlib.decompressFile(zipPath, outDir,
              { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
            imported += NoteTransfer.importFromDir(outDir, notesDir, 0);
          } catch (zipError) {
            NoteTransfer.logError('unzip failed', zipError);
          } finally {
            NoteTransfer.removeFile(zipPath);
            NoteTransfer.removeTree(outDir);
          }
        }
      }

      NoteStore.instance.reload();
      result.count = imported;
      result.ok = imported > 0;
      result.message = imported > 0 ? `已导入 ${imported} 篇笔记` : '没有找到可导入的笔记';
      hilog.info(DOMAIN, TAG, 'import files=%{public}d notes=%{public}d', uris.length, imported);
      return result;
    } catch (error) {
      NoteTransfer.logError('import failed', error);
      result.ok = false;
      result.message = '导入失败，请重试';
      return result;
    }
  }

  /**
   * 导出指定的若干篇笔记（而不是整个笔记库）。
   *
   * 一篇时**不打包**：用户点「导出笔记」拿到的是一个 `.md`，双击就能在别的编辑器
   * 里打开，而不是一个还得先解压的 zip。两篇以上才打包——多个同名文件没法一次
   * 保存到同一个目录，zip 是唯一不丢文件的形态。
   *
   * 两个分支都写在 `cacheDir` 里再交给保存选择器，和 `exportZip()` 走同一条
   * 「先落盘、再拷进 URI」的路径：picker 给出的 URI 只能按文件句柄写，不能直接
   * 用文件系统 API 写。`finally` 必须把两条路各自的临时文件/目录都删掉——缓存
   * 目录不会自己回收，导出过的笔记正文留在里面等同于多存了一份副本。
   */
  static async exportItems(context: common.UIAbilityContext, items: ExportItem[]): Promise<TransferResult> {
    const result = new TransferResult();
    if (items.length === 0) {
      result.message = '没有可导出的笔记';
      return result;
    }
    const stamp = NoteTransfer.stampLabel();
    const cacheDir = context.cacheDir;
    const stagingDir = `${cacheDir}/zhijian-export-${stamp}`;
    const singlePath = `${cacheDir}/zhijian-export-${stamp}-single.md`;
    const zipPath = `${cacheDir}/zhijian-notes-${stamp}.zip`;
    try {
      if (items.length === 1) {
        const one = items[0];
        const fileName = NoteTransfer.withMdSuffix(one.name);
        NoteTransfer.writeText(singlePath, one.content);
        const uri = await NoteTransfer.pickSaveUri(context, fileName);
        if (uri.length === 0) {
          result.cancelled = true;
          result.message = '已取消导出';
          return result;
        }
        NoteTransfer.copyToUri(singlePath, uri);
        result.ok = true;
        result.count = 1;
        result.message = '已导出 1 篇笔记';
        hilog.info(DOMAIN, TAG, 'export single %{public}s', fileName);
        return result;
      }

      NoteTransfer.ensureDir(stagingDir);
      // 文件名就是笔记自己的 `relPath`，**不加序号前缀**。`notes/` 是平铺目录，
      // `relPath` 本身唯一，而 `0-a.md` 这样的名字解压后还得手工改回来才认识。
      // 只有真的重名（调用方传了重复项）才补一个 ` (2)`。
      const used: Set<string> = new Set<string>();
      for (const item of items) {
        const base = NoteTransfer.withMdSuffix(item.name);
        let name = base;
        let n: number = 2;
        while (used.has(name)) {
          name = NoteTransfer.withMdSuffix(`${item.name} (${n})`);
          n++;
        }
        used.add(name);
        NoteTransfer.writeText(`${stagingDir}/${name}`, item.content);
      }
      await zlib.compressFile(stagingDir, zipPath,
        { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
      const uri = await NoteTransfer.pickSaveUri(context, `zhijian-notes-${stamp}.zip`);
      if (uri.length === 0) {
        result.cancelled = true;
        result.message = '已取消导出';
        return result;
      }
      NoteTransfer.copyToUri(zipPath, uri);
      result.ok = true;
      result.count = items.length;
      result.message = `已导出 ${items.length} 篇笔记`;
      hilog.info(DOMAIN, TAG, 'export ok notes=%{public}d', items.length);
      return result;
    } catch (error) {
      NoteTransfer.logError('export items failed', error);
      result.ok = false;
      result.message = '导出失败，请重试';
      return result;
    } finally {
      NoteTransfer.removeTree(stagingDir);
      NoteTransfer.removeFile(singlePath);
      NoteTransfer.removeFile(zipPath);
    }
  }

  /** 导出一篇笔记：`exportItems` 的单篇特例，文件名沿用笔记自己的 `relPath`。 */
  static async exportNote(context: common.UIAbilityContext, note: Note): Promise<TransferResult> {
    const content = FrontmatterCodec.build(note);
    return NoteTransfer.exportItems(context, [new ExportItem(note.relPath, content)]);
  }

  // ---------------------------------------------------------------- export

  /** 统一弹一次保存选择器；用户取消时返回空串。 */
  private static async pickSaveUri(context: common.UIAbilityContext, fileName: string): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    const uris = await documentPicker.save(options);
    if (uris.length === 0 || uris[0].length === 0) {
      return '';
    }
    return uris[0];
  }

  /** 保证导出的文件名带 `.md`，否则系统会当成无后缀文件。 */
  private static withMdSuffix(name: string): string {
    const value = name.trim();
    return value.toLowerCase().endsWith('.md') ? value : `${value}.md`;
  }

  /**
   * 导出文件名里的时间戳：`20261026-1612`，不是裸毫秒。
   *
   * `1793002316511` 这种名字在文件管理器里既读不出日期，又长得几乎一样，
   * 一天导三次就分不清哪个是哪个。本地时间而非 UTC：用户是在自己的时区里找文件。
   */
  private static stampLabel(): string {
    const d = new Date();
    const p2 = (n: number): string => n.toString().padStart(2, '0');
    return `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}`
      + `-${p2(d.getHours())}${p2(d.getMinutes())}`;
  }

  /** 把文本写进缓存目录的临时文件，交给 `copyToUri` 使用。 */
  private static writeText(path: string, content: string): void {
    let file: fs.File | undefined = undefined;
    try {
      file = NoteTransfer.openOrThrow(path,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
    } finally {
      NoteTransfer.closeQuietly(file);
    }
  }

  /** Copies markdown (and the attachments folder) into the staging dir. */
  private static stageNotes(notesDir: string, stagingDir: string): number {
    let names: string[] = [];
    try {
      names = fs.listFileSync(notesDir);
    } catch (e) {
      return 0;
    }
    let count = 0;
    for (const name of names) {
      if (!name.endsWith('.md')) {
        continue;
      }
      const source = `${notesDir}/${name}`;
      try {
        if (fs.statSync(source).isDirectory()) {
          continue;
        }
        fs.copyFileSync(source, `${stagingDir}/${name}`);
        count++;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'skip %{public}s', name);
      }
    }
    const attachSource = `${notesDir}/${ATTACH_DIR}`;
    try {
      if (fs.accessSync(attachSource) && fs.statSync(attachSource).isDirectory()) {
        fs.copyDirSync(attachSource, `${stagingDir}/${ATTACH_DIR}`);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'attachments copy failed');
    }
    return count;
  }

  /** Streams a local file into a user-picked document URI. */
  private static copyToUri(localPath: string, uri: string): void {
    let source: fs.File | undefined = undefined;
    let target: fs.File | undefined = undefined;
    try {
      source = NoteTransfer.openOrThrow(localPath, fs.OpenMode.READ_ONLY);
      target = NoteTransfer.openOrThrow(uri,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const size = fs.statSync(localPath).size;
        const buffer = new ArrayBuffer(size);
        const read = fs.readSync(source.fd, buffer);
        if (read > 0) {
          fs.writeSync(target.fd, buffer.slice(0, read));
        }
      } catch (e) {
        NoteTransfer.logError('copy to uri failed', e);
        throw e as Error;
      }
    } finally {
      NoteTransfer.closeQuietly(source);
      NoteTransfer.closeQuietly(target);
    }
  }

  // ---------------------------------------------------------------- import

  /** Copies a picker URI into the app cache so binary APIs can read it. */
  private static copyToLocal(uri: string, destPath: string): void {
    let source: fs.File | undefined = undefined;
    let target: fs.File | undefined = undefined;
    try {
      source = NoteTransfer.openOrThrow(uri, fs.OpenMode.READ_ONLY);
      target = NoteTransfer.openOrThrow(destPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const size = fs.statSync(source.fd).size;
        const chunk = 64 * 1024;
        let offset = 0;
        while (offset < size) {
          const length = Math.min(chunk, size - offset);
          const buffer = new ArrayBuffer(length);
          const read = fs.readSync(source.fd, buffer, { offset: offset, length: length });
          if (read <= 0) {
            break;
          }
          fs.writeSync(target.fd, buffer.slice(0, read));
          offset += read;
        }
      } catch (e) {
        NoteTransfer.logError('copy to local failed', e);
        throw e as Error;
      }
    } finally {
      NoteTransfer.closeQuietly(source);
      NoteTransfer.closeQuietly(target);
    }
  }

  private static openOrThrow(path: string, mode: number): fs.File {
    try {
      return fs.openSync(path, mode);
    } catch (e) {
      NoteTransfer.logError('open failed', e);
      throw e as Error;
    }
  }

  private static closeQuietly(file: fs.File | undefined): void {
    if (file === undefined) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close failed');
    }
  }

  /** Reads a picked `.md` URI as UTF-8 and writes it into `notes/`. */
  private static importMarkdown(uri: string, notesDir: string): boolean {
    let file: fs.File | undefined = undefined;
    try {
      file = NoteTransfer.openOrThrow(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      const read = fs.readSync(file.fd, buffer);
      const bytes = new Uint8Array(buffer.slice(0, read));
      const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
      return NoteTransfer.writeUnique(notesDir, NoteTransfer.nameOf(uri), text);
    } catch (e) {
      NoteTransfer.logError('read markdown failed', e);
      return false;
    } finally {
      NoteTransfer.closeQuietly(file);
    }
  }

  /** Finds `.md` files in `dir` (and one level of subfolders) and copies them out. */
  private static importFromDir(dir: string, notesDir: string, depth: number): number {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return 0;
    }
    let count = 0;
    for (const name of names) {
      const full = `${dir}/${name}`;
      let isDir = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        if (depth === 0) {
          count += NoteTransfer.importFromDir(full, notesDir, depth + 1);
        }
        continue;
      }
      if (!name.endsWith('.md')) {
        continue;
      }
      try {
        const content = fs.readTextSync(full);
        if (NoteTransfer.writeUnique(notesDir, name, content)) {
          count++;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'skip %{public}s', name);
      }
    }
    return count;
  }

  /** Writes `content` under a non-colliding, sanitized `<name>.md`. */
  private static writeUnique(notesDir: string, fileName: string, content: string): boolean {
    const base = NoteTransfer.sanitize(NoteTransfer.baseNameOf(fileName));
    let candidate = `${base}.md`;
    try {
      let index = 2;
      while (fs.accessSync(`${notesDir}/${candidate}`)) {
        candidate = `${base} (${index}).md`;
        index++;
      }
    } catch (e) {
      NoteTransfer.logError('resolve file name failed', e);
      candidate = `${base} (${systemDateTime.getTime()}).md`;
    }
    let file: fs.File | undefined = undefined;
    try {
      file = NoteTransfer.openOrThrow(`${notesDir}/${candidate}`,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } catch (e) {
        NoteTransfer.logError('write note failed', e);
        return false;
      }
      return true;
    } catch (e) {
      NoteTransfer.logError('write note failed', e);
      return false;
    } finally {
      NoteTransfer.closeQuietly(file);
    }
  }

  // ---------------------------------------------------------------- helpers

  private static nameOf(uri: string): string {
    let value = uri;
    const query = value.indexOf('?');
    if (query >= 0) {
      value = value.substring(0, query);
    }
    const slash = value.lastIndexOf('/');
    let name = slash >= 0 ? value.substring(slash + 1) : value;
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      // Keep the raw segment when it is not valid percent encoding.
    }
    return name;
  }

  private static baseNameOf(fileName: string): string {
    return fileName.endsWith('.md') ? fileName.substring(0, fileName.length - 3) : fileName;
  }

  private static sanitize(name: string): string {
    let value = name.trim().replace(/[\\/:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim();
    if (value.length === 0) {
      value = `导入笔记-${systemDateTime.getTime()}`;
    }
    if (value.length > 80) {
      value = value.substring(0, 80).trim();
    }
    return value;
  }

  private static ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (e) {
      NoteTransfer.logError('mkdir failed', e);
      throw e as Error;
    }
  }

  private static removeFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cleanup file failed');
    }
  }

  private static removeTree(dir: string): void {
    try {
      if (fs.accessSync(dir)) {
        fs.rmdirSync(dir);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cleanup dir failed');
    }
  }

  private static logError(what: string, error: Object | undefined): void {
    const code = (error as BusinessError).code;
    const message = (error as BusinessError).message;
    hilog.error(DOMAIN, TAG, '%{public}s code=%{public}d message=%{public}s', what, code, message);
  }
}
