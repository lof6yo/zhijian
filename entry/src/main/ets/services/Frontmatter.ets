import { Note } from '../models/Note';

export class ParsedNote {
  id: string = '';
  title: string = '';
  body: string = '';
  tags: string[] = [];
  archived: boolean = false;
  favorite: boolean = false;
  createdAt: number = 0;
  updatedAt: number = 0;
  excerpt: string = '';
  /**
   * Whether the file actually carried an `updated:` field.
   *
   * `updatedAt` falls back to *now* for a file with no frontmatter, which is the
   * right default when reading a note but poison for sync: a hand-written
   * Markdown file with no metadata would look like the most recent edit in the
   * vault and win against every real note. Sync must ask this flag instead of
   * comparing `updatedAt > 0`.
   */
  hasUpdatedAt: boolean = false;
  /** Whether the file carried an `id:` field. Files dropped in by hand do not. */
  hasId: boolean = false;
}

export class FrontmatterCodec {
  static parse(content: string): ParsedNote {
    const parsed = new ParsedNote();
    let text = content.replace(/\r\n/g, '\n');
    let frontmatter = '';
    let body = text;
    if (text.startsWith('---\n')) {
      const end = text.indexOf('\n---\n', 4);
      if (end >= 0) {
        frontmatter = text.substring(4, end);
        body = text.substring(end + 5);
      }
    }
    parsed.body = body;
    parsed.title = FrontmatterCodec.titleOf(body);
    parsed.excerpt = FrontmatterCodec.excerptOf(body);
    parsed.createdAt = FrontmatterCodec.now();
    parsed.updatedAt = parsed.createdAt;
    if (frontmatter.length === 0) {
      return parsed;
    }
    const lines = frontmatter.split('\n');
    for (const line of lines) {
      const idx = line.indexOf(':');
      if (idx <= 0) {
        continue;
      }
      const key = line.substring(0, idx).trim();
      const value = line.substring(idx + 1).trim();
      if (key === 'id') {
        parsed.id = FrontmatterCodec.unquote(value);
        parsed.hasId = parsed.id.length > 0;
      } else if (key === 'tags') {
        parsed.tags = FrontmatterCodec.parseTags(value);
      } else if (key === 'archived') {
        parsed.archived = value === 'true';
      } else if (key === 'favorite') {
        parsed.favorite = value === 'true';
      } else if (key === 'created') {
        parsed.createdAt = FrontmatterCodec.parseTime(value, parsed.createdAt);
      } else if (key === 'updated') {
        parsed.updatedAt = FrontmatterCodec.parseTime(value, parsed.updatedAt);
        parsed.hasUpdatedAt = true;
      }
    }
    return parsed;
  }

  /**
   * Serialises a note.
   *
   * The whole frontmatter block is regenerated, so a field that no longer exists
   * (the retired `pinned:`) disappears from the file the next time the note is
   * written — no migration pass needed. Readers must keep ignoring unknown keys,
   * which the `parse()` loop already does.
   */
  static build(note: Note): string {
    const tags = note.tags.map((tag: string) => `"${tag.replace(/"/g, '\\"')}"`).join(', ');
    const created = new Date(note.createdAt).toISOString();
    const updated = new Date(note.updatedAt).toISOString();
    return `---\nid: ${note.id}\ncreated: ${created}\nupdated: ${updated}\ntags: [${tags}]\narchived: ${note.archived}\nfavorite: ${note.favorite}\n---\n${note.body}`;
  }

  static titleOf(body: string): string {
    const lines = body.split('\n');
    for (const line of lines) {
      const text = line.trim();
      if (text.startsWith('# ')) {
        return text.substring(2).trim();
      }
    }
    return '无标题';
  }

  static excerptOf(body: string): string {
    let text = body;
    // 标题行不进摘要：卡片标题就渲染在摘要正上方，摘要再从 `# 标题` 开始读，
    // 一张卡上同一句话出现两次，第二行白白占掉两行高度。
    //
    // 只去掉**第一处** H1，且必须位于正文开头（允许前面有空行）——`# ` 出现在
    // 正文中间是合法的一级标题，把它当标题重复删掉会改变摘要的语义顺序。
    // 其它级别的 `#` 照旧只剥符号、保留文字：`## 小节` 是内容结构的一部分。
    text = text.replace(/^\s*# [^\n]*(\n|$)/, '');
    text = text.replace(/```[\s\S]*?```/g, ' ');
    text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, ' ');
    text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    text = text.replace(/^#{1,6}\s+/gm, '');
    // 任务列表的方括号必须先于列表符号剥掉：`^[-*+]\s+` 只吃 `- `，
    // 留下 `[x] ` 会原样出现在卡片摘要里（实测「无标题 周会 [x] 今天…」）。
    text = text.replace(/^[-*+]\s+\[[ xX]\]\s+/gm, ' ');
    text = text.replace(/^[-*+]\s+/gm, '');
    text = text.replace(/^\d+\.\s+/gm, '');
    text = text.replace(/^>\s?/gm, '');
    text = text.replace(/[*_~`]/g, '');
    text = text.replace(/\s+/g, ' ').trim();
    if (text.length > 120) {
      return text.substring(0, 120) + '…';
    }
    return text;
  }

  private static parseTags(value: string): string[] {
    let raw = value.trim();
    if (raw.startsWith('[') && raw.endsWith(']')) {
      raw = raw.substring(1, raw.length - 1);
    }
    if (raw.length === 0) {
      return [];
    }
    const result: string[] = [];
    const parts = raw.split(',');
    for (const part of parts) {
      const tag = FrontmatterCodec.unquote(part.trim());
      if (tag.length > 0 && !result.includes(tag)) {
        result.push(tag);
      }
    }
    return result;
  }

  private static unquote(value: string): string {
    let v = value.trim();
    if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith('\'') && v.endsWith('\'')))) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }

  private static parseTime(value: string, fallback: number): number {
    const time = Date.parse(FrontmatterCodec.unquote(value));
    return Number.isNaN(time) ? fallback : time;
  }

  private static now(): number {
    return Date.now();
  }
}
