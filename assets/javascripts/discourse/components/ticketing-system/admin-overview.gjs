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
  barWidth,
  formatDuration,
  formatTimestamp,
  serverErrorMessage,
  userPath,
} from "../../lib/ticketing-system";
import TicketingSystemIcon from "./icon";

// 管理页的「总览」标签。
//
// 数据形状来自 `Statistics.generate`（lib/ticketing_system/statistics.rb）：
//
//   { generated_at,
//     totals:        { all, active, unassigned, in_progress, overdue },
//     by_status:     { open: n, in_progress: n, pending: n, resolved: n, closed: n },
//     by_priority:   { low: n, normal: n, high: n, urgent: n },
//     by_department: [{ id, name, slug, enabled, staff_group_name,
//                       total, unassigned, overdue }],
//     first_response:{ sample_size, average_seconds, median_seconds, breached, on_time },
//     activity:      { created_today, created_week, created_month,
//                      resolved_week, resolved_month, closed_month },
//     load:          [{ id, username, name, avatar_template, assigned }] }
//
// 全部聚合都在一次请求里算完（服务端用 SQL 聚合，不是把工单捞出来在 Ruby 里数）。
// 所以这里没有分页、没有懒加载：一次 /tickets/api/stats 就是全部。
export default class TicketingSystemAdminOverview extends Component {
  @service("ticketing-system") ticketingSystem;

  @tracked stats = null;
  @tracked loading = true;
  @tracked error = null;

  constructor() {
    super(...arguments);
    // 构造器里只发请求，不读 args —— 见 ticket-list.gjs 里的说明。
    this.fetch();
  }

  get generatedAt() {
    return this.stats ? formatTimestamp(this.stats.generated_at) : null;
  }

  // ---- 队列总计 ---------------------------------------------------------

  get totalCards() {
    const totals = this.stats?.totals ?? {};

    return [
      {
        key: "all_tickets",
        label: i18n("ticketing_system.admin.overview.all_tickets"),
        value: totals.all ?? 0,
        cardClass: "ts-card",
      },
      {
        key: "active",
        label: i18n("ticketing_system.admin.overview.active"),
        value: totals.active ?? 0,
        cardClass: "ts-card",
      },
      {
        key: "unassigned",
        label: i18n("ticketing_system.admin.overview.unassigned"),
        value: totals.unassigned ?? 0,
        // 未分配是唯一一个「数字大就是坏事」的常规计数：它意味着没人认领。
        cardClass: (totals.unassigned ?? 0) > 0 ? "ts-card is-warn" : "ts-card",
      },
      {
        key: "in_progress",
        label: i18n("ticketing_system.admin.overview.in_progress"),
        value: totals.in_progress ?? 0,
        cardClass: "ts-card",
      },
      {
        key: "overdue",
        label: i18n("ticketing_system.admin.overview.overdue"),
        value: totals.overdue ?? 0,
        cardClass: (totals.overdue ?? 0) > 0 ? "ts-card is-alert" : "ts-card",
      },
    ];
  }

  // ---- 分布条形图 -------------------------------------------------------

  // 键 → 文案。`by_status` 的键就是 `Constants::STATUSES` 的键名，
  // `by_priority` 同理，两边的词表在 client 语言文件里各有一份
  // （通知渲染器也要用，见 client.en.yml 里的注释）。
  #bars(raw, namespace) {
    const entries = Object.entries(raw ?? {});
    const total = entries.reduce((sum, [, value]) => sum + value, 0);

