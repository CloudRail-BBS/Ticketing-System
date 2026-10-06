import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import {
  api,
  compact,
  formatTimestamp,
  pagePath,
  serverErrorMessage,
  ticketPath,
  userPath,
} from "../../lib/ticketing-system";
import TicketingSystemIcon from "./icon";
import TicketingSystemPill from "./pill";

// 哪些筛选条件会进 URL 与请求。白名单，不是「遍历 filters 的键」——
// 少一个键的表现是「筛选点了没反应」，多一个键的表现是把无关参数发给服务端。
const FILTER_KEYS = [
  "scope",
  "status",
  "priority",
  "department",
  "sort",
  "q",
  "unread",
  "page",
];

const SEARCH_DEBOUNCE_MS = 300;

// 初始筛选条件从 URL 里读。
//
// 刻意**不使用 Ember 的 query params**。query params 要求路由声明
// `queryParams = {…}`、控制器声明同名数组，并且依赖控制器属性在
// `controller.set()` 之后能触发自动追踪——这几件事里任何一件对不上，表现都是
// 「地址栏变了但列表不刷新」或者「列表刷了但下拉框不动」，而且不会报错。
//
// 这里用最朴素的办法：组件自己持有筛选状态、自己发请求，同时用
// `history.replaceState` 把地址栏同步过去。分享链接、刷新保持筛选都能用，
// 但不依赖任何框架级的隐式契约。
function readFiltersFromUrl() {
  const filters = { page: 1, q: "", unread: false };
  if (typeof window === "undefined") {
    return filters;
  }

  const params = new URLSearchParams(window.location.search);
  FILTER_KEYS.forEach((key) => {
    const value = params.get(key);
    if (value === null || value === "") {
      return;
    }
    if (key === "unread") {
      filters.unread = value === "true" || value === "1";
      return;
    }
    if (key === "page") {
      const page = Number.parseInt(value, 10);
      filters.page = Number.isFinite(page) && page > 0 ? page : 1;
      return;
    }
    filters[key] = value;
  });

  return filters;
}

export default class TicketingSystemTicketList extends Component {
  @service("ticketing-system") ticketingSystem;
  @service currentUser;

  @tracked filters = readFiltersFromUrl();
  @tracked payload = null;
  @tracked loading = true;
  @tracked error = null;

  // 搜索框自己的状态。用独立字段而不是直接绑 filters.q：
  // 输入框必须是「受控」的（每次按键都从事件里回写），否则防抖一触发就会
  // 重设 value 并把光标弹到末尾。
  @tracked searchText = "";

  _searchTimer = null;

  constructor() {
    super(...arguments);
    // 组件构造时 args 已可用，但这里刻意什么都不读——只发一个请求。
    // 在构造器里读 `this.args.model` 之类的载荷是「白屏」的经典成因：
    // 组件先于模型被构造，读到 undefined 然后抛错，而错误会被 Ember 吞掉。
    this.searchText = this.filters.q ?? "";
    this.fetch();
  }

  willDestroy() {
    // 不调用 super：@glimmer/component 的 willDestroy 是空实现，而
    // `super.willDestroy?.()` 这种写法在某些转译配置下会被判为语法错误。
    clearTimeout(this._searchTimer);
  }

  get tickets() {
    return this.payload?.tickets ?? [];
  }

  get pageInfo() {
    return this.payload?.page ?? null;
  }

  get isStaff() {
    return this.ticketingSystem.isStaff;
  }

  // 未读总数。优先用服务端的元数据（写操作后会被 reload 刷新），
  // 回退到 current_user 序列化器带下来的那份 —— 后者每个页面加载都有，
  // 所以这个数字在用户还没进过 /tickets 时也是对的。
  get unreadTotal() {
    return this.ticketingSystem.unreadTotal;
  }

  get showUnreadBadge() {
    return this.ticketingSystem.showUnreadBadge;
  }

  get canOpenTicket() {
    return this.ticketingSystem.enabled && Boolean(this.currentUser);
  }

  get newTicketPath() {
    return pagePath("/new");
  }

