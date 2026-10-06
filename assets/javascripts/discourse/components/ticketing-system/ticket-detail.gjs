import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import {
  api,
  formatTimestamp,
  pagePath,
  serverErrorMessage,
  slaClass,
  userPath,
} from "../../lib/ticketing-system";
import TicketingSystemComposer from "./composer";
import TicketingSystemIcon from "./icon";
import TicketingSystemPill from "./pill";

// 状态按钮的文案。
//
// 用 `actions.*` 里的动词而不是状态名（「标记为已解决」而不是「已解决」）：
// 按钮是动作，字段是状态，两者用同一套词会让人分不清哪个是可点的。
const STATUS_ACTION_KEYS = {
  open: "ticketing_system.actions.reopen",
  in_progress: "ticketing_system.actions.start",
  pending: "ticketing_system.actions.wait_for_requester",
  resolved: "ticketing_system.actions.resolve",
  closed: "ticketing_system.actions.close",
};

export default class TicketingSystemTicketDetail extends Component {
  @service("ticketing-system") ticketingSystem;
  @service router;

  // 写操作之后服务端会返回整张工单，但路由的 model 还是旧的。
  // 用「按 id 认领」的覆盖值而不是直接拷贝进状态：
  // 组件实例在 5 号工单 → 6 号工单的跳转中是复用的，构造器不会重跑，
  // 一个单纯的 `@tracked ticket = this.args.model.ticket` 会在跳转后过期，
  // 让 6 号工单的页面显示 5 号的内容。
  @tracked updated = null;
  @tracked acting = false;
  @tracked actionError = null;

  get model() {
    return this.args.model ?? {};
  }

  get error() {
    return this.model.error ?? null;
  }

  get ticket() {
    const base = this.model.ticket ?? null;
    if (this.updated && base && this.updated.id === base.id) {
      return this.updated.ticket;
    }
    return base;
  }

  get backPath() {
    return pagePath("");
  }

  get canManage() {
    return this.ticket?.can?.manage === true;
  }

  get canAssign() {
    return this.ticket?.can?.assign === true;
  }

  get canChangePriority() {
    return this.ticket?.can?.change_priority === true;
  }

  get canWriteNote() {
    return this.ticket?.can?.note === true;
  }

  get showActionBar() {
    return (
      this.canManage || this.canAssign || this.canChangePriority ||
      (this.ticket?.can?.statuses ?? []).length > 0
    );
  }

  // ---- 字段 -------------------------------------------------------------

  get metaFields() {
    const ticket = this.ticket;
    if (!ticket) {
      return [];
    }

    const requester = ticket.requester;
    const assignee = ticket.assignee;

    return [
      {
        key: "requester",
        label: i18n("ticketing_system.fields.requester"),
        value: requester ? requester.name || requester.username : "",
        href: requester ? userPath(requester.username) : null,
      },
      {
        key: "assignee",
        label: i18n("ticketing_system.fields.assignee"),
        value: assignee
          ? assignee.name || assignee.username
          : i18n("ticketing_system.ticket.unassigned"),
        href: assignee ? userPath(assignee.username) : null,
      },
      {
        key: "department",
        label: i18n("ticketing_system.fields.department"),
        value: ticket.department
          ? ticket.department.name
          : i18n("ticketing_system.ticket.no_department"),
        href: null,
      },
      {
        key: "created",
        label: i18n("ticketing_system.fields.created"),
        value: formatTimestamp(ticket.created_at),
        href: null,
      },
      {
        key: "last_activity",
        label: i18n("ticketing_system.fields.last_activity"),
        value: formatTimestamp(ticket.last_activity_at),
        href: null,
      },
    ];
  }

  get slaBlocks() {
    const sla = this.ticket?.sla;
    if (!sla) {
      return [];
    }

    return [
      {
        key: "first_response",
        label: i18n("ticketing_system.detail.first_response"),
        stateClass: slaClass(sla.first_response_state),
        stateLabel: i18n(
          `ticketing_system.detail.sla.${sla.first_response_state}`,
        ),
        dueLabel: i18n("ticketing_system.detail.due_at", {
          time: formatTimestamp(sla.first_response_due_at),
        }),
      },
      {
        key: "resolution",
        label: i18n("ticketing_system.detail.resolution"),
        stateClass: slaClass(sla.resolution_state),
        stateLabel: i18n(`ticketing_system.detail.sla.${sla.resolution_state}`),
        dueLabel: i18n("ticketing_system.detail.due_at", {
          time: formatTimestamp(sla.resolution_due_at),
        }),
      },
    ];
  }

