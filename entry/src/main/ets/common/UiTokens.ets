/**
 * 视觉令牌：圆角与字号。
 *
 * 这个应用原来没有常量层，同一个数字在各页各写一遍，于是漂移成了
 * `Index.ets` 里 10/11/12/13/14/16/17 并存、`TrashPage` 12/16、`WebDavPage`
 * 14/16、`NoteCard` 6/7/10。相邻的两个控件差 2 vp 用户看不出来，只会觉得
 * 「没对齐」——所以问题不是某一处写错了，而是**没有一处说了算**。
 *
 * 这里只收两个维度，因为这两个维度的漂移最容易被看见：
 *
 * - **圆角三档**对应三种层级：控件（12）/ 胶囊（14）/ 大表面（17）。第 17 档
 *   不在这里定义——它已经是 `CARD_CORNER`（`services/SettingsStore.ets`），
 *   而且会随卡片圆角设置变化，**运行期可变**，不能被一个模块常量取代。
 * - **字号五档**对应「信息离眼睛有多远」：页头 / 卡片标题 / 正文 / 次要 / 微。
 *   五档之外的数（24 Bold、28）不再新增——回收站那行 24 Bold 的标题就是
 *   这么来的，与整应用的 16 Medium 页头并排时读起来像系统弹窗。
 *
 * 完整的取舍理由与使用边界见 `docs/ui-consistency.md`。改这里的值等于改
 * 整个应用的控件层级，必须先确认没有页面依赖旧的偏差（例如某个 `borderRadius(11)`
 * 的胶囊其实是靠更小的弧度才装得进 28 vp 的高度）。
 */

/** 控件圆角：按钮、输入框、行内动作（`TextAction`）。 */
export const RADIUS_CONTROL: number = 12;

/** 胶囊圆角：28 vp 的筛选项 / 排序项 / 分段项。 */
export const RADIUS_PILL: number = 14;

/** 页头标题。与 `PageHeader` 一致，替代各页的 24 / 16 / 28。 */
export const FONT_PAGE_TITLE: number = 16;

/** 卡片标题（笔记卡片、回收站行）。 */
export const FONT_CARD_TITLE: number = 15;

/** 正文。 */
export const FONT_BODY: number = 14;

/** 次要：副标题、时间戳、标签、行内动作。 */
export const FONT_SECONDARY: number = 12;

/** 微：后缀、状态提示。 */
export const FONT_MICRO: number = 11;