  // 服务端在响应里回报它**实际**采用的 scope / sort（TicketQuery::Result）。
  // 界面上显示这个值，而不是显示「用户以为的值」：一个员工清掉 scope 之后，
  // 下拉框显示「全部工单」，而列表里确实是全部工单——两边不会互相说谎。
  get effectiveScope() {
    return this.filters.scope ?? this.pageInfo?.scope ?? "";
  }

  get effectiveSort() {
    return this.filters.sort ?? this.pageInfo?.sort ?? "recent";
  }

  get hasActiveFilters() {
    return Boolean(
      this.filters.scope ||
        this.filters.status ||
        this.filters.priority ||
        this.filters.department ||
        this.filters.sort ||
        this.filters.q ||
        this.filters.unread,
    );
  }

  get emptyKey() {
    if (this.hasActiveFilters) {
      return "ticketing_system.empty.filtered";
    }
    return this.isStaff
      ? "ticketing_system.empty.all"
      : "ticketing_system.empty.mine";
  }

  get prevDisabled() {
    return !((this.pageInfo?.page ?? 1) > 1);
  }

  get nextDisabled() {
    return !((this.pageInfo?.page ?? 1) < (this.pageInfo?.pages ?? 1));
  }

  get pageLabel() {
    if (!this.pageInfo || (this.pageInfo.pages ?? 1) <= 1) {
      return null;
    }
    return i18n("ticketing_system.list.page_info", {
      page: this.pageInfo.page,
      pages: this.pageInfo.pages,
    });
  }

  // ---- 下拉框选项 -------------------------------------------------------
  //
  // 每个选项预先算好 `selected`。模板里因此不需要 `(eq …)`，也就不用把
  // truth-helpers 拉进来——那个 import 路径一旦解析不了，整个 bundle 会变成
  // 一行 throw，而不是少一个下拉项。

  get scopeOptions() {
    const current = this.effectiveScope;
    const options = this.ticketingSystem.scopes.map((scope) => ({
      value: scope,
      label: i18n(`ticketing_system.scopes.${scope}`),
      selected: scope === current,
    }));

    if (options.length === 0) {
      return options;
    }

    return [
      {
        value: "",
        label: i18n("ticketing_system.filters.all"),
        selected: current === "",
      },
      ...options,
    ];
  }

  get statusOptions() {
    const current = this.filters.status ?? "";
    return [
      {
        value: "",
        label: i18n("ticketing_system.filters.all"),
        selected: current === "",
      },
      ...this.ticketingSystem.statuses.map((status) => ({
        value: status.id,
        label: status.label,
        selected: status.id === current,
      })),
    ];
  }

  get priorityOptions() {
    const current = this.filters.priority ?? "";
    return [
      {
        value: "",
        label: i18n("ticketing_system.filters.all"),
        selected: current === "",
      },
      ...this.ticketingSystem.priorities.map((priority) => ({
        value: priority.id,
        label: priority.label,
        selected: priority.id === current,
      })),
    ];
  }

  get departmentOptions() {
    const current = this.filters.department ?? "";
    return [
      {
        value: "",
        label: i18n("ticketing_system.filters.any"),
        selected: current === "",
      },
      ...this.ticketingSystem.enabledDepartments.map((department) => ({
        value: String(department.id),
        label: department.name,
        selected: String(department.id) === current,
      })),
    ];
  }

  get sortOptions() {
    const current = this.effectiveSort;
    return ["recent", "oldest", "priority", "created"].map((sort) => ({
      value: sort,
      label: i18n(`ticketing_system.sorts.${sort}`),
      selected: sort === current,
    }));
  }

  // ---- 行 ---------------------------------------------------------------

