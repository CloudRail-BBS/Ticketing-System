import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { i18n } from "discourse-i18n";

import TicketingSystemIcon from "./icon";

// 附件选择器。
//
// 纯展示 + 事件转发：状态在 TicketingSystemAttachmentUploader 里（见
// lib/attachment-uploader.js），所以新建表单和回复框共用同一份逻辑，
// 这个组件本身没有任何自己的 @tracked。
//
// 文件选择用 `<label>` 包住 `<input type="file">`，而不是「按钮 + 隐藏 input +
// 点击时 `input.click()`」：
//
//   * 不需要在组件里抓住 input 的引用（那需要一个 did-insert 修饰符，或者
//     querySelector，两者都比这多一层）；
//   * 原生 label 转发对键盘和读屏器都是对的；
//   * 「满了就禁用」可以直接写成 input 的 disabled —— 浏览器不会为一个 disabled
//     的 file input 打开选择框，所以不需要在 JS 里拦截。
export default class TicketingSystemAttachmentPicker extends Component {
  get uploader() {
    return this.args.uploader;
  }

  get enabled() {
    return this.args.disabled !== true && (this.uploader?.enabled ?? false);
  }

  get addDisabled() {
    return !this.enabled || (this.uploader?.slotsLeft ?? 0) === 0;
  }

  get countLabel() {
    const used = this.uploader?.items.length ?? 0;
    const max = this.uploader?.max ?? 0;
    return `${used} / ${max}`;
  }

  @action
  onChosen(event) {
    const input = event.target;
    const files = input.files;

    // 立刻清空 value。不清空的话，用户移除某个附件之后**再选同一个文件**不会
    // 触发 change（value 没有变化），表现是「点了没反应」。
    input.value = "";

    return this.uploader?.addFiles(files);
  }

  @action
  remove(key) {
    this.uploader?.remove(key);
  }

  <template>
    {{#if this.enabled}}
      <div class="ts-attachments">
        <div class="ts-attachments__head">
          <label class="ts-attachments__add {{if this.addDisabled 'is-disabled'}}">
            <TicketingSystemIcon @name="paperclip" @size="13" />
            <span class="ts-btn-text">{{i18n "ticketing_system.attachments.add"}}</span>
            <input
              type="file"
              multiple
              class="ts-attachments__input"
              accept={{this.uploader.accept}}
              disabled={{this.addDisabled}}
              {{on "change" this.onChosen}}
            />
          </label>

          <span class="ts-attachments__count">{{this.countLabel}}</span>
        </div>

        {{#if this.uploader.limitError}}
          <p class="ts-attachments__error">{{this.uploader.limitError}}</p>
        {{/if}}

        {{#if this.uploader.hasItems}}
          <ul class="ts-attachments__list">
            {{#each this.uploader.items as |item|}}
              <li class={{if item.error "ts-file is-error" "ts-file"}}>
                <TicketingSystemIcon @name="paperclip" @size="12" />
                <span class="ts-file__name">{{item.filename}}</span>

                {{#if item.uploading}}
                  <span class="ts-file__state">
                    {{i18n "ticketing_system.attachments.uploading"}}
                  </span>
                {{/if}}

                {{#if item.size}}
                  <span class="ts-file__size">{{item.size}}</span>
                {{/if}}

                <button
                  type="button"
                  class="ts-file__remove"
                  title={{i18n "ticketing_system.attachments.remove"}}
                  {{on "click" (fn this.remove item.key)}}
                >
                  <TicketingSystemIcon @name="close" @size="12" />
                </button>

                {{#if item.error}}
                  <span class="ts-file__error">{{item.error}}</span>
                {{/if}}
              </li>
            {{/each}}
          </ul>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
