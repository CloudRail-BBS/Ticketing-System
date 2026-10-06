import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import { api, serverErrorMessage } from "../../lib/ticketing-system";
import TicketingSystemIcon from "./icon";
import TicketingSystemPill from "./pill";

// 与服务端 `TicketingSystem::Department` 的常量保持一致。
//
// 这里刻意重复一遍数字，而不是从某个接口读回来：表单需要在**离线也能**判断
// 「这个值看起来对吗」，而服务端才是最终裁判。重复的是数字上限，不是校验逻辑 ——
// 真正的拒绝（slug 冲突、用户组不存在）只能由服务端给出，前端只挡下明显为空的
// 那种，让用户少跑一次往返。
const MAX_NAME_LENGTH = 80;
const MAX_DESCRIPTION_LENGTH = 500;
const MAX_SLA_HOURS = 8760;

// 与服务端 `Constants::PRIORITIES` 的键集一致。顺序就是展示顺序。
const PRIORITY_KEYS = ["low", "normal", "high", "urgent"];

// 新建时的初值。空字符串而不是 null：每个字段都绑在原生输入框上，
// 一个 null 会渲染成字面的 "null"。
function blankDraft() {
  return {
    id: null,
    name: "",
    slug: "",
    description: "",
    position: 0,
    enabled: true,
    staff_group_name: "",
    first_response_hours: 24,
    resolution_hours: 72,
    default_priority: "normal",
  };
}

// 注意 `default_priority`：`DepartmentSerializer` 覆写了这个字段，
// 输出的**是名字**（"high"）而不是列里的整数。所以这里不用做映射。
function draftFrom(department) {
  return {
    id: department.id,
    name: department.name ?? "",
    slug: department.slug ?? "",
    description: department.description ?? "",
    position: department.position ?? 0,
    enabled: department.enabled !== false,
    staff_group_name: department.staff_group_name ?? "",
    first_response_hours: department.first_response_hours ?? 24,
    resolution_hours: department.resolution_hours ?? 72,
    default_priority: department.default_priority ?? "normal",
  };
}

export default class TicketingSystemDepartmentManager extends Component {
  @service("ticketing-system") ticketingSystem;

  @tracked departments = [];
  @tracked loading = true;
  @tracked loadError = null;

  // null 表示表单关闭。用「有没有草稿」而不是一个布尔量：布尔量和草稿是两个
  // 会各自漂移的状态，而 `draft === null` 不可能与草稿内容矛盾。
  @tracked draft = null;
  @tracked saving = false;
  @tracked formError = null;

  @tracked notice = null;
  @tracked actionError = null;

  // 行内二次确认。存 id 而不是布尔量，这样「点了 A 的删除、又点了 B 的删除」
  // 不会让两行同时进入确认态。
  @tracked pendingDeleteId = null;

  constructor() {
    super(...arguments);
    this.fetch();
  }

  // ---- 表格行 -----------------------------------------------------------

  get rows() {
    return this.departments.map((department) => ({
      id: department.id,
      name: department.name,
      slug: department.slug,
      description: department.description,
      enabled: department.enabled !== false,
      statusLabel:
        department.enabled !== false
          ? i18n("ticketing_system.admin.departments.enabled")
          : i18n("ticketing_system.admin.departments.disabled"),
      statusClass:
        department.enabled !== false ? "ts-pill is-enabled" : "ts-pill is-disabled",
      groupLabel:
        department.staff_group_name ||
        i18n("ticketing_system.admin.departments.staff_group_any"),
      firstResponseHours: department.first_response_hours,
      resolutionHours: department.resolution_hours,
      priority: department.default_priority,
      priorityLabel: i18n(
        `ticketing_system.priority.${department.default_priority}`,
      ),
      confirmPending: this.pendingDeleteId === department.id,
      confirmLabel: i18n(
        "ticketing_system.admin.departments.delete_confirm",
        { name: department.name },
      ),
      rowClass:
        department.enabled === false ? "ts-table__row is-disabled" : "ts-table__row",
    }));
  }

