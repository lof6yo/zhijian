# `MdParser` 语料 · 期望结果

这份文件是 `tools/md-parse-check.js` 的**人能读的版本**：每个 `corpus/*.md` 对应的
块序列、每条行内规则的期望 AST，以及解析器刻意做出的取舍。

跑一遍：

```powershell
cd D:\HMProjects\HMStart
node tools/md-parse-check.js            # 断言全跑
node tools/md-parse-check.js --verbose  # 额外打印每个 case 的块序列
```

harness 不是 JS 复刻：它把 `entry/src/main/ets/markdown/MdParser.ets` + `MdTypes.ets`
原样复制成 `tools/.tmp/*.mts`（只改写那一句 relative import），用 Node 24 内置的
`--experimental-transform-types` 跑起来。被测的就是发布的那份代码。

行内节点写成 `Kind{text, flags}`；没标的 flags 为 false。块序列以 `→` 连接。

---

## 01-atx-heading.md — ATX 标题

```markdown
# 一级标题
## 二级标题
####### 七个井号不是标题
#没有空格不是标题
###### 六级 {#six}
## 收尾井号 ##
```

```
Heading l1 "一级标题"
Heading l2 "二级标题"
Paragraph "####### 七个井号不是标题"     ← 7 个井号不是标题
Paragraph "#没有空格不是标题"             ← # 后必须有空格
Heading l6 "六级" anchor="six"            ← {#anchor} 被剥出，正文不带
Heading l2 "收尾井号"                     ← 收尾 # 序列被去掉
```

## 02-setext-vs-divider.md — **判定顺序**

```markdown
标题行
---

段落一

---

段落二
```

```
Heading l2 "标题行"    ← 紧跟文字行的 --- 是 setext 下划线
Paragraph "段落一"
Divider                ← 空行之后的 --- 才是分割线
Paragraph "段落二"
```

这是最容易写反的一处：先判分割线会得到「一段 + 一条线」。

## 03-table.md — 表格

```
Table aligns=[0,1,2] cols=3 rows=3
Paragraph "没有分隔行的表格 | 1 | 2 | | 3 | 4 |"   ← 缺分隔行 → 整块按段落
Paragraph "竖线转义"
Table aligns=[0] cols=1 rows=2 plain="列 a | b"    ← 单元格里的 \| 还原成 |
```

## 04-fence.md — 围栏

```
Code lang="js" hlLines=[1,3,4] code="const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;"
Code lang="" code="tilde fence"                     ← ~~~ 围栏
Code lang="mermaid" code="graph TD; A-->B;"        ← 图表语言名不再分叉，是普通代码块
Code lang="" code="未闭合的围栏\n还有一行"           ← 未闭合吃到文末，不抛异常
```

`{1,3-4}` 展开成 `[1,3,4]`（1 起）。文末的换行不算一行。

## 05-quote-callout.md — 引用与提示块

```
Paragraph "引用一段"      quoteDepth=1
Paragraph "第二段"        quoteDepth=1     ← 中间那行是 `>`（引用内的空行）
Callout Note "提示内容"   quoteDepth=1     ← 大写 NOTE + 换行 = 提示块
Paragraph "[!note] 小写不算提示块" quoteDepth=1  ← 小写按普通引用（同一段落内连成一行）
Paragraph "嵌套引用"      quoteDepth=2     ← >> 是两层
```

空行结束引用：`>` 后面没有内容才是引用内的空行。

## 06-list.md — 列表

```
ListItem "第一项"     indent=0 unordered
ListItem "第二项"     indent=0
ListItem "嵌套项"     indent=1        ← 2 空格 = 一层
ListItem "更深"       indent=2        ← 4 空格 = 两层
ListItem "第三项起"   indent=0 ordered seq=3   ← 起始序号进 seq
ListItem "括号形式"   indent=0 ordered seq=1 marker="1)"
ListItem "待办"       task=Todo
ListItem "已完成"     task=Done
ListItem "也算完成"   task=Done       ← [X] 也认
ListItem "星号"       marker="*"
ListItem "加号"       marker="+"
ListItem "续行第一行 续行第二行"       ← 深缩进的续行并入该项
```

