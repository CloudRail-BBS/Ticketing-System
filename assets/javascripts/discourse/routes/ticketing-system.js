import Route from "@ember/routing/route";
import { service } from "@ember/service";

// 父路由。它只有一件事要做：在子路由渲染之前把元数据取回来。
//
// 元数据 = 部门列表 + 状态/优先级词表 + 当前用户的能力 + 未读计数（见
// MetaController#show）。三个子页面都依赖它：列表要下拉选项、新建表单要部门与
// 优先级、详情页要把 status/priority 的 id 翻成人话。放在父路由上，一次请求覆盖
// 三个页面，`router.refresh()` 也会重新走这里。
//
// 这个路由**没有** controller，也不需要：所有可变状态都在组件与 service 里。
// Ember 会为它合成一个默认 controller，仅用于承载 model。
export default class TicketingSystemRoute extends Route {
  @service("ticketing-system") ticketingSystem;

  // 注意这里**不会** reject。
  //
  // `TicketingSystemService#load()` 内部把失败收敛成 `loadError` 并 resolve(null)。
  // 这是刻意的：如果 model 抛错，Ember 会切到 error 子状态，而
  // `templates/ticketing-system/error.gjs` 并不存在 —— 结果是整个 /tickets 变成
  // 一页白屏，连「重试」都点不到。让页面照常渲染、由各组件自己展示错误，
  // 用户至少还能刷新或换个筛选条件。
  model() {
    return this.ticketingSystem.load();
  }
}
