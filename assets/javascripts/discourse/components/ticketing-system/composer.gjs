import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import TicketingSystemAttachmentUploader from "../../lib/attachment-uploader";
import { api, serverErrorMessage } from "../../lib/ticketing-system";
import TicketingSystemAttachmentPicker from "./attachment-picker";
import TicketingSystemIcon from "./icon";

// 回复 / 内部备注编辑器。
//
// 服务端返回的是**整张工单**而不是新消息：一次回复可能改变状态
// （员工回复把 open 推到 in_progress，提交者回复把 pending 拉回 open），
// 也可能重开一张已关闭的工单，还一定会动计数器。再取一次是多余的一轮往返。
export default class TicketingSystemComposer extends Component {
  @service("ticketing-system") ticketingSystem;

  @tracked body = "";
  @tracked internal = false;
  @tracked sending = false;
  @tracked error = null;

  // 延迟创建并缓存。**不要**写成字段初始化（`uploader = new …(this.ticketingSystem)`）：
  // 字段初始化跑在 `super()` 之后但在组件真正可用之前，而 `@service` 的注入
  // 依赖 owner，取值的时机在这里是脆的。放进 getter 就只在渲染时取值，一定安全。
  // 缓存进一个非 @tracked 字段：它是实现细节，不该触发重渲染。
  _uploader = null;

  get uploader() {
    if (!this._uploader) {
      this._uploader = new TicketingSystemAttachmentUploader(
        this.ticketingSystem,
      );
    }
    return this._uploader;
  }

  get ticket() {
    return this.args.ticket;
  }

  get canNote() {
    return this.args.canNote === true;
  }

  get canReply() {
    return this.ticket?.can?.reply === true;
  }

  get disabled() {
    // 还有文件在传时不能提交：那些条目还没有 upload id，提交出去等于用户
    // 看着列表里有三个文件、实际只附带了一个。
    if (this.sending || this.uploader.uploading) {
      return true;
    }
    return this.internal ? !this.canNote : !this.canReply;
  }

  // 公开回复被禁但内部备注仍可用时，也要让员工能写备注——「工单已关闭」
  // 不该连内部沟通一起锁上。
  get available() {
    return this.canReply || this.canNote;
  }

  get placeholder() {
    if (this.internal) {
      return i18n("ticketing_system.detail.internal_placeholder");
    }
    return i18n("ticketing_system.detail.reply_placeholder");
  }

  get submitLabel() {
    return this.sending
      ? i18n("ticketing_system.actions.sending")
      : i18n("ticketing_system.actions.send");
  }

  get publicModeClass() {
    return this.internal
      ? "ts-composer__mode-btn"
      : "ts-composer__mode-btn is-active";
  }

  get internalModeClass() {
    return this.internal
      ? "ts-composer__mode-btn is-active"
      : "ts-composer__mode-btn";
  }

  @action
  onInput(event) {
    this.body = event.target.value;
  }

  @action
  usePublic() {
    this.internal = false;
  }

  @action
  useInternal() {
    this.internal = true;
  }

  @action
  async submit(event) {
    event.preventDefault();

    const body = this.body.trim();
    if (!body) {
      this.error = i18n("ticketing_system.errors.body_required");
      return;
    }

    this.sending = true;

    try {
      const payload = await ajax(
        api("tickets", String(this.ticket.id), "messages"),
        {
          type: "POST",
          data: {
            body,
            internal: this.internal ? "true" : "false",
            // 逗号拼接而不是数组。两种形状服务端都收（Attachments.normalize_ids
            // 显式支持 `["3","7"]` 与 `"3,7"`），但数组在 jQuery 序列化后是
            // `upload_ids[]=3&upload_ids[]=7`，一旦哪天 `traditional` 变了就会变成
            // `upload_ids=3&upload_ids=7` —— Rails 只保留最后一个，附件静默少一个。
            // 拼接字符串没有这个失效模式。
            upload_ids: this.uploader.uploadIds.join(","),
          },
        },
      );

      this.body = "";
      this.internal = false;
      this.error = null;
      this.uploader.clear();
      this.args.onPosted?.(payload);
    } catch (rawError) {
      this.error =
        serverErrorMessage(rawError) ??
        i18n("ticketing_system.errors.reply_failed");
    } finally {
      this.sending = false;
    }
  }

  <template>
    {{#if this.available}}
      <form class="ts-composer" {{on "submit" this.submit}}>
        {{#if this.canNote}}
          <div class="ts-composer__modes">
            <button
              type="button"
              class={{this.publicModeClass}}
              {{on "click" this.usePublic}}
            >
              {{i18n "ticketing_system.actions.mode_public"}}
            </button>
            <button
              type="button"
              class={{this.internalModeClass}}
              {{on "click" this.useInternal}}
            >
              <TicketingSystemIcon @name="lock" @size="13" />
              {{i18n "ticketing_system.actions.mode_internal"}}
            </button>
          </div>
        {{/if}}

        {{#if this.internal}}
          <p class="ts-composer__hint">
            {{i18n "ticketing_system.actions.mode_internal_hint"}}
          </p>
        {{/if}}

        <textarea
          class="ts-textarea"
          rows="5"
          value={{this.body}}
          placeholder={{this.placeholder}}
          {{on "input" this.onInput}}
        ></textarea>

        <TicketingSystemAttachmentPicker @uploader={{this.uploader}} />

        {{#if this.error}}
          <p class="ts-composer__error">{{this.error}}</p>
        {{/if}}

        <div class="ts-composer__footer">
          <button
            type="submit"
            class="btn btn-primary"
            disabled={{this.disabled}}
          >
            {{this.submitLabel}}
          </button>
        </div>
      </form>
    {{else}}
      <p class="ts-composer__closed">
        {{i18n "ticketing_system.detail.closed_notice"}}
      </p>
    {{/if}}
  </template>
}
