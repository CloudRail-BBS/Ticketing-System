import Route from "@ember/routing/route";
import { service } from "@ember/service";

// /tickets/admin —— 管理页。
//
// 这个路由只做一件事：把非管理员转回列表。
//
// 为什么不把这个判断放进父路由 `routes/ticketing-system.js`：
// 父路由管着三个**用户侧**页面（列表 / 新建 / 详情），普通用户必须能进。
// 守卫只能挂在需要它的这一层，挂在父路由上会把整棵子树一起锁掉。
//
// 为什么是 admin 而不是 staff：
// 这个页面上的部门 CRUD 走 `DepartmentsController`，其 create / update / destroy
// 都是 `ensure_admin!`。让员工看见一个点下去必然 403 的表单，比看不见更糟 ——
// 用户会以为是自己填错了。总览标签页的数据接口（/tickets/api/stats）确实是
// staff-only 的，但那是服务端刻意的放宽，不是前端应该据此展示整页的理由：
// 一个页面里有一半能点一半不能点，不如整个不展示。
export default class TicketingSystemAdminRoute extends Route {
  @service currentUser;
  @service router;

  beforeModel() {
    if (!this.currentUser?.admin) {
      // 返回这个 Transition 会中止当前跳转。不返回的话，转走之后本路由仍会
      // 渲染一帧 —— 那一帧里管理表单是能点的，而点下去就是 403。
      return this.router.transitionTo("ticketing-system.index");
    }

    return undefined;
  }
}
