import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import { api, serverErrorMessage } from "../../lib/ticketing-system";
import TicketingSystemIcon from "./icon";

// 回复 / 内部备注编辑器。
//
// 服务端返回的是**整张工单**而不是新消息：一次回复可能改变状态
// （员工回复把 open 推到 in_progress，提交者回复把 pending 拉回 open），
// 也可能重开一张已关闭的工单，还一定会动计数器。再取一次是多余的一轮往返。
export default class TicketingSystemComposer extends Component {
  @tracked body = "";
  @tracked internal = false;
  @tracked sending = false;
  @tracked error = null;

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
    if (this.sending) {
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
          },
        },
      );

      this.body = "";
      this.internal = false;
      this.error = null;
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