  // ---- 对话与时间线 ------------------------------------------------------

  get messages() {
    return (this.ticket?.messages ?? []).map((message) => {
      const author = message.user;

      return {
        id: message.id,
        authorLabel: author ? author.name || author.username : "",
        authorHref: author ? userPath(author.username) : null,
        staff: message.staff === true,
        internal: message.internal === true,
        // `cooked` 由服务端的 PrettyText 生成，渲染时已经做过清洗。
        // 前端把它标记成安全是有依据的——依据就是「它来自服务端且经过消毒」，
        // 而不是「它是我们自己拼的」。
        cooked: htmlSafe(message.cooked ?? ""),
        createdAt: formatTimestamp(message.created_at),
        bubbleClass: message.internal
          ? "ts-message is-internal"
          : message.staff
            ? "ts-message is-staff"
            : "ts-message",
      };
    });
  }

  get events() {
    return (this.ticket?.events ?? []).map((event) => {
      const actor = event.actor;
      const from = this.#vocabularyLabel(event.from_value);
      const to = this.#vocabularyLabel(event.to_value);

      return {
        id: event.id,
        label: event.kind_label,
        actorLabel: actor ? actor.name || actor.username : null,
        changeLabel: from && to ? `${from} → ${to}` : null,
        createdAt: formatTimestamp(event.created_at),
      };
    });
  }

  // ---- 操作栏 -----------------------------------------------------------

  get statusActions() {
    const ticket = this.ticket;
    if (!ticket) {
      return [];
    }

    return (ticket.can?.statuses ?? [])
      .filter((status) => status !== ticket.status)
      .map((status) => ({
        status,
        label: i18n(STATUS_ACTION_KEYS[status] ?? "ticketing_system.actions.reply"),
      }));
  }

  get priorityOptions() {
    const current = this.ticket?.priority;
    return this.ticketingSystem.priorities.map((priority) => ({
      value: priority.id,
      label: priority.label,
      selected: priority.id === current,
    }));
  }

  get departmentOptions() {
    const current = this.ticket?.department_id ?? null;
    return [
      {
        value: "none",
        label: i18n("ticketing_system.ticket.no_department"),
        selected: current === null,
      },
      ...this.ticketingSystem.enabledDepartments.map((department) => ({
        value: String(department.id),
        label: department.name,
        selected: department.id === current,
      })),
    ];
  }

  get assigneeOptions() {
    const current = this.ticket?.assignee?.username ?? "";

    return [
      {
        value: "none",
        label: i18n("ticketing_system.ticket.unassigned"),
        selected: current === "",
      },
      {
        value: "me",
        label: i18n("ticketing_system.actions.assign_to_me"),
        selected: false,
      },
      ...(this.ticket?.assignable_users ?? []).map((user) => ({
        value: user.username,
        label: user.name || user.username,
        selected: user.username === current,
      })),
    ];
  }

  get showAssignToMe() {
    return this.canAssign && !this.ticket?.assignee;
  }

  // ---- 数据 -------------------------------------------------------------

  #vocabularyLabel(value) {
    if (!value) {
      return null;
    }

    const status = this.ticketingSystem.statuses.find(
      (item) => item.id === value,
    );
    if (status) {
      return status.label;
    }

    const priority = this.ticketingSystem.priorities.find(
      (item) => item.id === value,
    );
    if (priority) {
      return priority.label;
    }

