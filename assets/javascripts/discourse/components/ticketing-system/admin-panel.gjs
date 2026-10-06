import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";

import TicketingSystemAdminOverview from "./admin-overview";
import TicketingSystemDepartmentManager from "./department-manager";
import TicketingSystemIcon from "./icon";

// 标签页的 id 同时是 i18n 键后缀（`admin.tab_overview` / `admin.tab_departments`）。
// 白名单而不是从数组推导：多一个 id 的表现是页面上多一个空标签，
// 少一个的表现是一个标签永远选不中。
const TABS = ["overview", "departments"];

export default class TicketingSystemAdminPanel extends Component {
  @service("ticketing-system") ticketingSystem;

  @tracked tab = "overview";

  get tabs() {
    return TABS.map((id) => ({
      id,
      label: i18n(`ticketing_system.admin.tab_${id}`),
      tabClass: id === this.tab ? "ts-tab is-active" : "ts-tab",
    }));
  }

  get showDepartments() {
    return this.tab === "departments";
  }

  // 关闭时页面照常渲染，只是加一条说明。
  //
  // 为什么不做成「整个页面替换成停用提示」：管理员来这里通常正是为了看一眼
  // 队列是不是空的、部门还在不在，然后再去设置里打开开关。把数据藏起来会让他
  // 多跑一趟。而 /tickets/api/* 全部会被 `ensure_ticketing_system_enabled` 拒绝，
  // 所以下面两个组件会各自显示自己的错误态 —— 这里只负责把原因讲清楚。
  get enabled() {
    return this.ticketingSystem.enabled;
  }

  get disabled() {
    return !this.enabled;
  }

  @action
  selectTab(event) {
    this.tab = event.target.dataset.tab;
  }

  <template>
    <div class="ts-admin">
      <header class="ts-page__header">
        <div class="ts-page__intro">
          <h1 class="ts-page__title">{{i18n "ticketing_system.admin.title"}}</h1>
          <p class="ts-page__subtitle">{{i18n "ticketing_system.admin.description"}}</p>
        </div>
      </header>

      {{#if this.disabled}}
        <div class="ts-state is-error">
          <TicketingSystemIcon @name="alert" @size="24" />
          <p>{{i18n "ticketing_system.admin.disabled_hint"}}</p>
          <p class="ts-state__hint">{{i18n "ticketing_system.admin.settings_hint"}}</p>
        </div>
      {{/if}}

      <nav class="ts-tabs">
        {{#each this.tabs as |tab|}}
          <button
            type="button"
            class={{tab.tabClass}}
            data-tab={{tab.id}}
            {{on "click" this.selectTab}}
          >
            {{tab.label}}
          </button>
        {{/each}}
      </nav>

      {{#if this.showDepartments}}
        <TicketingSystemDepartmentManager />
      {{else}}
        <TicketingSystemAdminOverview />
      {{/if}}
    </div>
  </template>
}
