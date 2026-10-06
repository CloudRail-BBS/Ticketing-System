import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import { api, serverErrorMessage } from "../../lib/ticketing-system";

// /tickets/:id。
//
// 契约：返回的对象**永远**有两个键 —— `ticket` 与 `error`，二者恰好一个非空。
// `ticket-detail.gjs` 就是按这两个键消费的，它把 `error` 渲染成一条带返回链接的
// 错误态，把 `ticket` 渲染成详情。
//
// 为什么不直接 reject：这个路由是**叶子**，Ember 没有地方接住错误 —— 它会向上
// 冒到 application 路由的 error 子状态，把整个论坛外壳换成核心的 exception 页面。
// 一张工单被删了或不属于当前用户，不该让用户离开论坛。
//
// 顺带一提，这里的 404 / 403 都是**服务端已经翻译过**的话（`render_json_error`
// 出来的 `errors: [...]`），所以优先展示它，只有在拿不到时才回退到本地文案。
export default class TicketingSystemShowRoute extends Route {
  async model(params) {
    try {
      const payload = await ajax(api("tickets", params.id));
      return { ticket: payload.ticket, error: null };
    } catch (rawError) {
      return {
        ticket: null,
        error:
          serverErrorMessage(rawError) ??
          i18n("ticketing_system.errors.detail_failed"),
      };
    }
  }
}
