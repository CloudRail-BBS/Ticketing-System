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
  pagePath,
  serverErrorMessage,
} from "../../lib/ticketing-system";
import TicketingSystemIcon from "./icon";

// 新建工单表单。
//
// 长度限制全部来自服务端下发的 `capabilities.limits`（见 Permissions#client_payload），
// 不在这里写死。`title_min_length` / `title_max_length` / `body_max_length` 都是
// site setting，管理员改一个数字不该需要改前端 —— 而且前端写死的那个数字一旦和
// 服务端不一致，用户会看到「明明够长却提交失败」。
export default class TicketingSystemNewTicketForm extends Component {
  @service("ticketing-system") ticketingSystem;
  @service siteSettings;
  @service router;

  @tracked title = "";
  @tracked body = "";
  // 空串 = 不指定部门。服务端把空串与缺失一视同仁（`params[:department].presence`）。
  @tracked department = "";
  // null = 还没选，用服务端给的默认值。
  @tracked priority = null;
  @tracked submitting = false;
  @tracked error = null;

  // 只有员工，或论坛显式放开了 `allow_requester_priority`，才能选优先级。
  // 这条规则在服务端也有（TicketCreator#resolve_priority），两边都判断是故意的：
  // 服务端是防线，前端是「不展示一个注定被拒绝的控件」。
  get canChoosePriority() {
    return (
      this.ticketingSystem.isStaff ||
      this.siteSettings?.ticketing_system_allow_requester_priority === true
    );
  }

  get priorityValue() {
    return this.priority ?? this.ticketingSystem.defaultPriority;
  }

  get departmentOptions() {
    const current = this.department;

    return [
      {
        value: "",
        label: i18n("ticketing_system.new.department_any"),
        selected: current === "",
      },
      ...this.ticketingSystem.enabledDepartments.map((department) => ({
        value: String(department.id),
        label: department.name,
        selected: String(department.id) === current,
      })),
    ];
  }

  get priorityOptions() {
    const current = this.priorityValue;

    return this.ticketingSystem.priorities.map((priority) => ({
      value: priority.id,
      label: priority.label,
      selected: priority.id === current,
    }));
  }

  get titleMinLength() {
    return this.ticketingSystem.titleMinLength;
  }

  get titleMaxLength() {
    return this.ticketingSystem.titleMaxLength;
  }

  get bodyMaxLength() {
    return this.ticketingSystem.bodyMaxLength;
  }

  get trimmedTitle() {
    return this.title.trim();
  }

  // 只在用户已经开始输入之后才提示「太短」。一进页面就飘一行红字是敌意设计。
  get titleTooShort() {
    return (
      this.trimmedTitle.length > 0 &&
      this.trimmedTitle.length < this.titleMinLength
    );
  }

  // 提交按钮的禁用条件**只**看「必填项是否为空」。
  //
  // 标题太短不在这里拦：那样用户会看到一个点不动的按钮，却不知道为什么 ——
  // 短标题是能修好的，把它交给 submit 里的校验并给出具体原因。
  get disabled() {
    return (
      this.submitting ||
      this.trimmedTitle.length === 0 ||
      this.body.trim().length === 0
    );
  }

  get submitLabel() {
    return this.submitting
      ? i18n("ticketing_system.new.submitting")
      : i18n("ticketing_system.new.submit");
  }

  get counterLabel() {
    return i18n("ticketing_system.new.counter", {
      count: this.body.length,
      max: this.bodyMaxLength,
    });
  }

  get cancelPath() {
    return pagePath("");
  }

  @action
  onTitleInput(event) {
    this.title = event.target.value;
  }

  @action
  onBodyInput(event) {
    this.body = event.target.value;
  }

  @action
  onDepartmentChange(event) {
    this.department = event.target.value;
  }

  @action
  onPriorityChange(event) {
    this.priority = event.target.value;
  }