    return entries.map(([key, value]) => ({
      key,
      label: i18n(`ticketing_system.${namespace}.${key}`),
      value,
      // `barWidth` 把 0 与 undefined 都收敛成 "width: 0%"。
      // 不收敛的话会得到 `style="width: NaN%"`，浏览器整条忽略该声明，
      // 进度条静默停在零宽 —— 看起来像「这个状态没有工单」，而不是一个 bug。
      //
      // 包一层 htmlSafe：`style` 是「原始」属性，核心自己的模板也是这么写的
      // （见 frontend/discourse/app/components/sidebar/section-link-prefix.gjs）。
      fillStyle: htmlSafe(barWidth(value, total)),
    }));
  }

  get statusBars() {
    return this.#bars(this.stats?.by_status, "status");
  }

  get priorityBars() {
    return this.#bars(this.stats?.by_priority, "priority");
  }

  // ---- 按部门 -----------------------------------------------------------

  get departmentRows() {
    const rows = this.stats?.by_department ?? [];
    // 条形按「最大的那个部门」归一，而不是按总数：按总数归一之后，
    // 一个 10 个部门的论坛里每条都只有几个百分点，看起来全是零。
    const max = rows.reduce((peak, row) => Math.max(peak, row.total ?? 0), 0);

    return rows.map((row) => ({
      id: row.id,
      name: row.name,
      slug: row.slug,
      enabled: row.enabled !== false,
      statusLabel:
        row.enabled !== false
          ? i18n("ticketing_system.admin.departments.enabled")
          : i18n("ticketing_system.admin.departments.disabled"),
      statusClass: row.enabled !== false ? "ts-pill is-enabled" : "ts-pill is-disabled",
      groupLabel:
        row.staff_group_name ||
        i18n("ticketing_system.admin.departments.staff_group_any"),
      total: row.total ?? 0,
      unassigned: row.unassigned ?? 0,
      overdue: row.overdue ?? 0,
      overdueClass: (row.overdue ?? 0) > 0 ? "ts-cell is-alert" : "ts-cell",
      fillStyle: htmlSafe(barWidth(row.total, max)),
    }));
  }

  // ---- 首次响应 ---------------------------------------------------------

  get firstResponse() {
    const data = this.stats?.first_response;
    if (!data) {
      return null;
    }

    const answered = (data.on_time ?? 0) + (data.breached ?? 0);

    return {
      sampleSize: data.sample_size ?? 0,
      hasSample: (data.sample_size ?? 0) > 0,
      sampleLabel: i18n("ticketing_system.admin.overview.sample_size", {
        count: data.sample_size ?? 0,
      }),
      average: formatDuration(data.average_seconds, i18n),
      median: formatDuration(data.median_seconds, i18n),
      onTime: data.on_time ?? 0,
      breached: data.breached ?? 0,
      onTimeStyle: htmlSafe(barWidth(data.on_time, answered)),
      breachedStyle: htmlSafe(barWidth(data.breached, answered)),
    };
  }

  // ---- 动态 -------------------------------------------------------------

  get activityRows() {
    const activity = this.stats?.activity ?? {};

    return [
      "created_today",
      "created_week",
      "created_month",
      "resolved_week",
      "resolved_month",
      "closed_month",
    ].map((key) => ({
      key,
      label: i18n(`ticketing_system.admin.overview.${key}`),
      value: activity[key] ?? 0,
    }));
  }

  // ---- 员工负载 ---------------------------------------------------------

  get loadRows() {
    return (this.stats?.load ?? []).map((user) => ({
      id: user.id,
      label: user.name || user.username,
      href: userPath(user.username),
      assigned: user.assigned ?? 0,
      assignedLabel: i18n("ticketing_system.admin.overview.assigned_count", {
        count: user.assigned ?? 0,
      }),
    }));
  }

  // ---- 数据 -------------------------------------------------------------

  async fetch() {
    this.loading = true;

    try {
      const payload = await ajax(api("stats"));
      this.stats = payload.stats ?? null;
      this.error = null;
    } catch (rawError) {
      this.stats = null;
      this.error =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.admin.overview.failed");
    } finally {
      this.loading = false;
    }
  }

  @action
  refresh() {
    return this.fetch();
  }

  <template>
    <div class="ts-overview">
      {{#if this.loading}}
        <div class="ts-state">
          <TicketingSystemIcon @name="clock" @size="24" />
          <p>{{i18n "ticketing_system.admin.overview.loading"}}</p>
        </div>
      {{else if this.error}}
        <div class="ts-state is-error">
          <TicketingSystemIcon @name="alert" @size="24" />
          <p>{{this.error}}</p>
          <button type="button" class="btn btn-default" {{on "click" this.refresh}}>
            {{i18n "ticketing_system.actions.retry"}}
          </button>
        </div>
      {{else if this.stats}}
        <div class="ts-page__actions ts-overview__actions">
          <span class="ts-muted">{{this.generatedAt}}</span>
          <button
            type="button"
            class="btn btn-default btn-small"
            title={{i18n "ticketing_system.actions.refresh"}}
            {{on "click" this.refresh}}
          >
            <TicketingSystemIcon @name="refresh" @size="14" />
          </button>
        </div>

        <section class="ts-section">
          <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.totals"}}</h2>
          <div class="ts-cards">
            {{#each this.totalCards as |card|}}
              <div class={{card.cardClass}}>
                <span class="ts-card__label">{{card.label}}</span>
                <span class="ts-card__value">{{card.value}}</span>
              </div>
            {{/each}}
          </div>
        </section>

        <div class="ts-columns">
          <section class="ts-section">
            <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.by_status"}}</h2>
            <div class="ts-bars">
              {{#each this.statusBars as |bar|}}
                <div class="ts-bar">
                  <span class="ts-bar__label">{{bar.label}}</span>
                  <span class="ts-bar__track">
                    <span class="ts-bar__fill" style={{bar.fillStyle}}></span>
                  </span>
                  <span class="ts-bar__value">{{bar.value}}</span>
                </div>
              {{/each}}
            </div>
          </section>

          <section class="ts-section">
            <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.by_priority"}}</h2>
            <div class="ts-bars">
              {{#each this.priorityBars as |bar|}}
                <div class="ts-bar">
                  <span class="ts-bar__label">{{bar.label}}</span>
                  <span class="ts-bar__track">
                    <span class="ts-bar__fill" style={{bar.fillStyle}}></span>
                  </span>
                  <span class="ts-bar__value">{{bar.value}}</span>
                </div>
              {{/each}}
            </div>
          </section>
        </div>

        {{#if this.departmentRows.length}}
          <section class="ts-section">
            <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.by_department"}}</h2>
            <div class="ts-table-wrap">
              <table class="ts-table">
                <thead>
                  <tr>
                    <th>{{i18n "ticketing_system.admin.departments.name"}}</th>
                    <th>{{i18n "ticketing_system.admin.departments.staff_group"}}</th>
                    <th>{{i18n "ticketing_system.admin.overview.open_tickets"}}</th>
                    <th>{{i18n "ticketing_system.admin.overview.unassigned"}}</th>
                    <th>{{i18n "ticketing_system.admin.overview.overdue"}}</th>
                  </tr>
                </thead>
                <tbody>
                  {{#each this.departmentRows as |row|}}
                    <tr>
                      <td>
                        <span class="ts-dept-name">{{row.name}}</span>
                        <span class={{row.statusClass}}>{{row.statusLabel}}</span>
                      </td>
                      <td>{{row.groupLabel}}</td>
                      <td>
                        <span class="ts-bar ts-bar--inline">
                          <span class="ts-bar__track">
                            <span class="ts-bar__fill" style={{row.fillStyle}}></span>
                          </span>
                          <span class="ts-bar__value">{{row.total}}</span>
                        </span>
                      </td>
                      <td>{{row.unassigned}}</td>
                      <td class={{row.overdueClass}}>{{row.overdue}}</td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
          </section>
        {{/if}}

        <section class="ts-section">
          <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.first_response"}}</h2>

          {{#if this.firstResponse.hasSample}}
            <div class="ts-meta">
              <div class="ts-meta__item">
                <dt class="ts-meta__label">{{i18n "ticketing_system.admin.overview.average"}}</dt>
                <dd class="ts-meta__value">{{this.firstResponse.average}}</dd>
              </div>
              <div class="ts-meta__item">
                <dt class="ts-meta__label">{{i18n "ticketing_system.admin.overview.median"}}</dt>
                <dd class="ts-meta__value">{{this.firstResponse.median}}</dd>
              </div>
            </div>

            <p class="ts-muted ts-overview__hint">{{this.firstResponse.sampleLabel}}</p>

            <div class="ts-split">
              <div class="ts-split__part is-good">
                <span class="ts-split__label">
                  {{i18n "ticketing_system.admin.overview.on_time"}}
                </span>
                <span class="ts-split__value">{{this.firstResponse.onTime}}</span>
                <span class="ts-bar__track">
                  <span class="ts-bar__fill" style={{this.firstResponse.onTimeStyle}}></span>
                </span>
              </div>
              <div class="ts-split__part is-bad">
                <span class="ts-split__label">
                  {{i18n "ticketing_system.admin.overview.breached"}}
                </span>
                <span class="ts-split__value">{{this.firstResponse.breached}}</span>
                <span class="ts-bar__track">
                  <span class="ts-bar__fill" style={{this.firstResponse.breachedStyle}}></span>
                </span>
              </div>
            </div>
          {{else}}
            <p class="ts-muted">{{i18n "ticketing_system.admin.overview.no_sample"}}</p>
          {{/if}}
        </section>

        <div class="ts-columns">
          <section class="ts-section">
            <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.activity"}}</h2>
            <div class="ts-bars">
              {{#each this.activityRows as |row|}}
                <div class="ts-bar ts-bar--plain">
                  <span class="ts-bar__label">{{row.label}}</span>
                  <span class="ts-bar__value">{{row.value}}</span>
                </div>
              {{/each}}
            </div>
          </section>

          <section class="ts-section">
            <h2 class="ts-section__title">{{i18n "ticketing_system.admin.overview.load"}}</h2>

            {{#if this.loadRows.length}}
              <ul class="ts-load">
                {{#each this.loadRows as |row|}}
                  <li class="ts-load__item">
                    <a href={{row.href}}>{{row.label}}</a>
                    <span class="ts-load__count">{{row.assignedLabel}}</span>
                  </li>
                {{/each}}
              </ul>
            {{else}}
              <p class="ts-muted">{{i18n "ticketing_system.admin.overview.no_load"}}</p>
            {{/if}}
          </section>
        </div>
      {{/if}}
    </div>
  </template>
}