    // 指派人与部门存的是用户名 / 部门名，本身就是给人看的。
    return value;
  }

  #setTicket(ticket) {
    this.updated = { id: ticket.id, ticket };
    // 未读计数与部门列表都可能已经变了。
    this.ticketingSystem.reload();
  }

  async #act(operation, data) {
    if (this.acting) {
      return;
    }

    this.acting = true;

    try {
      const payload = await ajax(
        api("tickets", String(this.ticket.id), "actions"),
        {
          type: "POST",
          data: { operation, ...data },
        },
      );
      this.actionError = null;
      this.#setTicket(payload.ticket);
    } catch (rawError) {
      this.actionError =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.errors.action_failed");
    } finally {
      this.acting = false;
    }
  }

  // ---- 交互 -------------------------------------------------------------

  @action
  refresh() {
    this.updated = null;
    this.actionError = null;
    this.ticketingSystem.reload();
    this.router.refresh();
  }

  @action
  onPosted(payload) {
    if (payload?.ticket) {
      this.actionError = null;
      this.#setTicket(payload.ticket);
    }
  }

  @action
  changeStatus(event) {
    return this.#act("status", { status: event.target.dataset.status });
  }

  @action
  changePriority(event) {
    return this.#act("priority", { priority: event.target.value });
  }

  @action
  changeDepartment(event) {
    return this.#act("department", { department: event.target.value });
  }

  @action
  changeAssignee(event) {
    return this.#act("assign", { assignee: event.target.value });
  }

  @action
  assignToMe() {
    return this.#act("assign", { assignee: "me" });
  }

  <template>
    <div class="ts-detail">
      <a class="ts-detail__back" href={{this.backPath}}>
        <TicketingSystemIcon @name="arrowLeft" @size="14" />
        {{i18n "ticketing_system.detail.back"}}
      </a>

      {{#if this.error}}
        <div class="ts-state is-error">
          <TicketingSystemIcon @name="alert" @size="24" />
          <p>{{this.error}}</p>
          <a class="btn btn-default" href={{this.backPath}}>
            {{i18n "ticketing_system.detail.back"}}
          </a>
        </div>
      {{else if this.ticket}}
        <header class="ts-detail__header">
          <div class="ts-detail__heading">
            <span class="ts-detail__number">{{this.ticket.display_number}}</span>
            <h1 class="ts-detail__title">{{this.ticket.title}}</h1>
          </div>

          <div class="ts-detail__badges">
            <TicketingSystemPill
              @kind="status"
              @value={{this.ticket.status}}
              @label={{this.ticket.status_label}}
            />
            <TicketingSystemPill
              @kind="priority"
              @value={{this.ticket.priority}}
              @label={{this.ticket.priority_label}}
            />
            {{#if this.ticket.unread}}
              <span class="ts-unread-dot" title={{i18n "ticketing_system.ticket.unread"}}></span>
            {{/if}}
            <button
              type="button"
              class="btn btn-default btn-small"
              title={{i18n "ticketing_system.actions.refresh"}}
              {{on "click" this.refresh}}
            >
              <TicketingSystemIcon @name="refresh" @size="14" />
            </button>
          </div>
        </header>

        <dl class="ts-meta">
          {{#each this.metaFields as |field|}}
            <div class="ts-meta__item">
              <dt class="ts-meta__label">{{field.label}}</dt>
              <dd class="ts-meta__value">
                {{#if field.href}}
                  <a href={{field.href}}>{{field.value}}</a>
                {{else}}
                  {{field.value}}
                {{/if}}
              </dd>
            </div>
          {{/each}}
        </dl>

        {{#if this.slaBlocks.length}}
          <div class="ts-sla">
            {{#each this.slaBlocks as |block|}}
              <div class="ts-sla__block {{block.stateClass}}">
                <span class="ts-sla__label">{{block.label}}</span>
                <span class="ts-sla__state">{{block.stateLabel}}</span>
                <span class="ts-sla__due">{{block.dueLabel}}</span>
              </div>
            {{/each}}
          </div>
        {{/if}}

        {{#if this.showActionBar}}
          <div class="ts-actions">
            {{#if this.statusActions.length}}
              <div class="ts-actions__group">
                {{#each this.statusActions as |action|}}
                  <button
                    type="button"
                    class="btn btn-default btn-small"
                    data-status={{action.status}}
                    disabled={{this.acting}}
                    {{on "click" this.changeStatus}}
                  >
                    {{action.label}}
                  </button>
                {{/each}}
              </div>
            {{/if}}

            {{#if this.canChangePriority}}
              <label class="ts-field ts-field--inline">
                <span class="ts-field__label">{{i18n "ticketing_system.fields.priority"}}</span>
                <select
                  class="ts-select"
                  disabled={{this.acting}}
                  {{on "change" this.changePriority}}
                >
                  {{#each this.priorityOptions as |option|}}
                    <option value={{option.value}} selected={{option.selected}}>
                      {{option.label}}
                    </option>
                  {{/each}}
                </select>
              </label>
            {{/if}}

            {{#if this.canAssign}}
              <label class="ts-field ts-field--inline">
                <span class="ts-field__label">{{i18n "ticketing_system.fields.assignee"}}</span>
                <select
                  class="ts-select"
                  disabled={{this.acting}}
                  {{on "change" this.changeAssignee}}
                >
                  {{#each this.assigneeOptions as |option|}}
                    <option value={{option.value}} selected={{option.selected}}>
                      {{option.label}}
                    </option>
                  {{/each}}
                </select>
              </label>
            {{/if}}

            {{#if this.showAssignToMe}}
              <button
                type="button"
                class="btn btn-default btn-small"
                disabled={{this.acting}}
                {{on "click" this.assignToMe}}
              >
                {{i18n "ticketing_system.actions.assign_to_me"}}
              </button>
            {{/if}}

            {{#if this.canManage}}
              <label class="ts-field ts-field--inline">
                <span class="ts-field__label">{{i18n "ticketing_system.fields.department"}}</span>
                <select
                  class="ts-select"
                  disabled={{this.acting}}
                  {{on "change" this.changeDepartment}}
                >
                  {{#each this.departmentOptions as |option|}}
                    <option value={{option.value}} selected={{option.selected}}>
                      {{option.label}}
                    </option>
                  {{/each}}
                </select>
              </label>
            {{/if}}
          </div>

          {{#if this.actionError}}
            <p class="ts-actions__error">{{this.actionError}}</p>
          {{/if}}
        {{/if}}

        <section class="ts-section">
          <h2 class="ts-section__title">{{i18n "ticketing_system.detail.conversation"}}</h2>

          {{#if this.messages.length}}
            <div class="ts-thread">
              {{#each this.messages as |message|}}
                <article class={{message.bubbleClass}}>
                  <header class="ts-message__head">
                    {{#if message.authorHref}}
                      <a class="ts-message__author" href={{message.authorHref}}>
                        {{message.authorLabel}}
                      </a>
                    {{else}}
                      <span class="ts-message__author">{{message.authorLabel}}</span>
                    {{/if}}

                    {{#if message.staff}}
                      <span class="ts-badge">{{i18n "ticketing_system.ticket.staff_badge"}}</span>
                    {{/if}}
                    {{#if message.internal}}
                      <span class="ts-badge is-internal">
                        {{i18n "ticketing_system.ticket.internal_badge"}}
                      </span>
                    {{/if}}

                    <time class="ts-message__time">{{message.createdAt}}</time>
                  </header>

                  <div class="ts-message__body">{{message.cooked}}</div>
                </article>
              {{/each}}
            </div>
          {{else}}
            <p class="ts-muted">{{i18n "ticketing_system.detail.no_messages"}}</p>
          {{/if}}

          <TicketingSystemComposer
            @ticket={{this.ticket}}
            @canNote={{this.canWriteNote}}
            @onPosted={{this.onPosted}}
          />
        </section>

        <section class="ts-section">
          <h2 class="ts-section__title">{{i18n "ticketing_system.detail.timeline"}}</h2>

          {{#if this.events.length}}
            <ol class="ts-timeline">
              {{#each this.events as |event|}}
                <li class="ts-timeline__item">
                  <span class="ts-timeline__dot"></span>
                  <div class="ts-timeline__body">
                    <p class="ts-timeline__line">
                      <span class="ts-timeline__kind">{{event.label}}</span>
                      {{#if event.actorLabel}}
                        <span class="ts-timeline__actor">· {{event.actorLabel}}</span>
                      {{/if}}
                      {{#if event.changeLabel}}
                        <span class="ts-timeline__change">{{event.changeLabel}}</span>
                      {{/if}}
                    </p>
                    <time class="ts-timeline__time">{{event.createdAt}}</time>
                  </div>
                </li>
              {{/each}}
            </ol>
          {{else}}
            <p class="ts-muted">{{i18n "ticketing_system.detail.no_events"}}</p>
          {{/if}}
        </section>
      {{/if}}
    </div>
  </template>
}
