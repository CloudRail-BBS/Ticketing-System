// Ember 路由表：插件的自有顶层页面 /tickets。
//
// 为什么导出「函数」而不是「对象」——这是本文件唯一真正的坑。
//
// `frontend/discourse/app/mapping-router.js` 这样处理每个 *-route-map.js：
//
//     if (typeof mapObj === "function") {
//       tree.extract(mapObj);          // this === 路由树根
//     } else {
//       extras.push(mapObj);
//     }
//     // 稍后……
//     extras.forEach((extra) => {
//       let node = tree.findPath(extra.resource);
//       if (node) { node.extract(extra.map); }   // 找不到就静默丢弃
//     });
//
// 对象形式（`{ resource: "x", map() {} }`）是「挂到已有节点上」。而 `tree` 里
// 只有核心 app-route-map.js 建出来的节点：discovery / user / admin / topic …
// 插件自己的路由名永远不在其中，于是 `{ resource: "ticketing-system" }` 会被
// **无声丢弃**：路由不存在，URL 落到兜底的 `unknown`（path: "*path"）→ 404。
// 没有控制台报错、没有构建告警、服务端日志也一片干净。这是插件页面「打不开」
// 最常见的原因。
//
// 函数形式与核心的 app-route-map.js、以及 discourse-cakeday 的 /cakeday 完全一致。
export default function () {
  // 路由名 `ticketing-system`，路径 /tickets。
  //
  // 路径与 Rails 引擎的挂载点（`mount ::TicketingSystem::Engine, at: "/tickets"`）
  // 必须一致：Ember 只处理客户端跳转，而刷新 /tickets/new 是一次真实 HTTP 请求，
  // 由引擎的 pages#index 返回服务端外壳。
  this.route("ticketing-system", { path: "/tickets" }, function () {
    this.route("index", { path: "/" });
    this.route("new");
    // `admin` MUST be declared before `show`.
    //
    // Ember matches routes in declaration order, and `show`'s path is `:id` —
    // a bare segment that happily matches the literal string "admin". Declared
    // the other way round, /tickets/admin resolves to `ticketing-system.show`
    // with `id = "admin"`, which requests /tickets/api/tickets/admin and renders
    // the detail page's error state. There is no error message to explain it:
    // the route matched, the request failed.
    //
    // Ember route paths have no regex constraints, so ordering is the only
    // available mechanism. The Rails side needs the matching `get "/admin"`
    // route for the same reason (see config/routes.rb).
    this.route("admin");
    // Only accepts numeric ids, matching the engine's `get "/:id", constraints:
    // { id: /\d+/ }`. Keeping the two in step means a URL Ember cannot generate
    // can never be mistaken for a page by the server either.
    this.route("show", { path: ":id" });
  });
}
