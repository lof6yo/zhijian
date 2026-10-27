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

  /**
   * 回车续写：在列表 / 待办 / 引用里敲回车时，自动带上下一项的前缀。
   *
   * ## 为什么是「比较前后两次文本」而不是监听按键
   *
   * `TextArea` 不告诉我们「用户按了哪个键」，只告诉我们「文本变成了什么」。
   * 所以判定必须落在**文本的差分**上：`next` 相对 `prev` 只多了一个 `\n`，
   * 就说明这是一次纯回车（粘贴、输入法组词、删改都不会满足这个条件）。
   * 这条判定同时挡掉了粘贴一段带列表的多行文本——那种情况不该续写。
   *
   * ## 为什么只在「那一行还叫列表」时续写
   *
   * 用户在列表里连敲两下回车的意思是「列表写完了」。所以在空列表项上再敲回车
   * 不是插入新的空项，而是**把这一项的前缀去掉**，让它退回普通段落——否则
   * 按多少次回车就多出多少个空圆点，列表永远退不出去。
   *
   * 匹配顺序不能调：`- [ ] ` 必须以任务项规则先试，否则会先命中普通的 `- `，
   * 续写出来的就是一个「没有方框」的列表项。
   *
   * 返回 `null` 表示「这不是续写」——调用方应保留输入框自己插进去的那个换行。
   *
   * 例：`prev = '- 甲'`、`next = '- 甲\n'` → `text = '- 甲\n- '`、`caret = 6`；
   * `prev = '- [ ] '`、`next = '- [ ] \n'`（空待办上再按回车）→ `text = '\n'`、
   * `caret = 0`，这一项退回普通段落，列表到此为止。
   */
  static autoContinue(prev: string, next: string): EditResult | null {
    // 长度差必须正好 1，且多出来的就是换行。
    if (next.length !== prev.length + 1) {
      return null;
    }
    // 插入点：前缀一致、该位是换行、其后仍然相同。
    //
    // 三条缺一不可：只比长度差，粘贴进来的「多一个字符」也会被当成回车；后两条
    // 确保那个换行是**新插入**的，而不是本来就在那里。
    let at: number = -1;
    for (let i: number = 0; i < next.length; i++) {
      if (next.charAt(i) === '\n' && next.substring(0, i) === prev.substring(0, i)
        && next.substring(i + 1) === prev.substring(i)) {
        at = i;
        break;
      }
    }
    if (at < 0) {
      return null;
    }
    // 插入点**之前**的那一行，也就是回车所在行。
    // `lastIndexOf` 的第二个参数是「从哪个下标往前找」；`at - 1` 避免把刚插入的
    // 这个换行本身当成上一行的结尾，否则 `lastLine` 永远是空串。
    const lineStart: number = next.lastIndexOf('\n', at - 1) + 1;
    const lastLine: string = next.substring(lineStart, at);

    const todo: RegExpMatchArray | null = lastLine.match(/^(\s*)([-*+])\s+\[[ xX]\]\s*(.*)$/);
    if (todo !== null) {
      return MarkdownEdits.continueLine(prev, next, at, lineStart, todo[1], todo[3], '- [ ] ');
    }
    const ordered: RegExpMatchArray | null = lastLine.match(/^(\s*)(\d+)\.\s+(.*)$/);
    if (ordered !== null) {
      const seq: number = parseInt(ordered[2], 10);
      const marker: string = `${isNaN(seq) ? 1 : seq + 1}. `;
      return MarkdownEdits.continueLine(prev, next, at, lineStart, ordered[1], ordered[3], marker);
    }
    const bullet: RegExpMatchArray | null = lastLine.match(/^(\s*)[-*+]\s+(.*)$/);
    if (bullet !== null) {
      return MarkdownEdits.continueLine(prev, next, at, lineStart, bullet[1], bullet[2], '- ');
    }
    const quote: RegExpMatchArray | null = lastLine.match(/^(\s*)>\s?(.*)$/);
    if (quote !== null) {
      return MarkdownEdits.continueLine(prev, next, at, lineStart, quote[1], quote[2], '> ');
    }
    // 普通段落：不接管，输入框自己保留那个换行。
    return null;
  }

  /**
   * 续写的公共部分：内容为空 → 清掉这一行的前缀退回普通段落；否则带上下一项。
   *
   * `prefix` 已经包含尾部空格（`- [ ] ` / `3. ` / `> `）。
   *
   * ## 退出列表时为什么是 `text = prev`
   *
   * 退出有两种写法，结果完全不同：
   *
   * - `text = prev`：用户按下的这个回车等于「什么都不插」，光标停在该行行首。
   *   `- 写完了` 敲回车 → 变回 `- 写完了`，光标在行首——**列表项本身还在**，
   *   用户还得自己删掉 `- `。这不是「退出列表」。
   * - 清掉该行的前缀、并把它和下一行之间的换行合成一个空行：`- 写完了\n` 变成
   *   `写完了\n`，下一段就落在列表外面。这才是第二次回车应有的语义。
   *
   * 所以这里取后者：把 `[lineStart, at]` 这一段（前缀 + 回车）替换成一个 `\n`，
   * 光标落在 `lineStart`——也就是那个空行的行首。
   */
  private static continueLine(prev: string, next: string, at: number, lineStart: number,
    indent: string, content: string, prefix: string): EditResult {
    if (content.trim().length === 0) {
      const text: string = next.substring(0, lineStart) + '\n' + next.substring(at + 1);
      const result: EditResult = { text: text, caret: lineStart };
      return result;
    }
    const insertion: string = `\n${indent}${prefix}`;
    const text: string = next.substring(0, at) + insertion + next.substring(at + 1);
    const result: EditResult = { text: text, caret: at + insertion.length };
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