## 07-inline.md — 行内规则的块级投影

`plain` 必须是行内片段拼回去的结果，所以标记一个都不该残留：

```
Paragraph "粗体 和 斜体 和 粗斜体"
Paragraph "** 内侧有空格 ** 不生效"   ← 内侧贴空格不配对
Paragraph "**粗* 数量不对称"          ← 数量不对称，整行不加粗
Paragraph "行内代码 和 含 ` 反引号"
Paragraph "删除线 和 高亮"
Paragraph "链接 和 图"
Paragraph "x^2 行内公式"
Paragraph "上标 和 下标"
Paragraph "转义 * 不是强调"
Paragraph "snake_case_name 不应当变斜体"
```

## 08-frontmatter.md — front matter + 脚注

```
Heading l1 "真标题"      srcLine=5   ← 行号是**归一化后**原文的真实行号
Paragraph "脚注引用n1。"  srcLine=7
Paragraph "注释内容"      srcLine=9   ← 脚注定义本身也是一块（MdNote.blockIndex 指向它）

outline: [{ level:1, text:"真标题", blockIndex:0, seq:1, anchor:"" }]
notes:   [{ no:1, label:"n1", text:"注释内容", blockIndex:2 }]
```

front matter 被整段跳过，**不产生块、不动行号**。正文里的 `[^n1]` 解析成
`Link{text:"n1", href:"#fn-n1", num:1}`，所以 `plain` 里出现的是 label（契约里
`MdInline.text` 对脚注引用的定义就是 label）。

## 09-paragraph-breaks.md — 软换行 / 硬换行

```
Paragraph "第一行 第二行"      ← 软换行连成一个空格
Paragraph "硬换行\n下一行"     ← 行尾两个空格 = 硬换行，用行内文本里的 \n 表达
```

## 10-math.md — 公式块

```
Math code="E = mc^2"
Math code="未闭合"      ← 未闭合也产出 Math 块，不吞后面的文本
```

## 11-chart.md — 图表语言名的围栏

```
Code lang="mermaid" code="graph TD\n  A --> B"   ← 缩进原样保留；不再是 Chart 块
```

## 14-math-mixed.md — 一行里既有块级公式又有正文

```
Math code="E = mc^2"                              ← 单行 `$$…$$` 独占一行才是块
Paragraph "E = mc^2 与行内 a+b=c 两种"             ← 行尾还有正文 → 整行是段落
```

判据必须收到**行尾**。只判「以 `$$` 开头」会把这行当成未闭合的公式块，把后面整篇
笔记吞成公式源码，KaTeX 再把它整段染红报错。退化成正文之后，行内的 `$$…$$` 与
`$…$` 都按**行内公式**收下（`plain` 里是去掉定界符的源码），否则紧接着的 `^`
会被上标规则抓走，`$$E = mc^2$$` 会渲染成 `$$E = mc2$$`。

## 12-garbage.md — 畸形输入

一个都不能抛异常，也不能吞掉文本：

```
Paragraph "#######"
Paragraph "|||"
Paragraph "["             quoteDepth=1
Paragraph "**未闭合粗体"
Paragraph "`未闭合代码"
Paragraph "[链接]("
Paragraph "</>"
```

## 13-image.md — 图片降级

```
Paragraph "独立图"                 inlines=[Image "独立图"]        ← 独立成段 = 图片
Paragraph "文字里 行内图 混排"      inlines=[Plain, Plain, Plain]   ← 混排 = 退化成 alt
```

---

# 行内用例（harness 内，24 条）

| 输入 | 期望 |
|---|---|
| `**粗**` | `Strong{粗, bold}` |
| `** 粗 **` | `Plain{"** 粗 **"}`（内侧贴空格不配对） |
| `**粗*` | `Plain{"**粗*"}`（数量不对称，整行不加粗） |
| `***粗***` | `Strong{粗, bold+italic}` |
| `*斜*` / `_斜_` | `Em{斜, italic}` |
| `a_b_c` | `Plain{"a_b_c"}`（词内 `_` 不是强调） |
| `前**粗**后` | `Plain{前} Strong{粗,bold} Plain{后}` |
| `**a *b* c**` | `Plain{"a ",bold} Em{"b",bold+italic} Plain{" c",bold}` |
| `**a\n\nb**` | `Plain{"**a\n\nb**"}`（不跨空行配对） |
| `` `a*b*c` `` | `Code{"a*b*c"}` |
| ```` ``a`b`` ```` | ``Code{"a`b"}`` |
| `~删~` | `Sub{删}` |
| `~~删~~` | `Strike{删, strike}` |
| `==高==` | `Mark{高}` |
| `^上^` | `Sup{上}` |
| `[链](https://a.b/c)` | `Link{链, href}` |
| `![alt](i.png)` | `Image{alt, href}`（`inlineOf()` 直接调用时不降级） |
| `\*不是强调\*` | `Plain{"*不是强调*"}` |
| `\q` | `Plain{"\q"}`（不可转义字符保留反斜杠） |
| `$x^2$` | `MathInline{"x^2"}` |
| `[^n1]`（无定义） | `Link{n1, href:"#fn-n1", num:0}` |
| `***` | `Plain{"***"}` |
| `` \`code\` `` | ``Plain{"`code`"}``（转义的反引号不开启代码段） |

其余断言：`plainOf` 不残留标记；`srcLine` 单调不减；`srcRangeOf` 恒为左闭右开且
`start === srcLine`；317 份畸形文档（含随机字节、80 个 `#`、`\u0000`、BOM）不抛异常；
10 万字符 / 2800 块的解析耗时 **~30 ms**（目标 < 150 ms）。

