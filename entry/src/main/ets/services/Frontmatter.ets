import { Note } from '../models/Note';

export class ParsedNote {
  id: string = '';
  title: string = '';
  body: string = '';
  tags: string[] = [];
  pinned: boolean = false;
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
      } else if (key === 'pinned') {
        parsed.pinned = value === 'true';
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

  static build(note: Note): string {
    const tags = note.tags.map((tag: string) => `"${tag.replace(/"/g, '\\"')}"`).join(', ');
    const created = new Date(note.createdAt).toISOString();
    const updated = new Date(note.updatedAt).toISOString();
    return `---\nid: ${note.id}\ncreated: ${created}\nupdated: ${updated}\ntags: [${tags}]\npinned: ${note.pinned}\nfavorite: ${note.favorite}\n---\n${note.body}`;
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
    text = text.replace(/```[\s\S]*?```/g, ' ');
    text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, ' ');
    text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    text = text.replace(/^#{1,6}\s+/gm, '');
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
