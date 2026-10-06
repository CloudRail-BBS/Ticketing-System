import Component from "@glimmer/component";
import { priorityClass, slaClass, statusClass } from "../../lib/ticketing-system";

// 状态 / 优先级 / SLA 三个标签共用一个小圆片组件。
//
// 三者的差别只有「颜色后缀怎么算」，所以用一个组件加 `@kind` 分派，而不是三个
// 几乎相同的文件——三份拷贝最终一定会有一份忘了跟着改。
//
// CSS 后缀在 JS 里算好再传给模板，模板里只做一次 `{{this.modifierClass}}`。
// 这样可以完全避开 `(eq a b)` 这类辅助函数：在严格模式模板里未导入的辅助函数
// 是**编译期**错误，会让整个插件 bundle 变成一行 throw。
const BUILDERS = {
  status: statusClass,
  priority: priorityClass,
  sla: slaClass,
};

export default class TicketingSystemPill extends Component {
  get modifierClass() {
    const build = BUILDERS[this.args.kind] ?? statusClass;
    return build(this.args.value);
  }

  get label() {
    return this.args.label ?? this.args.value ?? "";
  }

  <template>
    <span class="ts-pill ts-pill--{{@kind}} {{this.modifierClass}}">
      {{this.label}}
    </span>
  </template>
}