---

# 刻意做出的取舍（渲染侧需要知道）

1. **脚注引用没有专门的 kind。** `MdInlineKind` 里没有 `FootnoteRef`，所以正文里的
   `[^label]` 是 `Link`：`text`=label、`href`=`#fn-<label>`、`num`=序号（缺定义 0）。
   用 `num > 0` 区分「有定义」。
2. **独立成段的图片没有块种类。** `MdBlockKind` 里没有 Image，所以它是
   `Paragraph` 且 `inlines` 恰好只有一个 `Image`。混排的图片在**解析期**就降级成
   `Plain`（契约要求，`Span` 里塞图会破坏逐字坐标系）。
3. **硬换行用 `\n` 表达。** AST 没有 Break 种类；软换行连成空格。
4. **强调的样式既在标志位也在种类上。** 单一文本片段的强调结果同时把 `kind` 标成
   `Strong`/`Em`/`Strike` 并置 `bold`/`italic`/`strike`；含嵌套片段的（`**a *b* c**`）
   只能是 `Plain` + 标志位。两种读法都能正确渲染。
5. **脚注定义本身产出一个 `Paragraph`**（`plain` = 定义内容），以便 `MdNote.blockIndex`
   有落点；渲染侧可以按「`_fn:<label>` 这类标记」或直接忽略它。
6. **空行结束引用**（引用内的空行要写成 `>`）。否则紧跟在引用后面的 `> [!NOTE]`
   会被吞进上一段引用当正文，提示块直接消失。
7. **setext 的 `-` 要求 ≥3 个**（CommonMark 是 ≥1）。单个 `-` 紧跟文字行时判成标题
   会把「空列表项」升级成标题，代价比少支持一次单横线标题大。
8. **列表项内部的代码块 / 表格不识别**，只会当成续行文本。误识别会在列表里凭空
   长出块，宁可少支持。
9. **不认 HTML 块、不认引用式链接（`[a][b]` + `[b]: url`）、不认 `<small>` 等内联
   HTML。** §2 没要求，而且都能退化成本文本，不会误切文档。
10. **代码块 / 图表块 / 分割线不计入 `charCount` / `wordCount`**：它们不是「读的字」。