  get hasDepartments() {
    return this.departments.length > 0;
  }

  // ---- 表单 -------------------------------------------------------------

  get formOpen() {
    return this.draft !== null;
  }

  get formTitle() {
    if (!this.draft) {
      return "";
    }
    return this.draft.id === null
      ? i18n("ticketing_system.admin.departments.new")
      : i18n("ticketing_system.admin.departments.edit");
  }

  get canSave() {
    if (!this.draft || this.saving) {
      return false;
    }
    const name = this.draft.name.trim();
    return name.length > 0 && name.length <= MAX_NAME_LENGTH;
  }

  get nameHint() {
    if (!this.draft) {
      return null;
    }
    if (this.draft.name.trim().length === 0) {
      return i18n("ticketing_system.admin.departments.name_required");
    }
    return null;
  }

  get nameHintClass() {
    return this.nameHint ? "ts-field__hint is-error" : "ts-field__hint";
  }

  // 模板里不能写 `{{not this.canSave}}`：`not` 是 ember-truth-helpers 提供的，
  // 不是 Glimmer 的内建辅助函数，而 Discourse 的 `discourse/truth-helpers` 在
  // 当前版本里已经不存在了 —— import 一个解析不了的模块会把整个插件 bundle
  // 换成一行 throw（见 icon.gjs 的说明）。所有布尔取反都在这里算好。
  get saveDisabled() {
    return !this.canSave;
  }

  get newDisabled() {
    return this.formOpen;
  }

  get nameMaxLength() {
    return MAX_NAME_LENGTH;
  }

  get descriptionMaxLength() {
    return MAX_DESCRIPTION_LENGTH;
  }

  get slaMaxHours() {
    return MAX_SLA_HOURS;
  }

  get priorityOptions() {
    const current = this.draft?.default_priority;
    return PRIORITY_KEYS.map((key) => ({
      value: key,
      label: i18n(`ticketing_system.priority.${key}`),
      selected: key === current,
    }));
  }

  get saveLabel() {
    return this.saving
      ? i18n("ticketing_system.admin.departments.saving")
      : i18n("ticketing_system.admin.departments.save");
  }

  // ---- 数据 -------------------------------------------------------------

  async fetch() {
    this.loading = true;

    try {
      const payload = await ajax(api("departments"));
      this.departments = payload.departments ?? [];
      this.loadError = null;
    } catch (rawError) {
      this.departments = [];
      this.loadError =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.admin.departments.failed");
    } finally {
      this.loading = false;
    }
  }

  // 表单提交的载荷。
  //
  // 刻意**不**走 `compact()`（lib/ticketing-system.js 里那个剥掉空值的工具）。
  // 在这里空字符串是有意义的值：「把描述清空」「把用户组清空」都必须能提交，
  // 而 `compact` 会把它们整键丢掉，于是 `update!` 不会改这一列 —— 用户看到
  // 保存成功、内容却还在。`slug` 是唯一的例外，它的空值语义由服务端定义
  // （`before_validation :assign_slug` 会按名称重新生成），见下面的提示文案。
  #payload() {
    const draft = this.draft;

