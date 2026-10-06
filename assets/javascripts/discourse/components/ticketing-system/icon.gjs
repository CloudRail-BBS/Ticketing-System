import Component from "@glimmer/component";

// 内联 SVG 图标集。
//
// 为什么不用核心的 d-icon：
//
//   `d-icon` 已从 `discourse/helpers/d-icon` 移到 `discourse/ui-kit/helpers/d-icon`
//   （ui-kit 目录是 2026-09-08 的一次重组新建的），旧路径直接 404，且它**不再**是
//   自动注册的模板辅助函数——核心每个用到它的模板都显式 import。
//
// 在一个 .gjs 里 import 一个不存在的模块，后果不是「这个图标不显示」，而是
// Discourse 的 js_compiler 把**整个插件 bundle** 替换成一行
// `throw new Error("… not in scope …")`：所有组件一起失效，路由也注册不上，
// 浏览器控制台只留一条指向别处的报错。为了一个图标付这个代价不值得。
//
// 自己画：零依赖、任何版本都能跑，`stroke="currentColor"` 让它自动跟随主题配色。
const PATHS = {
  ticket:
    "M2.5 3.5h11v9h-11zM2.5 7h3.5a2 2 0 0 0 4 0h3.5",
  plus: "M8 3.5v9M3.5 8h9",
  search: "M7 12a5 5 0 1 0 0-10 5 5 0 0 0 0 10zM10.8 10.8l3 3",
  chevronLeft: "M10 3L5 8l5 5",
  chevronRight: "M6 3l5 5-5 5",
  refresh: "M13.5 8a5.5 5.5 0 1 1-1.7-4M13.5 2.5V5.2h-2.7",
  lock: "M5.5 7.2V5.4a2.5 2.5 0 0 1 5 0v1.8M4 7.2h8v6H4z",
  user:
    "M8 8.2a2.6 2.6 0 1 0 0-5.2 2.6 2.6 0 0 0 0 5.2zM2.8 14c0-2.5 2.3-4 5.2-4s5.2 1.5 5.2 4",
  close: "M4 4l8 8M12 4l-8 8",
  check: "M3 8.4l3.4 3.4L13 5.2",
  alert: "M8 2.2l6 11.6H2zM8 6.2v3.2M8 11.6h.01",
  clock: "M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM8 5v3.6l2.4 1.4",
  inbox: "M2 9.2h3.2l1 2h3.6l1-2H14M2 9.2l2.2-5.4h7.6L14 9.2v4.4H2z",
  tag: "M2.4 8.2l5.8-5.8h5.4v5.4l-5.8 5.8zM10.6 5.4h.01",
  building: "M3 14V3h6.2v11M9.2 7h3.8v7M5 6h2.2M5 9h2.2M5 12h2.2M11 10h.01M11 12h.01",
  arrowLeft: "M12.5 8h-9M7 3.5L2.5 8 7 12.5",
  // 回形针。取自 Feather 的 paperclip，按 24 → 16 的 viewBox 等比缩放
  // （系数 2/3），这样描边宽度和其余图标在视觉上一致。
  paperclip:
    "M14.29 7.37l-6.13 6.13a4 4 0 0 1-5.66-5.66l6.13-6.13a2.67 2.67 0 0 1 3.77 3.77l-6.13 6.13a1.33 1.33 0 0 1-1.89-1.89l5.66-5.65",
};

export default class TicketingSystemIcon extends Component {
  get path() {
    return PATHS[this.args.name] ?? PATHS.ticket;
  }

  get size() {
    return this.args.size ?? 16;
  }

  // 大尺寸时用细一点的线，否则图标会显得笨重。
  get strokeWidth() {
    if (this.args.stroke) {
      return this.args.stroke;
    }
    return this.size >= 24 ? 1.2 : 1.5;
  }

  <template>
    <svg
      class="ts-icon"
      width={{this.size}}
      height={{this.size}}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width={{this.strokeWidth}}
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d={{this.path}} />
    </svg>
  </template>
}
