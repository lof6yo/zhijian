import { AiReply, AiClient, AI_INSIGHT } from './AiClient';

/**
 * 一次「洞见」的结果。
 *
 * `tags` 是**已经跟已有标签对齐过**的最终名单：模型给的是接近的写法时（`AI` vs
 * `ai`、`鸿蒙` vs `HarmonyOS`），这里换成库里那份的写法，因为「再建一个近义标签」
 * 正是标签体系烂掉的方式。
 */
export class TagSuggestion {
  ok: boolean = false;
  tags: string[] = [];
  message: string = '';
}

/** 一次最多给几个。超过 4 个，卡片上的标签行就开始挤压标题了。 */
const MAX_TAGS: number = 4;

/** 送给模型的正文截断长度。开头几段足以判断主题，全文只会把请求撑大。 */
const BODY_LIMIT: number = 4000;

/** 单个标签的最大长度。超出的基本是模型把一句话当标签了。 */
const TAG_LIMIT: number = 18;

/**
 * AI 洞见：给一篇笔记自动打标签。
 *
 * ## 为什么结果要跟「库里的标签」比对
 *
 * 「打标签」最大的失败不是打错，而是**造近义词**：库里已经有 `工作`，模型给了
 * `职场`，下次又给 `办公`，标签页于是变成一堆各管一摊的同义词，筛谁都不全。
 * 所以两处都为这件事服务：
 * - 提示词里带上现有标签，并要求「意思相同就复用」；
 * - 解析时再做一次**确定性的**对齐（大小写 / 空白归一后比对），因为提示词管不住
 *   模型的手，代码能。
 *
 * ## 为什么新建标签不需要额外动作
 *
 * 标签的「存在」就等于「至少有一篇笔记带着它」——`NoteStore.setTags()` 写进
 * frontmatter，`collectTags()` 一收集，标签页就多一个。所以这里不调
 * `TagStore.addTag()`：那是给「刚建好、还没有笔记使用」的标签留的位置，AI 打的
 * 标签天生就有笔记，走那条路只会多一份可能与 frontmatter 不一致的名录。
 */
export class AiTags {
  /**
   * 跑一次并解析。
   *
   * `known` 是库里的全部标签（`Index.tagsSnapshot`）。给它空数组也成立，只是
   * 「复用」这一层失效。
   */
  static async suggest(title: string, body: string, known: string[]): Promise<TagSuggestion> {
    const result = new TagSuggestion();
    const text: string = body.trim();
    if (text.length === 0) {
      result.message = '这一篇还没有内容';
      return result;
    }
    const user: string = AiTags.buildUser(title, text, known);
    const reply: AiReply = await AiClient.chat(AI_INSIGHT, AiTags.systemPrompt(), user);
    if (!reply.ok) {
      result.message = reply.message;
      return result;
    }
    const parsed: string[] = AiTags.parse(reply.text);
    if (parsed.length === 0) {
      result.message = '模型没有给出可用的标签';
      return result;
    }
    result.ok = true;
    result.tags = AiTags.align(parsed, known);
    return result;
  }

  private static systemPrompt(): string {
    return '给下面这篇笔记打标签。只输出标签本身：每行一个，不要行首的 # 或 -，' +
      '不要编号，不要解释，不要输出任何别的话。' +
      '中文标签 2 到 4 个字，英文标签 1 到 2 个词。' +
      '数量 2 到 4 个，按重要程度排列。' +
      '**已有标签里意思相同或相近的，优先直接复用那个写法，不要另造近义词。**' +
      '标签描述的是这篇笔记「关于什么」，不是它「是什么文件」。';
  }

  private static buildUser(title: string, body: string, known: string[]): string {
    const trimmed: string = body.length > BODY_LIMIT ? body.substring(0, BODY_LIMIT) : body;
    const existing: string = known.length > 0 ? known.join('、') : '（库里还没有标签）';
    const head: string = title.trim().length > 0 && title.trim() !== '无标题'
      ? `标题：${title.trim()}\n\n`
      : '';
    return `已有标签：${existing}\n\n${head}正文：\n${trimmed}`;
  }

  /**
   * 把模型的自由文本切成标签。
   *
   * 分隔符不只换行：模型经常一句 `- 学习, Markdown` 把两三个标签写在一样里，
   * 也常用中文逗号或顿号。全部当分隔符切，比只按换行切稳得多。
   */
  static parse(raw: string): string[] {
    const out: string[] = [];
    const parts: string[] = raw.split(/[\n\r,，、;；|]+/);
    for (const part of parts) {
      const tag: string = AiTags.clean(part);
      if (tag.length === 0 || tag.length > TAG_LIMIT) {
        continue;
      }
      if (!out.includes(tag)) {
        out.push(tag);
      }
      if (out.length >= MAX_TAGS) {
        break;
      }
    }
    return out;
  }

  /** 去掉行首的列表符号 / 编号 / `#`，以及两端的引号与句末标点。 */
  private static clean(raw: string): string {
    let tag: string = raw.trim();
    tag = tag.replace(/^\d+\s*[.)、]\s*/, '');
    tag = tag.replace(/^[-*•·]\s*/, '');
    tag = tag.replace(/^[#＃]+\s*/, '');
    tag = tag.replace(/^["'“”‘’「」『』《》【】\[\]]+/, '');
    tag = tag.replace(/["'“”‘’「」『』《》【】\[\]]+$/, '');
    tag = tag.replace(/[。.!！?？:：]+$/, '');
    tag = tag.replace(/\s+/g, ' ');
    return tag.trim();
  }

  /**
   * 与库里已有标签对齐。
   *
   * 只按「归一后相等」替换写法，**不做模糊匹配**：把 `工作` 猜成 `工作流` 是错的，
   * 而这种错在标签上无法撤销（用户只会看到一个莫名其妙的标签）。
   */
  private static align(tags: string[], known: string[]): string[] {
    const canonical: Map<string, string> = new Map<string, string>();
    for (const item of known) {
      const key: string = AiTags.keyOf(item);
      if (!canonical.has(key)) {
        canonical.set(key, item);
      }
    }
    const out: string[] = [];
    for (const tag of tags) {
      const hit: string | undefined = canonical.get(AiTags.keyOf(tag));
      const value: string = hit !== undefined ? hit : tag;
      if (!out.includes(value)) {
        out.push(value);
      }
    }
    return out;
  }

  private static keyOf(tag: string): string {
    return tag.trim().replace(/\s+/g, ' ').toLowerCase();
  }
}