  @action
  async submit(event) {
    event.preventDefault();

    if (this.disabled) {
      return;
    }

    if (this.trimmedTitle.length < this.titleMinLength) {
      this.error = i18n("ticketing_system.errors.title_too_short", {
        min: this.titleMinLength,
      });
      return;
    }

    this.submitting = true;

    try {
      // `compact()` 会把空串与 null 摘掉。部门留空时**不能**发 `department=""`：
      // 服务端读的是 `params[:department].presence`，空串恰好也走 nil 分支，
      // 但把无意义的参数发出去会让日志和调试都变吵。
      const payload = await ajax(api("tickets"), {
        type: "POST",
        data: compact({
          title: this.trimmedTitle,
          body: this.body,
          department: this.department,
          priority: this.canChoosePriority ? this.priorityValue : null,
        }),
      });

      this.error = null;
      // 未读计数与（员工视角的）队列都可能已经变了。
      this.ticketingSystem.reload();

      // 不 await：transitionTo 在跳转被中止时会 reject，而那不是错误 ——
      // 用户点了两次、或者中途点了别处，都不该弹一句「创建失败」。
      this.router
        .transitionTo("ticketing-system.show", payload.ticket.id)
        .catch(() => {});
    } catch (rawError) {
      // 限流、超过未关闭工单上限、标题过长、部门已停用……服务端都给了具体原因
      // （`Errors::*` → `render_json_error`），优先展示它。
      this.error =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.errors.create_failed");
    } finally {
      this.submitting = false;
    }
  }

  <template>
    <div class="ts-page">
      <header class="ts-page__header">
        <div class="ts-page__intro">
          <h1 class="ts-page__title">{{i18n "ticketing_system.new.heading"}}</h1>
          <p class="ts-page__subtitle">{{i18n "ticketing_system.new.description"}}</p>
        </div>
      </header>

      <form class="ts-form" {{on "submit" this.submit}}>
        <label class="ts-field ts-field--block">
          <span class="ts-field__label">{{i18n "ticketing_system.new.title_label"}}</span>
          <input
            type="text"
            class="ts-input"
            value={{this.title}}
            maxlength={{this.titleMaxLength}}
            placeholder={{i18n "ticketing_system.new.title_placeholder"}}
            {{on "input" this.onTitleInput}}
          />
          {{#if this.titleTooShort}}
            <span class="ts-field__hint is-error">
              {{i18n "ticketing_system.errors.title_too_short" min=this.titleMinLength}}
            </span>
          {{/if}}
        </label>

        <label class="ts-field ts-field--block">
          <span class="ts-field__label">{{i18n "ticketing_system.new.body_label"}}</span>
          <textarea
            class="ts-textarea"
            rows="8"
            value={{this.body}}
            maxlength={{this.bodyMaxLength}}
            placeholder={{i18n "ticketing_system.new.body_placeholder"}}
            {{on "input" this.onBodyInput}}
          ></textarea>
          <span class="ts-field__hint">{{this.counterLabel}}</span>
        </label>

        <div class="ts-form__row">
          <label class="ts-field">
            <span class="ts-field__label">{{i18n "ticketing_system.new.department_label"}}</span>
            <select class="ts-select" {{on "change" this.onDepartmentChange}}>
              {{#each this.departmentOptions as |option|}}
                <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
              {{/each}}
            </select>
          </label>

          {{#if this.canChoosePriority}}
            <label class="ts-field">
              <span class="ts-field__label">{{i18n "ticketing_system.new.priority_label"}}</span>
              <select class="ts-select" {{on "change" this.onPriorityChange}}>
                {{#each this.priorityOptions as |option|}}
                  <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
                {{/each}}
              </select>
            </label>
          {{/if}}
        </div>

        {{#if this.error}}
          <p class="ts-form__error">{{this.error}}</p>
        {{/if}}

        <div class="ts-form__footer">
          <a class="btn btn-default" href={{this.cancelPath}}>
            {{i18n "ticketing_system.detail.back"}}
          </a>
          <button type="submit" class="btn btn-primary" disabled={{this.disabled}}>
            <TicketingSystemIcon @name="ticket" @size="14" />
            <span class="ts-btn-text">{{this.submitLabel}}</span>
          </button>
        </div>
      </form>
    </div>
  </template>
}
