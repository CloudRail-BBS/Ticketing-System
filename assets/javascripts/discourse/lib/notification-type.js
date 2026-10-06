import { i18n } from "discourse-i18n";

import { ticketPath } from "./ticketing-system";

// 工单通知的渲染器。
//
// 契约来自核心，且是**逐字核实过的**（frontend/discourse/app/lib/
// notification-types-manager.js 与 lib/user-menu/notification-item.js）：
//
//     api.registerNotificationTypeRenderer("ticketing_system", (Base) => class extends Base {…})
//
// `registerNotificationTypeRenderer` 内部是 `_customClassForType[type] = func(NotificationTypeBase)`，
// 也就是说传进来的 `Base` 就是 `NotificationTypeBase` 本身。之后核心用
// `new klass({ notification, currentUser, siteSettings, site })` 构造它，并从
// 实例上读这些 getter：
//
//     classNames · linkHref · linkTitle · icon · label · labelClasses
//     description · descriptionClasses · topicId · onClick
//
// 基类的默认值对本插件**全部不适用**，这是必须覆写而不是可选覆写的原因：
//
//   linkHref     基类只在有 topic_id 或 group_id 时返回路径。工单通知两者都没有，
//                于是得到 undefined —— 渲染成 <a> 没有 href，条目点了没反应。
//   linkTitle    基类返回 i18n("notifications.titles.ticketing_system")，这个键
//                在核心语言文件里不存在，悬停时显示 [en.notifications.titles.…]。
//   description  基类返回 fancy_title / data.topic_title。工单通知没有主题，
//                两个都是 undefined，于是这一行整段不渲染 —— 通知只剩一个用户名。
//   label        基类读 acting_user_name，那是核心在 `populate_acting_user` 里
//                根据 data 里的 username 填的，能用；但它在
//                `prioritize_full_name_in_ux` 关闭时回退到 `username`，
//                而工单的 username 可能是 nil（系统事件）。这里自己兜底。
//   icon         基类返回 `notification.ticketing_system`，核心图标表里没有这个
//                名字，d-icon 渲染出一个空 svg。这里改用它，但**仅仅改名字是不够的**：
//                见下面的 `ticket` 说明。
//
// 关于 `ticket`：它存在于 FontAwesome 的源文件里
// （vendor/assets/svg-icons/fontawesome/solid.svg 有 id="ticket"），但 Discourse
// 下发的是**子集** —— `SvgSprite.bundle` 只打包 `SvgSprite.all_icons` 里的图标，
// 也就是 `SvgSprite::SVG_ICONS` 加上站点设置 / 主题 / 插件贡献的那些。`ticket`
// 不在 `SVG_ICONS` 里（`plus`、`clock`、`inbox`、`envelope`、`bell`、
// `magnifying-glass` 在，`ticket` 不在）。所以插件必须在 plugin.rb 里显式
// `register_svg_icon "ticket"`，否则这个 getter 返回的名字渲染出来仍然是空 svg ——
// 侧边栏链接只剩文字、通知条目空一块，而且**没有任何日志**，因为「名字不在精灵里」
// 对渲染器来说不是错误，只是不存在。（solid 图标不带前缀，regular 才需要 far-。）
//
// 顺带说明头像：通知条目在 `show_user_menu_avatars` 打开时会渲染发言人的头像，
// 数据来源是 `Notification.populate_acting_user` 读 `data_hash[:username]` ——
// 服务端 `Notifier` 正好写了这个键，所以头像是对的，不需要额外的服务端改动。
// （不要试图给 `Notification.create!` 加 `acting_user_id`：`Notification` 上
// 根本没有这一列，`acting_user` 是个 attr_accessor，加了会抛 UnknownAttributeError，
// 而 Notifier 里的 rescue 会把它吞成「通知没发出去」。）
const EVENT_KEYS = {
  new_ticket: "ticketing_system.notifications.new_ticket",
  requester_reply: "ticketing_system.notifications.requester_reply",
  staff_reply: "ticketing_system.notifications.staff_reply",
  assigned: "ticketing_system.notifications.assigned",
  status_changed: "ticketing_system.notifications.status_changed",
  sla_breached: "ticketing_system.notifications.sla_breached",
  auto_closed: "ticketing_system.notifications.auto_closed",
};

// `sla_breached` 带一个更具体的 `breach`，用它分流到更准确的一句话。
//
// 后两个事件由定时任务写入，没有发言人，条目的 label 是空的 —— 所以它们的文案
// 是**完整句子**而不是短语，见 config/locales/client.*.yml 里的说明。
const SLA_BREACH_KEYS = {
  first_response: "ticketing_system.notifications.sla_breached_first_response",
  resolution: "ticketing_system.notifications.sla_breached_resolution",
};

export function buildNotificationDirector(NotificationTypeBase) {
  return class extends NotificationTypeBase {
    get data() {
      return this.notification.data ?? {};
    }

    // 事件 → 文案键。
    //
    // 未知事件回退到 `undefined`，由 description 兜到工单标题上 —— 服务端加了
    // 事件而这里没跟上时，用户看到的是标题，而不是一个原始键名。
    #phraseKey() {
      const event = this.data.event;

      if (event === "sla_breached") {
        return SLA_BREACH_KEYS[this.data.breach] ?? EVENT_KEYS.sla_breached;
      }

      return EVENT_KEYS[event];
    }

    // 指向工单详情页。`ticketPath` 内部走 `getURL()`，子目录安装（/forum）下
    // 也能正确解析；核心的 `UserMenuBaseItem#onClick` 直接把这个值交给
    // `DiscourseURL.routeTo`，不做二次拼接。
    get linkHref() {
      const id = this.data.ticket_id;
      return id ? ticketPath(id) : null;
    }

    get linkTitle() {
      return this.data.title || i18n("ticketing_system.title");
    }

    // 用户名单独作为 label 渲染，所以下面的事件文案里**不再**包含 %{username} ——
    // 两边都写会得到「alice alice opened a ticket」。
    get label() {
      return this.data.display_username || this.data.username || "";
    }

    get description() {
      const key = this.#phraseKey();
      // `data.event` 只有 Notifier 写进去的那几个取值。出现别的值意味着服务端
      // 加了事件而这里没跟上 —— 退回工单标题，至少不显示一个原始键名。
      const phrase = key
        ? i18n(key, {
            // `status_changed` 带 status；其余事件没有这个占位符，多传无害。
            // 空串而不是 undefined：`isValidNode` 把 "" 视为有效值并替换掉占位符，
            // 而 undefined 会渲染成字面的 "[missing %{status} value]"。
            status: this.data.status
              ? i18n(`ticketing_system.status.${this.data.status}`)
              : "",
          })
        : i18n("ticketing_system.title");

      const number = this.data.ticket_number;
      if (!number) {
        return phrase;
      }

      return `${phrase} · ${i18n("ticketing_system.ticket.number", { number })}`;
    }

    get icon() {
      return "ticket";
    }
  };
}
