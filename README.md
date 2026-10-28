# 纸见 — HarmonyOS NEXT 原生 Markdown 笔记

**纸见** 是一个 **API 26 / Stage 模型 / ArkTS + ArkUI** 的原生鸿蒙笔记应用，
面向 **OpenCode V2 纯 vibe coding**：在没有 DevEco Studio、只有 Command Line
Tools + 模拟器的 Windows 机器上，也能完成“改代码 → 构建 → 签名 → 安装 →
截图/UI 树 → 读日志”的闭环。

- 应用名：`纸见`（桌面显示名走 `EntryAbility_label`）
- 包名：`com.hmprojects.hmstart`（为免重新签名暂未改动）
- 入口：`EntryAbility` → `pages/Index`
- 设备：`puraxview` 模拟器，`127.0.0.1:15000`
- 构建：DevEco CLI 1.3.6 / Hvigor 6.26.4 / SDK 26.0.0
- Agent：OpenCode V2（`.opencode/`）

## MVP 已跑通

- HDS 外壳（`HdsNavigation` + `HdsTabs`），底部 3 页签：笔记 / 标签 / 设置；
  悬浮页签栏，内容从其下方滚过；单层全局背景，切页签无拼接缝。
- 页面标题与右上两个圆形按钮同排；搜索圈就地展开为搜索框，不占第二行。
- 筛选条 / 排序条压缩在同一行（全部·收藏·归档 / 修改·标题·创建），随页签收放有动画。
- 官方沉浸光感：标题栏圆形按钮与搜索框走 `systemMaterial`，算力等级自适应；
  设置 › 外观 › 光感挡位（自适应 / 高 / 中 / 低）实时生效。
- 标题栏与页签栏的胶囊玻璃统一由 `glassEffect()` 生成，并叠加高光层。
- 原生块级编辑：点哪一块改哪一块（源码在上、渲染在下），另有「简单」整篇模式。
  正文首个 H1 即标题，文件名自动同步。
- 500 ms 防抖自动保存 + 返回保存；内容未变时不写盘，避免无谓的 `updatedAt` 抖动。
- 误触新建、一个字都没写就返回会丢弃空笔记（`purgeNote`，不进回收站）。
- 本地 `.md` + YAML frontmatter，笔记平铺在 `notes/`；回收站（`TrashPage`）。
- 搜索按标题/正文/标签过滤；点标签回到笔记页并把标签变成可见的查询条件。
- 笔记卡片左右滑动四档：右轻归档 / 右重删除（确认）/ 左轻收藏 / 左重 AI 洞见。
- AI 洞见（OpenAI 兼容接口）：左滑到底让模型给出标签，已有标签归一复用，
  没有才新建，与原标签**合并**而非覆盖；请求期间页面上有进度胶囊。
- 状态栏与手势条在主页、阅读页、回收站均与页面背景连续（深色模式已逐像素核对）。
- 应用图标为分层图标：3×3 蓝色马赛克背景层 + 白色折角纸前景层，各 1024×1024；
  由 `design/my-icon.png` 一张母版经 `scripts/gen-icon.ps1` 反解 alpha 拆分而来。

截图：`screenshots/`（`/screenshots` 不入库）。

## 快速开始

```powershell
cd D:\HMProjects\HMStart
. .\scripts\env.ps1          # 设置 CLT/SDK/OHOS_HDC_SERVER_PORT=18710
pwsh -NoProfile -File scripts\doctor.ps1

# 构建
scripts\build.ps1

# 本地签名 + 安装 + 启动（无需华为账号）
scripts\run.ps1

# 截图
scripts\shot.ps1 -Name home

# 查看最近错误日志
scripts\logs.ps1 -Minutes 5
```

启动 OpenCode：

```powershell
opencode
```

项目默认 Agent 是 `harmonyos`。常用命令：

| 命令 | 用途 |
|---|---|
| `/hs-doctor` | 工具链/MCP/设备/签名体检 |
| `/hs-docs <关键词>` | 查官方鸿蒙文档（知识 MCP） |
| `/hs-feature <需求>` | 端到端实现并验证 |
| `/hs-check` | ArkTS 静态检查 |
| `/hs-build` | 构建并修复第一个错误 |
| `/hs-run` | 安装并启动到模拟器 |
| `/hs-shot` | 截图并检查 UI |
| `/hs-layout` | 导出 UI 树 |
| `/hs-logs` | 查看错误/崩溃日志 |

## 目录

