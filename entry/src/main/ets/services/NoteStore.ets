import { fileIo as fs } from '@kit.CoreFileKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Note, TrashEntry } from '../models/Note';
import { FrontmatterCodec } from './Frontmatter';

const NOTES_DIR = 'notes';
const TRASH = '.trash';
const TRASH_RETENTION_DAYS = 30;

@ObservedV2
export class NoteStore {
  static readonly instance: NoteStore = new NoteStore();

  @Trace notes: Note[] = [];
  @Trace tags: string[] = [];
  @Trace ready: boolean = false;

  private root: string = '';
  private initialized: boolean = false;

  init(filesDir: string): void {
    if (this.initialized) {
      return;
    }
    this.root = `${filesDir}/${NOTES_DIR}`;
    this.ensureDir(this.root);
    this.initialized = true;
    this.migrateLegacyFolders();
    this.reload();
    this.purgeExpiredTrash(TRASH_RETENTION_DAYS);
    if (this.notes.length === 0) {
      this.createSample();
    }
  }

  reload(): void {
    if (this.root.length === 0) {
      return;
    }
    const loaded: Note[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.root);
    } catch (e) {
      names = [];
    }
    for (const name of names) {
      if (!name.endsWith('.md')) {
        continue;
      }
      const full = `${this.root}/${name}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          continue;
        }
        const content = fs.readTextSync(full);
        const parsed = FrontmatterCodec.parse(content);
        const note = new Note();
        note.id = parsed.id.length > 0 ? parsed.id : name;
        note.title = parsed.title;
        note.body = parsed.body;
        note.tags = parsed.tags;
        note.pinned = parsed.pinned;
        note.favorite = parsed.favorite;
        note.createdAt = parsed.createdAt;
        note.updatedAt = parsed.updatedAt;
        note.excerpt = parsed.excerpt;
        note.folder = '';
        note.relPath = name;
        loaded.push(note);
      } catch (e) {
        // Skip unreadable files; do not break the whole list.
      }
    }
    this.notes = loaded;
    this.tags = this.collectTags(loaded);
    this.ready = true;
    hilog.info(0x0000, 'HMStartStore', 'reload notes=%{public}d', loaded.length);
  }

  find(id: string): Note | undefined {
    for (const note of this.notes) {
      if (note.id === id) {
        return note;
      }
    }
    return undefined;
  }

  createNote(): Note {
    const path = this.uniquePath('无标题', undefined);
    const note = new Note();
    note.id = `${systemDateTime.getTime().toString(36)}-${Math.floor(Math.random() * 100000)}`;
    note.title = '无标题';
    note.body = '# 无标题\n\n';
    note.folder = '';
    note.relPath = path;
    note.createdAt = systemDateTime.getTime();
    note.updatedAt = note.createdAt;
    this.writeNote(note);
    this.notes = [note, ...this.notes];
    hilog.info(0x0000, 'HMStartStore', 'create %{public}s notes=%{public}d', note.relPath, this.notes.length);
    return note;
  }

  saveNote(note: Note, body: string): void {
    if (this.root.length === 0 || note.relPath.length === 0) {
      return;
    }
    const title = FrontmatterCodec.titleOf(body);
    const safeTitle = this.sanitize(title);
    const currentFile = this.fileBase(note.relPath);
    if (safeTitle !== currentFile) {
      const nextRel = this.uniquePath(safeTitle, note.relPath);
      const oldFull = `${this.root}/${note.relPath}`;
      const newFull = `${this.root}/${nextRel}`;
      try {
        if (fs.accessSync(oldFull)) {
          fs.renameSync(oldFull, newFull);
        }
      } catch (e) {
        // If rename fails, keep the old path and rewrite it.
      }
      note.relPath = nextRel;
    }
    note.body = body;
    note.title = title;
    note.excerpt = FrontmatterCodec.excerptOf(body);
    note.updatedAt = systemDateTime.getTime();
    this.writeNote(note);
    this.notes = [...this.notes];
    this.tags = this.collectTags(this.notes);
    hilog.info(0x0000, 'HMStartStore', 'save %{public}s notes=%{public}d', note.relPath, this.notes.length);
  }

  /**
   * Moves a note into `.trash` and drops it from the index.
   *
   * Returns whether the file actually reached `.trash`, and the index is updated
   * only in that case. A failed rename used to remove the note from the list
   * anyway, which leaves the file on disk forever with nothing pointing at it —
   * invisible, uncounted, and re-read by the next `reload()` as if the user had
   * never deleted it. Keeping the row is the honest outcome: sync can then tell
   * "the move failed" from "the note is gone" and retry, and the list keeps
   * showing a note that still exists.
   */
  deleteNote(note: Note): boolean {
    const full = `${this.root}/${note.relPath}`;
    const trashDir = `${this.root}/${TRASH}`;
    this.ensureDir(trashDir);
    const name = this.uniqueTrashName(trashDir, `${systemDateTime.getTime()}-${this.fileName(note.relPath)}`);
    let trashed = true;
    try {
      if (fs.accessSync(full)) {
        fs.renameSync(full, `${trashDir}/${name}`);
      }
    } catch (e) {
      trashed = false;
      hilog.error(0x0000, 'HMStartStore', 'delete %{public}s could not be trashed: %{public}s',
        note.relPath, JSON.stringify(e));
    }
    if (!trashed) {
      return false;
    }
    this.notes = this.notes.filter((item: Note) => item.id !== note.id);
    this.tags = this.collectTags(this.notes);
    hilog.info(0x0000, 'HMStartStore', 'delete %{public}s trashed=%{public}s',
      note.relPath, name);
    return true;
  }

  /**
   * Deletes a note file outright, without moving it to `.trash`.
   *
   * For notes that never really existed: a mis-tapped 新建笔记 creates the file
   * up front so the editor can load it, and leaving it untouched must not leave a
   * 无标题 husk behind. Trashing it would be wrong — nothing was deleted by the
   * user, so it does not belong in 回收站 and must not occupy a retention slot.
   */
  purgeNote(note: Note): void {
    if (this.root.length === 0 || note.relPath.length === 0) {
      return;
    }
    const full = `${this.root}/${note.relPath}`;
    try {
      if (fs.accessSync(full)) {
        fs.unlinkSync(full);
      }
    } catch (e) {
      hilog.error(0x0000, 'HMStartStore', 'purge failed: %{public}s', JSON.stringify(e));
    }
    this.notes = this.notes.filter((item: Note) => item.id !== note.id);
    this.tags = this.collectTags(this.notes);
    hilog.info(0x0000, 'HMStartStore', 'purge %{public}s notes=%{public}d', note.relPath, this.notes.length);
  }

  /** Lists `.trash` markdown files, newest first. */
  trashEntries(): TrashEntry[] {
    const result: TrashEntry[] = [];
    const trashDir = `${this.root}/${TRASH}`;
    if (this.root.length === 0 || !fs.accessSync(trashDir)) {
      return result;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(trashDir);
    } catch (e) {
      return result;
    }
    for (const name of names) {
      if (!name.endsWith('.md')) {
        continue;
      }
      const full = `${trashDir}/${name}`;
      let size = 0;
      let isDir = false;
      try {
        const stat = fs.statSync(full);
        isDir = stat.isDirectory();
        size = stat.size;
      } catch (e) {
        isDir = true;
      }
      if (isDir) {
        continue;
      }
      const entry = new TrashEntry();
      entry.fileName = name;
      entry.deletedAt = this.trashTimeOf(name);
      entry.size = size;
      entry.title = this.trashTitleOf(full, name);
      result.push(entry);
    }
    result.sort((a: TrashEntry, b: TrashEntry): number => b.deletedAt - a.deletedAt);
    return result;
  }

  /** Moves one `.trash` file back into `notes/` under a non-colliding name. */
  restoreTrash(fileName: string): boolean {
    if (this.root.length === 0 || fileName.length === 0) {
      return false;
    }
    const trashDir = `${this.root}/${TRASH}`;
    const source = `${trashDir}/${fileName}`;
    try {
      if (!fs.accessSync(source)) {
        return false;
      }
      this.ensureDir(this.root);
      const base = this.fileBase(this.stripTrashTime(fileName));
      const target = this.uniquePath(base, undefined);
      fs.renameSync(source, `${this.root}/${target}`);
      this.reload();
      hilog.info(0x0000, 'HMStartStore', 'restore %{public}s -> %{public}s', fileName, target);
      return true;
    } catch (e) {
      hilog.error(0x0000, 'HMStartStore', 'restore failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** Permanently deletes a single trash file. */
  deleteTrashForever(fileName: string): boolean {
    if (this.root.length === 0 || fileName.length === 0) {
      return false;
    }
    const target = `${this.root}/${TRASH}/${this.fileName(fileName)}`;
    try {
      if (!fs.accessSync(target)) {
        return false;
      }
      fs.unlinkSync(target);
      hilog.info(0x0000, 'HMStartStore', 'trash purge %{public}s', fileName);
      return true;
    } catch (e) {
      hilog.error(0x0000, 'HMStartStore', 'trash purge failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** Deletes every entry in `.trash`; returns how many were removed. */
  emptyTrash(): number {
    const trashDir = `${this.root}/${TRASH}`;
    if (this.root.length === 0 || !fs.accessSync(trashDir)) {
      return 0;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(trashDir);
    } catch (e) {
      return 0;
    }
    let count = 0;
    for (const name of names) {
      const full = `${trashDir}/${name}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          fs.rmdirSync(full);
        } else {
          fs.unlinkSync(full);
        }
        count++;
      } catch (e) {
        // Skip files that cannot be removed; keep counting the rest.
      }
    }
    hilog.info(0x0000, 'HMStartStore', 'emptyTrash removed=%{public}d', count);
    return count;
  }

  /** Removes trash entries whose timestamp prefix is older than `days`. */
  purgeExpiredTrash(days: number = TRASH_RETENTION_DAYS): number {
    const trashDir = `${this.root}/${TRASH}`;
    if (this.root.length === 0 || !fs.accessSync(trashDir)) {
      return 0;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(trashDir);
    } catch (e) {
      return 0;
    }
    const cutoff = systemDateTime.getTime() - days * 24 * 60 * 60 * 1000;
    let count = 0;
    for (const name of names) {
      const deletedAt = this.trashTimeOf(name);
      if (deletedAt <= 0 || deletedAt >= cutoff) {
        continue;
      }
      const full = `${trashDir}/${name}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          fs.rmdirSync(full);
        } else {
          fs.unlinkSync(full);
        }
        count++;
      } catch (e) {
        // Skip; retry on the next launch.
      }
    }
    if (count > 0) {
      hilog.info(0x0000, 'HMStartStore', 'purgeExpiredTrash days=%{public}d removed=%{public}d', days, count);
    }
    return count;
  }

  togglePin(note: Note): void {
    note.pinned = !note.pinned;
    note.updatedAt = systemDateTime.getTime();
    this.writeNote(note);
    this.notes = [...this.notes];
  }

  toggleFavorite(note: Note): void {
    note.favorite = !note.favorite;
    note.updatedAt = systemDateTime.getTime();
    this.writeNote(note);
    this.notes = [...this.notes];
  }

  /**
   * Replaces a note's tag list and rewrites its frontmatter.
   *
   * Deliberately *not* routed through `saveNote()`: that renames the file to
   * match the body's H1, bumps `updatedAt` and re-derives the excerpt. Tagging
   * a note changes no prose, so doing that here would rename files behind the
   * user's back and invalidate every `ForEach` key for no reason. `updatedAt` is
   * still bumped, because sync must see this as an edit and push it.
   *
   * Returns the normalised list actually written, so the caller can render the
   * result without re-reading the file.
   */
  setTags(note: Note, tags: string[]): string[] {
    const cleaned: string[] = [];
    for (const raw of tags) {
      const tag = raw.trim().replace(/^#+/, '').replace(/\s+/g, ' ').trim();
      if (tag.length === 0 || cleaned.includes(tag)) {
        continue;
      }
      cleaned.push(tag);
    }
    note.tags = cleaned;
    note.updatedAt = systemDateTime.getTime();
    this.writeNote(note);
    this.notes = [...this.notes];
    this.tags = this.collectTags(this.notes);
    return cleaned;
  }

  countTag(tag: string): number {
    let count = 0;
    for (const note of this.notes) {
      if (note.tags.includes(tag)) {
        count++;
      }
    }
    return count;
  }

  private createSample(): void {
    const note = this.createNote();
    const body = `# 欢迎使用 纸见

这是一个本地优先的 Markdown 笔记应用。

## 可以做什么

- 点击右上角的 **新建笔记** 按钮开始书写
- 输入 \`# \`、\`- \`、\`> \` 体验 Markdown 快捷输入
- 在正文第一行写 H1，文件名会自动同步
- 标签会随着 frontmatter 自动更新

> 下一步会接入 WebDAV 同步、源码模式和图片。

\`\`\`ts
const hello = 'HarmonyOS';
\`\`\`

[了解 HarmonyOS](https://developer.huawei.com/)
`;
    note.title = '欢迎使用 纸见';
    note.tags = ['示例', 'Markdown'];
    note.body = body;
    note.updatedAt = systemDateTime.getTime();
    this.writeNote(note);
    this.notes = [note, ...this.notes.filter((item: Note) => item.id !== note.id)];
    this.tags = this.collectTags(this.notes);
  }

  private migrateLegacyFolders(): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.root);
    } catch (e) {
      return;
    }
    for (const name of names) {
      const dir = `${this.root}/${name}`;
      let isDir = false;
      try {
        isDir = fs.statSync(dir).isDirectory();
      } catch (e) {
        isDir = false;
      }
      if (!isDir || name === TRASH) {
        continue;
      }
      let files: string[] = [];
      try {
        files = fs.listFileSync(dir);
      } catch (e) {
        files = [];
      }
      for (const file of files) {
        if (!file.endsWith('.md')) {
          continue;
        }
        const target = this.uniquePath(this.fileBase(file), undefined);
        try {
          fs.renameSync(`${dir}/${file}`, `${this.root}/${target}`);
        } catch (e) {
          // Skip migration failures; leave the original in place.
        }
      }
    }
  }

  /**
   * Sync entry point: writes a note into the collection without applying the
   * "filename follows the H1" rule.
   *
   * `saveNote()` renames the file to match the body's first heading, which is
   * right for editing but wrong for sync — a downloaded note must land on the
   * path the *remote* chose, or the next sync uploads it again under a new name
   * and the vault grows a copy on every round trip.
   */
  importFromSync(note: Note): boolean {
    if (this.root.length === 0) {
      return false;
    }
    const relPath = this.uniquePath(note.title.length > 0 ? this.sanitize(note.title) : '无标题',
      undefined);
    note.relPath = relPath;
    note.folder = '';
    try {
      this.writeNote(note);
    } catch (e) {
      hilog.error(0x0000, 'HMStartStore', 'import failed: %{public}s', JSON.stringify(e));
      return false;
    }
    this.notes = [note, ...this.notes.filter((item: Note) => item.id !== note.id)];
    this.tags = this.collectTags(this.notes);
    return true;
  }

  /**
   * Sync entry point: replaces a note's content in place, keeping its existing
   * filename so the local list does not churn on every pull.
   */
  overwriteFromSync(note: Note): boolean {
    if (this.root.length === 0 || note.relPath.length === 0) {
      return false;
    }
    try {
      this.writeNote(note);
    } catch (e) {
      hilog.error(0x0000, 'HMStartStore', 'overwrite failed: %{public}s', JSON.stringify(e));
      return false;
    }
    this.notes = [...this.notes];
    this.tags = this.collectTags(this.notes);
    return true;
  }

  private writeNote(note: Note): void {
    this.ensureDir(this.root);
    const content = FrontmatterCodec.build(note);
    const path = `${this.root}/${note.relPath}`;
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
    } finally {
      if (file !== undefined) {
        fs.closeSync(file);
      }
    }
  }

  private collectTags(notes: Note[]): string[] {
    const result: string[] = [];
    for (const note of notes) {
      for (const tag of note.tags) {
        if (!result.includes(tag)) {
          result.push(tag);
        }
      }
    }
    result.sort((a: string, b: string): number => a.localeCompare(b));
    return result;
  }

  private uniquePath(base: string, currentRelPath: string | undefined): string {    const safe = this.sanitize(base);
    let candidate = `${safe}.md`;
    if (currentRelPath !== undefined && candidate === currentRelPath) {
      return candidate;
    }
    let index = 2;
    while (fs.accessSync(`${this.root}/${candidate}`)) {
      candidate = `${safe} (${index}).md`;
      index++;
    }
    return candidate;
  }

  /** Returns `preferred` if free in `dir`, otherwise `name (2).ext`, `name (3).ext`, ... */
  private uniqueTrashName(dir: string, preferred: string): string {
    if (!fs.accessSync(`${dir}/${preferred}`)) {
      return preferred;
    }
    const dot = preferred.lastIndexOf('.');
    const base = dot > 0 ? preferred.substring(0, dot) : preferred;
    const ext = dot > 0 ? preferred.substring(dot) : '';
    let index = 2;
    let candidate = `${base} (${index})${ext}`;
    while (fs.accessSync(`${dir}/${candidate}`)) {
      index++;
      candidate = `${base} (${index})${ext}`;
    }
    return candidate;
  }

  /** Extracts the leading `<milliseconds>-` prefix; returns 0 when absent. */
  private trashTimeOf(fileName: string): number {
    const dash = fileName.indexOf('-');
    if (dash <= 0) {
      return 0;
    }
    const raw = fileName.substring(0, dash);
    for (let i = 0; i < raw.length; i++) {
      const code = raw.charCodeAt(i);
      if (code < 48 || code > 57) {
        return 0;
      }
    }
    const value = Number.parseInt(raw, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /** Removes the leading `<milliseconds>-` prefix from a trash file name. */
  private stripTrashTime(fileName: string): string {
    const time = this.trashTimeOf(fileName);
    if (time <= 0) {
      return fileName;
    }
    const dash = fileName.indexOf('-');
    return dash >= 0 && dash + 1 < fileName.length ? fileName.substring(dash + 1) : fileName;
  }

  private trashTitleOf(fullPath: string, fileName: string): string {
    try {
      const parsed = FrontmatterCodec.parse(fs.readTextSync(fullPath));
      if (parsed.title.length > 0 && parsed.title !== '无标题') {
        return parsed.title;
      }
    } catch (e) {
      // Unreadable content; fall back to the file name below.
    }
    const base = this.fileBase(this.stripTrashTime(fileName));
    return base.length > 0 ? base : '无标题';
  }

  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  private sanitize(name: string): string {
    let value = name.trim().replace(/[\\/:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim();
    if (value.length === 0) {
      value = '无标题';
    }
    if (value.length > 80) {
      value = value.substring(0, 80).trim();
    }
    return value;
  }

  private fileBase(relPath: string): string {
    const name = this.fileName(relPath);
    return name.endsWith('.md') ? name.substring(0, name.length - 3) : name;
  }

  private fileName(relPath: string): string {
    const idx = relPath.lastIndexOf('/');
    return idx >= 0 ? relPath.substring(idx + 1) : relPath;
  }
}
