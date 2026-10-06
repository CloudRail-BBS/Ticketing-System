import Service from "@ember/service";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { api, serverErrorMessage } from "../lib/ticketing-system";

// 每个会话只需要取一次的元数据：部门列表、状态/优先级词表、当前用户的能力与未读计数。
//
// 为什么用 service 而不是塞进父路由的 model：
//
//   父路由的 model 只会取一次，子路由读 `this.modelFor("ticketing-system")`
//   也能拿到——但这样一来，任何需要「写完一张工单之后刷新未读数」的地方，
//   都得先拿到父路由实例再调 `refresh()`，而组件里通常只有 controller。
//   放进 service 之后，任何组件都可以 `@service("ticketing-system")` 注入，
//   读同一个 `meta`，需要时调 `reload()`。
//
// 词表由服务端翻译好再下发（见 MetaController#vocabulary），所以前端不硬编码
// 「open / in_progress / …」这些名字：新增一个状态是服务端一处改动，而不是
// 前端再加一层两语言映射。
export default class TicketingSystemService extends Service {
  @service siteSettings;
  @service currentUser;

  @tracked meta = null;
  @tracked loadError = null;

  // 并发去重。父路由和某个组件同时要求加载时，只发一个请求。
  // 用普通字段而不是 @tracked：它是实现细节，不该触发重渲染。
  _pending = null;

  // 一份**不需要请求**的快照。
  //
  // plugin.rb 里 `add_to_serializer(:current_user, :ticketing_system)` 把能力、
  // 未读计数和上限挂在当前用户序列化器上，于是每个页面加载都会带着它下来。
  // 侧边栏的未读徽标因此可以在用户从未打开过 /tickets 时就是对的。
  //
  // 用 `?.` 而不是断言：`add_to_serializer` 生成的 `include_ticketing_system?`
  // 守卫在插件停用时返回 false，此时这个键是**不存在**而不是空对象；而且客户端
  // 模型是否接收未声明字段取决于模型实现，所以这里必须容忍 undefined。
  get bootstrap() {
    return this.currentUser?.ticketing_system ?? null;
  }

  get loaded() {
    return this.meta !== null;
  }

  // 优先用 `/meta` 的答案（写完一张工单之后它更新，未读计数因此是准的），
  // 拿不到时回退到序列化器那份。
  get capabilities() {
    return this.meta?.capabilities ?? this.bootstrap ?? {};
  }

  // 注意 `enabled` 的语义：`Permissions.client_payload` 在插件关闭时整体返回 nil，
  // 于是 `capabilities` 是 {}，`enabled` 落到 false——这正是我们想要的解读。
  get enabled() {
    return this.capabilities.enabled === true;
  }

  get isStaff() {
    return this.capabilities.staff === true;
  }

  get isAdmin() {
    return this.capabilities.admin === true;
  }

  get canAssign() {
    return this.capabilities.can_assign === true;
  }

  get canWriteInternalNote() {
    return this.capabilities.can_write_internal_note === true;
  }

  get canManageDepartments() {
    return this.capabilities.can_manage_departments === true;
  }

  get departments() {
    return this.meta?.departments ?? [];
  }

  // 只包含已启用的部门——工单列表的筛选器不该列出一个已经停用的部门。
  // 管理页需要完整列表，走自己的接口（/tickets/api/departments）。
  get enabledDepartments() {
    return this.departments.filter((department) => department.enabled !== false);
  }

  get statuses() {
    return this.meta?.statuses ?? [];
  }

  get priorities() {
    return this.meta?.priorities ?? [];
  }

  get scopes() {
    return this.meta?.scopes ?? ["mine"];
  }

  get limits() {
    return this.capabilities.limits ?? {};
  }

  get defaults() {
    return this.capabilities.defaults ?? {};
  }

  get unread() {
    return (
      this.meta?.unread ??
      this.bootstrap?.unread ?? { requester: 0, staff: 0, total: 0 }
    );
  }

  get unreadTotal() {
    return this.unread.total ?? 0;
  }

  // 未读徽标的显示条件：开关打开、确有未读、且当前用户登录。
  get showUnreadBadge() {
    return (
      this.siteSettings?.ticketing_system_unread_badge === true &&
      this.unreadTotal > 0
    );
  }

  get defaultPriority() {
    return this.defaults.priority ?? "normal";
  }

  get titleMinLength() {
    return this.limits.title_min_length ?? 4;
  }

  get titleMaxLength() {
    return this.limits.title_max_length ?? 120;
  }

  get bodyMaxLength() {
    return this.limits.body_max_length ?? 20000;
  }

  // 单条消息的附件上限。0 表示附件功能被关掉（`ticketing_system_max_attachments`
  // 设成 0），此时附件选择器整个不渲染 —— 服务端也会拒绝带 upload_ids 的请求，
  // 但让用户看到一个注定失败的控件比不显示它更糟。
  get maxAttachments() {
    return this.limits.max_attachments ?? 0;
  }

  get attachmentsEnabled() {
    return this.maxAttachments > 0;
  }

  // 论坛允许的扩展名（已由服务端归一化：小写、去掉点、去重）。
  // 空数组表示「不限制」。注意这只是给 picker 用的提示：真正的白名单在
  // Attachments.validate! 里，客户端改不了它。
  get allowedUploadExtensions() {
    return this.limits.allowed_upload_extensions ?? [];
  }

  load() {
    if (!this._pending) {
      this._pending = this.#fetch();
    }
    return this._pending;
  }

  // 写操作之后调用：未读计数、部门列表都可能已经变了。
  reload() {
    this._pending = null;
    return this.load();
  }

  async #fetch() {
    try {
      this.meta = await ajax(api("meta"));
      this.loadError = null;
    } catch (error) {
      // 不抛出。父路由的 model 如果 reject，Ember 会切到 error 子状态，
      // 而这里更希望页面照常渲染、由各组件各自展示「加载失败」——
      // 一张工单打不开不该让整个 /tickets 变成错误页。
      this.meta = null;
      this.loadError = serverErrorMessage(error);
    }
    return this.meta;
  }
}
