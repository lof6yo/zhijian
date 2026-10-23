/**
 * Markdown 文本的**纯函数**编辑操作。
 *
 * 抽成纯函数是为了让两条编辑路径共用同一套规则：整篇输入（记事本式）和分块编辑
 * 都必须把「列表」「待办」「粗体」变成同一段源码。逻辑留在 UI 里就会分叉——
 * 一边加了 `- [ ] `，另一边忘了先剥 `- `，同一颗按钮在两种模式里产出不同结果。
 *
 * 所有函数只接收文本与选区，返回新文本与**新光标位置**，不碰任何状态。
 */

/** 一次编辑的结果：新文本 + 光标应落在哪儿。 */
export interface EditResult {
  text: string;
  caret: number;
}

/** 已知的块级前缀，长的在前——否则 `- [ ] ` 会被 `- ` 抢先剥掉。 */
const LINE_PREFIXES: string[] = [
  '- [ ] ', '- [x] ', '- ', '* ', '+ ', '> ',
  '###### ', '##### ', '#### ', '### ', '## ', '# '
];

/** 2×2 表格骨架。手抄 `| --- |` 对不熟语法的人是不可能的。 */
const TABLE_SKELETON: string = '| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |';

export class MarkdownEdits {
  private static stripLinePrefix(line: string): string {
    for (const prefix of LINE_PREFIXES) {
      if (line.startsWith(prefix)) {
        return line.substring(prefix.length);
      }
    }
    return line;
  }

  /**
   * 行级前缀开关：整段已经有这个前缀就去掉，否则先剥掉别的再加。
   *
   * 空行不动——否则在代码块或表格里加列表会把结构改坏。
   */
  static togglePrefix(text: string, prefix: string): EditResult {
    const lines: string[] = text.split('\n');
    let allHave: boolean = lines.length > 0;
    for (const line of lines) {
      if (line.trim().length > 0 && !line.startsWith(prefix)) {
        allHave = false;
        break;
      }
    }
    const out: string[] = [];
    for (const line of lines) {
      if (line.trim().length === 0) {
        out.push(line);
        continue;
      }
      const bare: string = MarkdownEdits.stripLinePrefix(line);
      out.push(allHave ? bare : prefix + bare);
    }
    const next: string = out.join('\n');
    const result: EditResult = { text: next, caret: next.length };
    return result;
  }

  /**
   * 行内包裹：有选区就包住选区，没有就在光标处插入一对标记并停在中间。
   *
   * 光标位置按**插入后的文本**计算，所以调用方直接把 `caret` 交给输入框即可。
   */
  static wrap(text: string, selStart: number, selEnd: number, marker: string): EditResult {
    const start: number = Math.min(selStart, selEnd);
    const end: number = Math.max(selStart, selEnd);
    if (start === end) {
      const next: string = text.substring(0, start) + marker + marker + text.substring(end);
      const result: EditResult = { text: next, caret: start + marker.length };
      return result;
    }
    const picked: string = text.substring(start, end);
    const next: string = text.substring(0, start) + marker + picked + marker + text.substring(end);
    const result: EditResult = { text: next, caret: end + marker.length * 2 };
    return result;
  }

  /** 在末尾追加一个表格骨架；已有内容时空一行再插。 */
  static insertTable(text: string): EditResult {
    const base: string = text.replace(/\n+$/, '');
    const next: string = base.length === 0 ? TABLE_SKELETON : `${base}\n\n${TABLE_SKELETON}`;
    const result: EditResult = { text: next, caret: next.length };
    return result;
  }

  /** 格式按钮的语义 id → 具体操作。字符串 id 让按钮条与实现解耦。 */
  static apply(text: string, selStart: number, selEnd: number, action: string): EditResult {
    if (action === 'heading') {
      return MarkdownEdits.togglePrefix(text, '## ');
    }
    if (action === 'list') {
      return MarkdownEdits.togglePrefix(text, '- ');
    }
    if (action === 'todo') {
      return MarkdownEdits.togglePrefix(text, '- [ ] ');
    }
    if (action === 'quote') {
      return MarkdownEdits.togglePrefix(text, '> ');
    }
    if (action === 'table') {
      return MarkdownEdits.insertTable(text);
    }
    if (action === 'bold') {
      return MarkdownEdits.wrap(text, selStart, selEnd, '**');
    }
    if (action === 'italic') {
      return MarkdownEdits.wrap(text, selStart, selEnd, '*');
    }
    if (action === 'code') {
      return MarkdownEdits.wrap(text, selStart, selEnd, '`');
    }
    const unchanged: EditResult = { text: text, caret: selEnd };
    return unchanged;
  }
}