```text
AGENTS.md                    # 项目契约（自动加载）
.opencode/
  opencode.json              # V2 MCP / 权限 / 默认 Agent
  instructions/harmonyos.md  # 常驻硬规则
  agents/                    # harmonyos（primary）/ harmonyos-reviewer（subagent）
  skills/                    # harmonyos-app / harmonyos-verify
  commands/                  # hs-*.md
entry/src/main/ets/
  models/Note.ets            # 笔记模型（V2 @ObservedV2/@Trace）
  services/NoteStore.ets     # 平铺 .md 文件存储/本地仓库（含 purgeNote）
  services/Frontmatter.ets   # YAML frontmatter 编解码
  services/SettingsStore.ets # 主题/背景/强调色/光感挡位/编辑器排版
  common/Palette.ets         # 强调色 light/dark 色对
  common/WindowService.ets   # 系统栏内容色与图标明暗
  components/NoteCard.ets    # 瀑布流卡片（只接收 primitives）
  components/FormulaWeb.ets  # 块级公式（ArkWeb + 离线 KaTeX），全工程唯一的 Web
  pages/Index.ets            # HDS 外壳 + 3 页签 + 搜索/筛选/排序 + 设置
  pages/ReaderPage.ets       # 阅读 + 块级就地编辑（无模式切换）
  pages/TrashPage.ets        # 回收站 NavDestination
AppScope/resources/base/media/
  layered_image.json         # 分层图标：foreground/background，均 1024
entry/src/main/resources/rawfile/render/
  katex.html                 # 唯一的 Web 渲染页（块级公式）
  vendor/                    # katex.min.js / .css / KaTeX_*.woff2（离线）
scripts/                     # 环境/构建/签名/截图/日志/图标生成
signing/                     # 本地 debug 签名材料（.gitignore）
docs/vibe-coding-harmonyos.md# 环境与 Agent 配置深度研究
docs/prd-v0.1.md             # 产品需求 v0.1
```

## 包体构成

HAP ≈ 1.3 MB（release，实测 1,345 KB）。只有两件事：应用代码
（`ets/modules.abc` 524 KB，另有 `ets/symbolMap.map` 230 KB）和一套离线
KaTeX（`rawfile/render` 558 KB）。

曾经这里有 Mermaid（5.4 MB）、ECharts（1.1 MB）与一个 Vite 构建的 Crepe
编辑器（2.7 MB），合计占 HAP 的 93%，但没有一条 UI 路径能走到它们——图块被画成
「渲染未接入」占位卡片，`EditorPage` 也没有任何 `pushPath` 入口。删掉后包体从
10.5 MB 降到 ~1.3 MB。

另注：HAP 内的 rawfile 条目是 `method=stored`（不压缩），所以「传到手机」的实际
流量大头可以靠 HTTP gzip 再省一次；包体本身则以磁盘上的 HAP 为准。

## MCP

| Server | 状态 | 用途 |
|---|---|---|
| `harmonyos` | 启用 | 33 个工具：模拟器、构建、安装、启动、截图、UI 树/点击、hilog |
| `harmonyos-knowledge` | 启用 | 华为官方文档检索/全文（无需 Key） |
| `deveco` | 禁用 | 官方 `devecocli serve mcp`；需要 DevEco Studio 的 LSP，CLT-only 下不可用 |

设备 MCP 依赖 `OHOS_HDC_SERVER_PORT=18710`（本机 WSL2 占用了 hdc 默认的
8710）。`scripts/env.ps1` 和 MCP wrapper 已内置。

## 签名

- **本地模拟器**：`scripts\run.ps1` 使用 `signing/` 下的 OpenHarmony debug
  证书链 + bundle 专属 p7b，自动签名、安装、启动。仅用于模拟器。
- **真机/发布**：先 `devecocli auth login --no-prompt`，再
  `devecocli signature generate --product default`，然后
  `devecocli build` / `devecocli run`。
- `build-profile.json5` 故意不写 `signingConfigs`：hvigor 期望 DevEco 加密
  后的密码，明文会让构建挂起。详见 `signing/README.md`。

## 已知环境注意事项

- **hdc 8710 冲突**：WSL2 mirrored networking 的 `sshd-sess` 占用 8710。
  使用 `OHOS_HDC_SERVER_PORT=18710`；模拟器目标仍是 `127.0.0.1:15000`。
- **模拟器端口范围**：10000–16555；`5555` 会被 Emulator 7.0 拒绝。
- **OpenCode V2**：MCP 配置必须是 `mcp.servers`，用 `disabled` 而不是
  `enabled`；V2.0.32 没有可用 LSP runtime。
- **DevEco CLI `init --mcp`** 仍写 V1 形状，不要直接使用；以
  `.opencode/opencode.json` 为准。
- **修改 MCP 配置/ wrapper 后**：OpenCode 会缓存旧连接状态，`opencode mcp list`
  可能仍显示 failed。在 TUI 里用 `/mcps` 重连，或执行
  `opencode service restart`，再开新会话。

## 当前限制

- ZIP/Markdown 导入导出、源码模式、图片插入。
- 搜索目前是内存遍历；<1000 篇足够，规模上来再换 RDB `LIKE`/倒排索引。
- 自动同步只在前台做（30 s 心跳），详情页打开时不做。

完整研究、MCP 对比、验证记录见
[`docs/vibe-coding-harmonyos.md`](docs/vibe-coding-harmonyos.md)。
产品需求见 [`docs/prd-v0.1.md`](docs/prd-v0.1.md)。

