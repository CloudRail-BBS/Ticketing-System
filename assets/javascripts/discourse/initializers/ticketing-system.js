import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

import { buildNotificationDirector } from "../lib/notification-type";
import { pagePath } from "../lib/ticketing-system";

// 通知类型名必须与服务端 `Notification.types` 的键名一致（plugin.rb 里注册的
// `:ticketing_system` → 5000）。核心用 `site.notificationLookup[notification_type]`
// 反查名字，再用这个名字找渲染器 —— 拼错的表现是通知条目回落到基类，
// 渲染出裸用户名和原始键名，而控制台一片干净。
const NOTIFICATION_TYPE = "ticketing_system";

// 侧边栏链接的 name 必须 dasherized + lowercase（核心在 JSDoc 里写明了这一点）。
const SIDEBAR_LINK_NAME = "ticketing-system-nav-link";
const NAV_ITEM_NAME = "ticketing-system";

export default {
  name: "ticketing-system",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    const currentUser = container.lookup("service:current-user");

    withPluginApi((api) => {
      // 通知渲染器**无条件**注册。
      //
      // 它不依赖当前用户：注册表是全局的，而 `initialize` 里的 currentUser 只是
      // 「页面加载那一刻是否登录」。把它塞进 `if (currentUser)` 会让注册与否取决于
      // 初始化的顺序，而不是取决于事实 —— 而漏注册的后果（通知渲染成裸用户名）
      // 没有任何日志。
      api.registerNotificationTypeRenderer(
        NOTIFICATION_TYPE,
        buildNotificationDirector,
      );

      // 导航入口需要三个条件同时成立：
      //
      //   1. 插件启用。关掉之后 /tickets/api/* 一律被
      //      `ensure_ticketing_system_enabled` 挡成 404，链接点进去是一页错误。
      //   2. 有登录用户。每个工单页面都要求登录，给访客一个只能跳登录页的链接
      //      比不给更糟。
      //   3. 开关打开（`ticketing_system_show_nav_link`）。
      if (!siteSettings?.ticketing_system_enabled) {
        return;
      }
      if (!currentUser) {
        return;
      }
      if (!siteSettings.ticketing_system_show_nav_link) {
        return;
      }

      addSidebarLink(api);
      addNavBarItem(api);
    });
  },
};

// 侧边栏 Community 区块里的链接。
//
// 只用**对象形式**，不用工厂函数形式。
//
// 工厂形式（`(Base) => class extends Base {}`）能拿到 `BaseCommunitySectionLink`，
// 那上面有一个 `badgeText` getter 可以覆写 —— 也就是侧边栏未读徽标的唯一入口。
// 这里不用它，是因为未读徽标已经放在工单列表页的标题上了（见 ticket-list.gjs）：
// 徽标放两处会让「未读」变成两个可能互相矛盾的数字，而侧边栏那份还要额外处理
// `topicTrackingState` 的刷新时机。
//
// 对象形式支持的字段是逐字核实过的（frontend/discourse/app/lib/sidebar/
// custom-community-section-links.js）：name / text / route / href / title / icon /
// models。其中 `icon` 会被当成 `prefixValue`。
//
// 但**光传对名字不够**，这一点踩过坑：`ticket` 在 FontAwesome 源文件里存在
// （vendor/assets/svg-icons/fontawesome/solid.svg 有 id="ticket"），而 Discourse
// 下发的是子集 —— 只打包 `SvgSprite.all_icons`（= `SvgSprite::SVG_ICONS` + 站点
// 设置 / 主题 / 插件贡献）里的图标，`ticket` 不在其中。所以 plugin.rb 里必须有一行
// `register_svg_icon "ticket"`；少了它，链接会正常出现、文字正常、图标是空的，
// 控制台也**不会**报任何错。solid 图标不带前缀，regular 才需要 far-。
function addSidebarLink(api) {
  api.addCommunitySectionLink({
    name: SIDEBAR_LINK_NAME,
    text: i18n("ticketing_system.nav_label"),
    title: i18n("ticketing_system.nav_label"),
    route: "ticketing-system.index",
    icon: "ticket",
  });
}

// 分类导航栏（/discovery 顶部那一条）里的链接。
//
// 两处细节：
//
//   1. `displayName` 是**字面字符串**，核心不翻译它（navigation-item.gjs 直接
//      渲染 `{{this.content.displayName}}`），所以这里必须自己调 i18n。
//   2. `href` 会被核心再过一次 `getURL()`（models/nav-item.js：
//      `item.href = getURL(item.href)`）。`getURL` 是幂等的 —— 它先用
//      `baseUriMatcher` 判断是否已经带前缀，带了就原样返回 —— 所以传
//      `pagePath("")` 在子目录安装（/forum）下不会变成 /forum/forum/tickets。
//      传 `pagePath("")` 而不是裸的 "/tickets"，是为了让路径的唯一来源留在
//      lib/ticketing-system.js 里。
//
// `before: "top"` 让它在「最新/热门」那一排里排在 top 之前。目标不存在时核心会
// 直接追加到末尾（nav-item.js 的循环走完 i === items.length 再 splice），
// 不是静默丢弃。
function addNavBarItem(api) {
  api.addNavigationBarItem({
    name: NAV_ITEM_NAME,
    displayName: i18n("ticketing_system.nav_label"),
    href: pagePath(""),
    before: "top",
  });
}