  // 派生字段一律在这里算完。模板里因此只做取值与 {{#if}}，
  // 不需要任何辅助函数——少一类「未导入的辅助函数把整包干掉」的风险。
  get rows() {
    return this.tickets.map((ticket) => {
      const requester = ticket.requester;
      const assignee = ticket.assignee;
      const department = ticket.department;

      return {
        id: ticket.id,
        href: ticketPath(ticket.id),
        number: ticket.display_number,
        title: ticket.title,
        excerpt: ticket.excerpt,
        unread: ticket.unread === true,
        rowClass: ticket.unread ? "ts-table__row is-unread" : "ts-table__row",
        status: ticket.status,
        statusLabel: ticket.status_label,
        priority: ticket.priority,
        priorityLabel: ticket.priority_label,
        requesterLabel: requester ? requester.name || requester.username : "",
        requesterHref: requester ? userPath(requester.username) : null,
        assigneeLabel: assignee ? assignee.name || assignee.username : null,
        assigneeHref: assignee ? userPath(assignee.username) : null,
        departmentLabel: department ? department.name : null,
        activityLabel: formatTimestamp(ticket.last_activity_at),
      };
    });
  }

  // ---- 数据 -------------------------------------------------------------

  async fetch() {
    if (!this.currentUser) {
      this.loading = false;
      this.error = i18n("ticketing_system.errors.sign_in");
      return;
    }

    this.loading = true;

    try {
      const payload = await ajax(api("tickets"), {
        data: compact(this.#requestParams()),
      });
      this.payload = payload;
      this.error = null;
    } catch (rawError) {
      this.payload = null;
      this.error =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.errors.load_failed");
    } finally {
      this.loading = false;
    }
  }

  #requestParams() {
    return {
      scope: this.filters.scope,
      status: this.filters.status,
      priority: this.filters.priority,
      department: this.filters.department,
      sort: this.filters.sort,
      q: this.filters.q,
      unread: this.filters.unread ? "true" : null,
      page: this.filters.page > 1 ? this.filters.page : null,
    };
  }

