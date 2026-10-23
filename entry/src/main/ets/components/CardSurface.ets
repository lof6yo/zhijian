import { MaterialLayer } from './MaterialLayer';

/**
 * 一张「卡」的表面：沉浸光感材质 + 半透明遮罩。
 *
 * 笔记卡片和设置页的分组卡片是**同一种东西**，所以共用这一个实现——两处的
 * 圆角、材质强度与遮罩浓度必须一致，否则设置页会看起来像另一个应用里的控件。
 *
 * ## 为什么要两层
 *
 * 材质（`systemMaterial`）的视觉层画在 `backgroundColor` **之上**、子节点**之下**。
 * 所以只写材质，材质会几乎看不出来：这一页的背景是近乎均匀的强调色浅色wash，
 * 材质采样它之后仍是同一个颜色（实测卡片与页面几乎同色，网格失去结构）。
 * 而只写不透明底色，材质又被完全盖住。
 *
 * 于是：材质在下负责边缘折射，半透明遮罩在上负责让卡片成为一张卡片。
 *
 * ## 挂载方式：必须用 `.background(builder)`
 *
 * 承载层用 `LayoutPolicy.matchParent` 量尺寸，而百分比高度在**内容驱动**的父级里
 * 按可用高度解析——把承载层做成 `Stack` 兄弟节点时，每张卡片都被撑成一屏高，
 * 后面的内容全被顶出视口。`.background(builder)` 是按节点自己已经测量好的框来
 * 布局的，撑不动。
 */
@ComponentV2
export struct CardSurface {
  /** 圆角 vp。与外层卡片的 `borderRadius` 一致，否则会出现内嵌的小圆角边框。 */
  @Param radius: number = 26;
  /** 是否绘制沉浸光感材质；false 时只画遮罩。 */
  @Param glassOn: boolean = false;
  /** 沉浸光感挡位，0 = 自适应 … 3 = 低。 */
  @Param glassGear: number = 0;
  /** 半透明遮罩色（ARGB）。 */
  @Param glassTint: string = '';

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.glassOn) {
        MaterialLayer({
          radius: this.radius,
          gear: this.glassGear
        })
      }
      if (this.glassTint.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(this.radius)
          .backgroundColor(this.glassTint)
      }
    }
    .width('100%')
    .height('100%')
  }
}
