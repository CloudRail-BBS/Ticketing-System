import Route from "@ember/routing/route";
import { service } from "@ember/service";

// /tickets/new。
//
// 没有 model：表单的全部状态属于组件（`new-ticket-form.gjs`），路由只负责一件事
// —— 把未登录的人挡在外面。
//
// 为什么在路由而不是组件里判断：未登录时 `POST /tickets/api/tickets` 会被
// `TicketCreator#ensure_signed_in!` 以 403 拒绝，用户填完一张表才被告知要登录。
// 在这里提前转走，代价是零。
export default class TicketingSystemNewRoute extends Route {
  @service currentUser;
  @service router;

  beforeModel() {
    if (!this.currentUser) {
      // 返回这个 Transition 会中止当前跳转。不返回的话，转走之后
      // /tickets/new 的模板仍会渲染一帧 —— 那一帧里表单是能点的。
      return this.router.transitionTo("ticketing-system.index");
    }

    return undefined;
  }
}