    return {
      name: draft.name.trim(),
      slug: draft.slug.trim(),
      description: draft.description,
      position: draft.position === "" ? 0 : draft.position,
      enabled: draft.enabled,
      staff_group_name: draft.staff_group_name.trim(),
      first_response_hours: draft.first_response_hours,
      resolution_hours: draft.resolution_hours,
      default_priority: draft.default_priority,
    };
  }

  // ---- 交互：表单 -------------------------------------------------------

  // `fetch` 本身不是 `@action`，所以不能直接写 `{{on "click" this.fetch}}`：
  // `on` 修改器把回调当普通函数调用，`this` 是 undefined，方法体第一行
  // `this.loading = true` 就会抛错。包一层 `@action`（它会绑定 `this`）是
  // 这里唯一需要的理由，不是风格问题。
  @action
  refresh() {
    return this.fetch();
  }

  @action
  openNew() {
    this.draft = blankDraft();
    this.formError = null;
    this.notice = null;
    this.actionError = null;
    this.pendingDeleteId = null;
  }

  @action
  openEdit(event) {
    const id = Number(event.currentTarget.dataset.id);
    const department = this.departments.find((item) => item.id === id);
    if (!department) {
      return;
    }

    this.draft = draftFrom(department);
    this.formError = null;
    this.notice = null;
    this.actionError = null;
    this.pendingDeleteId = null;
  }

  @action
  closeForm() {
    this.draft = null;
    this.formError = null;
  }

  // 一个处理器覆盖所有字段：每个输入带 `data-field`，值按控件类型取。
  //
  // 用一个而不是九个 action：九个几乎相同的 action 里必然有一个写错
  // `data-field`，而那种错误的症状是「某个字段保存后回到旧值」，不报错。
  @action
  onField(event) {
    const target = event.target;
    const field = target.dataset.field;
    if (!field || !this.draft) {
      return;
    }

    // 数字框取到的仍是字符串，交给服务端的 `numericality` 校验去转换与拒绝。
    // 在这里 `Number()` 会把空框变成 0，而 0 对 `first_response_hours` 是
    // 合法输入（会被 `greater_than: 0` 拒掉），于是「用户清空了框」和
    // 「用户填了 0」得到同一条报错 —— 让服务端看到原值更诚实。
    const value = target.type === "checkbox" ? target.checked : target.value;

    this.draft = { ...this.draft, [field]: value };
    this.formError = null;
  }

  @action
  async save(event) {
    event?.preventDefault?.();

    if (!this.canSave) {
      return;
    }

    const wasNew = this.draft.id === null;
    this.saving = true;

    try {
      if (wasNew) {
        await ajax(api("departments"), { type: "POST", data: this.#payload() });
      } else {
        await ajax(api("departments", String(this.draft.id)), {
          type: "PUT",
          data: this.#payload(),
        });
      }

      this.draft = null;
      this.formError = null;
      this.actionError = null;
      this.notice = i18n(
        wasNew
          ? "ticketing_system.admin.departments.created"
          : "ticketing_system.admin.departments.updated",
      );

      await this.fetch();
      // 部门列表也挂在 service 上（工单列表的筛选器、新建表单的部门下拉框），
      // 不刷新的话用户切回列表页看到的还是旧选项。
      this.ticketingSystem.reload();
    } catch (rawError) {
      this.formError =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.admin.departments.save_failed");
    } finally {
      this.saving = false;
    }
  }

  // ---- 交互：删除 -------------------------------------------------------

  @action
  askDelete(event) {
    this.pendingDeleteId = Number(event.currentTarget.dataset.id);
    this.notice = null;
    this.actionError = null;
  }

  @action
  cancelDelete() {
    this.pendingDeleteId = null;
  }

  @action
  async confirmDelete(event) {
    const id = Number(event.currentTarget.dataset.id);
    this.pendingDeleteId = null;

    try {
      await ajax(api("departments", String(id)), { type: "DELETE" });
      this.actionError = null;
      this.notice = i18n("ticketing_system.admin.departments.deleted");

      await this.fetch();
      this.ticketingSystem.reload();
    } catch (rawError) {
      // 最常见的失败是「部门下还有工单」，服务端已经翻译好那句话
      // （`Errors::Conflict.new(:department_in_use, name:)`），直接用。
      this.actionError =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.admin.departments.delete_in_use");
    }
  }

  <template>
    <div class="ts-departments">
      <header class="ts-page__header">
        <div class="ts-page__intro">
          <h2 class="ts-page__title">{{i18n "ticketing_system.admin.departments.heading"}}</h2>
          <p class="ts-page__subtitle">{{i18n "ticketing_system.admin.departments.description"}}</p>
        </div>

        <div class="ts-page__actions">
          <button
            type="button"
            class="btn btn-primary"
            disabled={{this.newDisabled}}
            {{on "click" this.openNew}}
          >
            <TicketingSystemIcon @name="plus" />
            <span class="ts-btn-text">{{i18n "ticketing_system.admin.departments.new"}}</span>
          </button>
        </div>
      </header>

      {{#if this.notice}}
        <p class="ts-notice">{{this.notice}}</p>
      {{/if}}

      {{#if this.actionError}}
        <p class="ts-form__error">{{this.actionError}}</p>
      {{/if}}

      {{#if this.formOpen}}
        <form class="ts-form ts-form--department" {{on "submit" this.save}}>
          <h3 class="ts-section__title">{{this.formTitle}}</h3>

          {{#if this.formError}}
            <p class="ts-form__error">{{this.formError}}</p>
          {{/if}}

          <div class="ts-form__row">
            <label class="ts-field ts-field--grow">
              <span class="ts-field__label">{{i18n "ticketing_system.admin.departments.name"}}</span>
              <input
                type="text"
                class="ts-input"
                data-field="name"
                value={{this.draft.name}}
                maxlength={{this.nameMaxLength}}
                {{on "input" this.onField}}
              />
              {{#if this.nameHint}}
                <span class={{this.nameHintClass}}>{{this.nameHint}}</span>
              {{/if}}
            </label>

            <label class="ts-field ts-field--grow">
              <span class="ts-field__label">{{i18n "ticketing_system.admin.departments.slug"}}</span>
              <input
                type="text"
                class="ts-input"
                data-field="slug"
                value={{this.draft.slug}}
                maxlength={{this.nameMaxLength}}
                {{on "input" this.onField}}
              />
              <span class="ts-field__hint">
                {{i18n "ticketing_system.admin.departments.slug_hint"}}
              </span>
            </label>
          </div>

          <label class="ts-field ts-field--block">
            <span class="ts-field__label">
              {{i18n "ticketing_system.admin.departments.description_field"}}
            </span>
            <textarea
              class="ts-textarea"
              data-field="description"
              maxlength={{this.descriptionMaxLength}}
              value={{this.draft.description}}
              {{on "input" this.onField}}
            ></textarea>
          </label>

          <div class="ts-form__row">
            <label class="ts-field">
              <span class="ts-field__label">{{i18n "ticketing_system.admin.departments.position"}}</span>
              <input
                type="number"
                class="ts-input"
                data-field="position"
                min="0"
                value={{this.draft.position}}
                {{on "input" this.onField}}
              />
            </label>

            <label class="ts-field">
              <span class="ts-field__label">
                {{i18n "ticketing_system.admin.departments.default_priority"}}
              </span>
              <select class="ts-select" data-field="default_priority" {{on "change" this.onField}}>
                {{#each this.priorityOptions as |option|}}
                  <option value={{option.value}} selected={{option.selected}}>
                    {{option.label}}
                  </option>
                {{/each}}
              </select>
            </label>

            <label class="ts-checkbox">
              <input
                type="checkbox"
                data-field="enabled"
                checked={{this.draft.enabled}}
                {{on "change" this.onField}}
              />
              <span>{{i18n "ticketing_system.admin.departments.enabled"}}</span>
            </label>
          </div>

          <label class="ts-field ts-field--block">
            <span class="ts-field__label">
              {{i18n "ticketing_system.admin.departments.staff_group"}}
            </span>
            <input
              type="text"
              class="ts-input"
              data-field="staff_group_name"
              value={{this.draft.staff_group_name}}
              {{on "input" this.onField}}
            />
            <span class="ts-field__hint">
              {{i18n "ticketing_system.admin.departments.staff_group_hint"}}
            </span>
          </label>

          <div class="ts-form__row">
            <label class="ts-field">
              <span class="ts-field__label">
                {{i18n "ticketing_system.admin.departments.first_response_hours"}}
              </span>
              <input
                type="number"
                class="ts-input"
                data-field="first_response_hours"
                min="1"
                max={{this.slaMaxHours}}
                value={{this.draft.first_response_hours}}
                {{on "input" this.onField}}
              />
            </label>

            <label class="ts-field">
              <span class="ts-field__label">
                {{i18n "ticketing_system.admin.departments.resolution_hours"}}
              </span>
              <input
                type="number"
                class="ts-input"
                data-field="resolution_hours"
                min="1"
                max={{this.slaMaxHours}}
                value={{this.draft.resolution_hours}}
                {{on "input" this.onField}}
              />
            </label>
          </div>

          <div class="ts-form__footer">
            <button type="button" class="btn btn-default" {{on "click" this.closeForm}}>
              {{i18n "ticketing_system.admin.departments.cancel"}}
            </button>
            <button type="submit" class="btn btn-primary" disabled={{this.saveDisabled}}>
              {{this.saveLabel}}
            </button>
          </div>
        </form>
      {{/if}}

      {{#if this.loading}}
        <div class="ts-state">
          <TicketingSystemIcon @name="clock" @size="24" />
          <p>{{i18n "ticketing_system.loading"}}</p>
        </div>
      {{else if this.loadError}}
        <div class="ts-state is-error">
          <TicketingSystemIcon @name="alert" @size="24" />
          <p>{{this.loadError}}</p>
          <button type="button" class="btn btn-default" {{on "click" this.refresh}}>
            {{i18n "ticketing_system.actions.retry"}}
          </button>
        </div>
      {{else if this.hasDepartments}}
        <div class="ts-table-wrap">
          <table class="ts-table">
            <thead>
              <tr>
                <th>{{i18n "ticketing_system.admin.departments.name"}}</th>
                <th class="ts-table__col-department">
                  {{i18n "ticketing_system.admin.departments.staff_group"}}
                </th>
                <th>{{i18n "ticketing_system.admin.departments.first_response_hours"}}</th>
                <th>{{i18n "ticketing_system.admin.departments.resolution_hours"}}</th>
                <th>{{i18n "ticketing_system.admin.departments.default_priority"}}</th>
                <th>{{i18n "ticketing_system.fields.status"}}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {{#each this.rows as |row|}}
                <tr class={{row.rowClass}}>
                  <td>
                    <span class="ts-dept-name">{{row.name}}</span>
                    <span class="ts-ticket-link__number">{{row.slug}}</span>
                  </td>
                  <td class="ts-table__col-department">{{row.groupLabel}}</td>
                  <td>{{row.firstResponseHours}}</td>
                  <td>{{row.resolutionHours}}</td>
                  <td>
                    <TicketingSystemPill
                      @kind="priority"
                      @value={{row.priority}}
                      @label={{row.priorityLabel}}
                    />
                  </td>
                  <td>
                    <span class={{row.statusClass}}>{{row.statusLabel}}</span>
                  </td>
                  <td>
                    {{#if row.confirmPending}}
                      <div class="ts-confirm">
                        <span class="ts-confirm__text">{{row.confirmLabel}}</span>
                        <button
                          type="button"
                          class="btn btn-danger btn-small"
                          data-id={{row.id}}
                          {{on "click" this.confirmDelete}}
                        >
                          {{i18n "ticketing_system.admin.departments.delete"}}
                        </button>
                        <button
                          type="button"
                          class="btn btn-default btn-small"
                          {{on "click" this.cancelDelete}}
                        >
                          {{i18n "ticketing_system.admin.departments.cancel"}}
                        </button>
                      </div>
                    {{else}}
                      <div class="ts-row-actions">
                        <button
                          type="button"
                          class="btn btn-default btn-small"
                          data-id={{row.id}}
                          {{on "click" this.openEdit}}
                        >
                          {{i18n "ticketing_system.admin.departments.edit"}}
                        </button>
                        <button
                          type="button"
                          class="btn btn-default btn-small"
                          data-id={{row.id}}
                          {{on "click" this.askDelete}}
                        >
                          {{i18n "ticketing_system.admin.departments.delete"}}
                        </button>
                      </div>
                    {{/if}}
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      {{else}}
        <div class="ts-state">
          <TicketingSystemIcon @name="building" @size="24" />
          <p>{{i18n "ticketing_system.admin.departments.empty"}}</p>
        </div>
      {{/if}}
    </div>
  </template>
}