  #applyFilters(patch) {
    this.filters = { ...this.filters, ...patch };
    this.#syncUrl();
    this.fetch();
  }

  // 地址栏同步。整段包在 try 里：某些嵌入场景（跨域 iframe、file:// 预览）下
  // replaceState 会抛 SecurityError，而「地址栏没跟上」绝不该让列表加载失败。
  #syncUrl() {
    if (typeof window === "undefined") {
      return;
    }

    try {
      const params = new URLSearchParams();
      Object.entries(compact(this.#requestParams())).forEach(([key, value]) => {
        params.set(key, value);
      });
      const search = params.toString();
      const url = `${window.location.pathname}${search ? `?${search}` : ""}`;
      window.history.replaceState(window.history.state, "", url);
    } catch {
      // 忽略：URL 只是便利功能，不是数据通路。
    }
  }

  // ---- 交互 -------------------------------------------------------------

  @action
  refresh() {
    this.ticketingSystem.reload();
    return this.fetch();
  }

  @action
  onScopeChange(event) {
    this.#applyFilters({ scope: event.target.value, page: 1 });
  }

  @action
  onStatusChange(event) {
    this.#applyFilters({ status: event.target.value, page: 1 });
  }

  @action
  onPriorityChange(event) {
    this.#applyFilters({ priority: event.target.value, page: 1 });
  }

  @action
  onDepartmentChange(event) {
    this.#applyFilters({ department: event.target.value, page: 1 });
  }

  @action
  onSortChange(event) {
    this.#applyFilters({ sort: event.target.value, page: 1 });
  }

  @action
  onUnreadToggle(event) {
    this.#applyFilters({ unread: event.target.checked, page: 1 });
  }

  @action
  onSearchInput(event) {
    const value = event.target.value;
    this.searchText = value;
    clearTimeout(this._searchTimer);
    this._searchTimer = setTimeout(() => {
      this.#applyFilters({ q: value.trim(), page: 1 });
    }, SEARCH_DEBOUNCE_MS);
  }

  @action
  clearFilters() {
    this.searchText = "";
    clearTimeout(this._searchTimer);
    this.#applyFilters({
      scope: "",
      status: "",
      priority: "",
      department: "",
      sort: "",
      q: "",
      unread: false,
      page: 1,
    });
  }

  @action
  prevPage() {
    if (this.prevDisabled) {
      return;
    }
    this.#applyFilters({ page: (this.pageInfo?.page ?? 1) - 1 });
  }

  @action
  nextPage() {
    if (this.nextDisabled) {
      return;
    }
    this.#applyFilters({ page: (this.pageInfo?.page ?? 1) + 1 });
  }

  <template>
    <div class="ts-page">
      <header class="ts-page__header">
        <div class="ts-page__intro">
          <h1 class="ts-page__title">
            {{i18n "ticketing_system.heading"}}
            {{#if this.showUnreadBadge}}
              <span
                class="ts-count-badge"
                title={{i18n "ticketing_system.ticket.unread"}}
              >{{this.unreadTotal}}</span>
            {{/if}}
          </h1>
          <p class="ts-page__subtitle">{{i18n "ticketing_system.description"}}</p>
        </div>

        <div class="ts-page__actions">
          <button
            type="button"
            class="btn btn-default"
            title={{i18n "ticketing_system.actions.refresh"}}
            {{on "click" this.refresh}}
          >
            <TicketingSystemIcon @name="refresh" />
            <span class="ts-btn-text">{{i18n "ticketing_system.actions.refresh"}}</span>
          </button>

          {{#if this.canOpenTicket}}
            <a class="btn btn-primary" href={{this.newTicketPath}}>
              <TicketingSystemIcon @name="plus" />
              <span class="ts-btn-text">{{i18n "ticketing_system.new.submit"}}</span>
            </a>
          {{/if}}
        </div>
      </header>

      <div class="ts-toolbar">
        <label class="ts-field">
          <span class="ts-field__label">{{i18n "ticketing_system.filters.scope"}}</span>
          <select class="ts-select" {{on "change" this.onScopeChange}}>
            {{#each this.scopeOptions as |option|}}
              <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
            {{/each}}
          </select>
        </label>

        <label class="ts-field">
          <span class="ts-field__label">{{i18n "ticketing_system.filters.status"}}</span>
          <select class="ts-select" {{on "change" this.onStatusChange}}>
            {{#each this.statusOptions as |option|}}
              <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
            {{/each}}
          </select>
        </label>

        <label class="ts-field">
          <span class="ts-field__label">{{i18n "ticketing_system.filters.priority"}}</span>
          <select class="ts-select" {{on "change" this.onPriorityChange}}>
            {{#each this.priorityOptions as |option|}}
              <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
            {{/each}}
          </select>
        </label>

        {{#if this.ticketingSystem.enabledDepartments.length}}
          <label class="ts-field">
            <span class="ts-field__label">{{i18n "ticketing_system.filters.department"}}</span>
            <select class="ts-select" {{on "change" this.onDepartmentChange}}>
              {{#each this.departmentOptions as |option|}}
                <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
              {{/each}}
            </select>
          </label>
        {{/if}}

        <label class="ts-field">
          <span class="ts-field__label">{{i18n "ticketing_system.filters.sort"}}</span>
          <select class="ts-select" {{on "change" this.onSortChange}}>
            {{#each this.sortOptions as |option|}}
              <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
            {{/each}}
          </select>
        </label>

        <label class="ts-field ts-field--grow">
          <span class="ts-field__label">{{i18n "ticketing_system.filters.search"}}</span>
          <span class="ts-input-wrap">
            <TicketingSystemIcon @name="search" @size="14" />
            <input
              type="search"
              class="ts-input"
              value={{this.searchText}}
              placeholder={{i18n "ticketing_system.filters.search_placeholder"}}
              {{on "input" this.onSearchInput}}
            />
          </span>
        </label>

        <label class="ts-checkbox">
          <input
            type="checkbox"
            checked={{this.filters.unread}}
            {{on "change" this.onUnreadToggle}}
          />
          <span>{{i18n "ticketing_system.filters.unread_only"}}</span>
        </label>

        {{#if this.hasActiveFilters}}
          <button
            type="button"
            class="btn btn-default btn-small ts-toolbar__clear"
            {{on "click" this.clearFilters}}
          >
            {{i18n "ticketing_system.filters.clear"}}
          </button>
        {{/if}}
      </div>

      {{#if this.loading}}
        <div class="ts-state">
          <TicketingSystemIcon @name="clock" @size="24" />
          <p>{{i18n "ticketing_system.loading"}}</p>
        </div>
      {{else if this.error}}
        <div class="ts-state is-error">
          <TicketingSystemIcon @name="alert" @size="24" />
          <p>{{this.error}}</p>
          <button type="button" class="btn btn-default" {{on "click" this.refresh}}>
            {{i18n "ticketing_system.actions.retry"}}
          </button>
        </div>
      {{else if this.rows.length}}
        <div class="ts-table-wrap">
          <table class="ts-table">
            <thead>
              <tr>
                <th class="ts-table__col-ticket">{{i18n "ticketing_system.columns.ticket"}}</th>
                <th class="ts-table__col-requester">{{i18n "ticketing_system.columns.requester"}}</th>
                <th class="ts-table__col-assignee">{{i18n "ticketing_system.columns.assignee"}}</th>
                <th class="ts-table__col-department">{{i18n "ticketing_system.columns.department"}}</th>
                <th class="ts-table__col-status">{{i18n "ticketing_system.columns.status"}}</th>
                <th class="ts-table__col-priority">{{i18n "ticketing_system.columns.priority"}}</th>
                <th class="ts-table__col-activity">{{i18n "ticketing_system.columns.activity"}}</th>
              </tr>
            </thead>
            <tbody>
              {{#each this.rows as |row|}}
                <tr class={{row.rowClass}}>
                  <td class="ts-table__col-ticket">
                    <a class="ts-ticket-link" href={{row.href}}>
                      <span class="ts-ticket-link__number">{{row.number}}</span>
                      <span class="ts-ticket-link__title">{{row.title}}</span>
                      {{#if row.unread}}
                        <span
                          class="ts-unread-dot"
                          title={{i18n "ticketing_system.ticket.unread"}}
                        ></span>
                      {{/if}}
                    </a>
                    {{#if row.excerpt}}
                      <p class="ts-ticket-link__excerpt">{{row.excerpt}}</p>
                    {{/if}}
                  </td>
                  <td class="ts-table__col-requester">
                    {{#if row.requesterHref}}
                      <a href={{row.requesterHref}}>{{row.requesterLabel}}</a>
                    {{else}}
                      {{row.requesterLabel}}
                    {{/if}}
                  </td>
                  <td class="ts-table__col-assignee">
                    {{#if row.assigneeHref}}
                      <a href={{row.assigneeHref}}>{{row.assigneeLabel}}</a>
                    {{else}}
                      <span class="ts-muted">{{i18n "ticketing_system.ticket.unassigned"}}</span>
                    {{/if}}
                  </td>
                  <td class="ts-table__col-department">
                    {{#if row.departmentLabel}}
                      {{row.departmentLabel}}
                    {{else}}
                      <span class="ts-muted">{{i18n "ticketing_system.ticket.no_department"}}</span>
                    {{/if}}
                  </td>
                  <td class="ts-table__col-status">
                    <TicketingSystemPill
                      @kind="status"
                      @value={{row.status}}
                      @label={{row.statusLabel}}
                    />
                  </td>
                  <td class="ts-table__col-priority">
                    <TicketingSystemPill
                      @kind="priority"
                      @value={{row.priority}}
                      @label={{row.priorityLabel}}
                    />
                  </td>
                  <td class="ts-table__col-activity">{{row.activityLabel}}</td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>

        {{#if this.pageLabel}}
          <nav class="ts-pagination">
            <button
              type="button"
              class="btn btn-default btn-small"
              disabled={{this.prevDisabled}}
              {{on "click" this.prevPage}}
            >
              {{i18n "ticketing_system.list.prev"}}
            </button>
            <span class="ts-pagination__label">{{this.pageLabel}}</span>
            <button
              type="button"
              class="btn btn-default btn-small"
              disabled={{this.nextDisabled}}
              {{on "click" this.nextPage}}
            >
              {{i18n "ticketing_system.list.next"}}
            </button>
          </nav>
        {{/if}}
      {{else}}
        <div class="ts-state">
          <TicketingSystemIcon @name="inbox" @size="24" />
          <p>{{i18n this.emptyKey}}</p>
          <p class="ts-state__hint">{{i18n "ticketing_system.empty.hint"}}</p>
        </div>
      {{/if}}
    </div>
  </template>
}
