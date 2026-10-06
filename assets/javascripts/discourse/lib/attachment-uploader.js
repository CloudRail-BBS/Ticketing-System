import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

import { serverErrorMessage } from "./ticketing-system";

// 附件上传的状态机。
//
// 为什么是一个普通类，而不是组件、也不是父组件里的一个字段：
//
//   需要附件的地方有两处 —— 新建工单表单与回复框。把状态机写进父组件就要写两遍；
//   写进子组件，父组件又拿不到提交时要用的 upload id。做成一个可实例化的类之后，
//   父组件持有它（`new TicketingSystemAttachmentUploader(this.ticketingSystem)`）、
//   提交时读 `uploadIds`，渲染交给 <TicketingSystemAttachmentPicker>。一份状态机，
//   两处复用，且没有「子组件把状态回传给父组件」那种双向管道。
//
// `@tracked` 用在普通类上完全有效：tracking 是一套标签系统，不依赖组件实例。
//
// 关于上传本身，有两个**必须**照做的地方，写错了都不会报错、只会静默失效：
//
//   1. `processData: false` / `contentType: false`。jQuery 不会因为 `data` 是
//      FormData 就自动改用 multipart —— 它照常走 `jQuery.param()`，而 FormData
//      没有任何可枚举的自有属性，结果是**一个空请求体**，服务端报「没有文件」。
//   2. CSRF 不需要在这里做。核心在 instance-initializer 里装了一个全局
//      `$.ajaxPrefilter`，对所有非 crossDomain 请求注入 `X-CSRF-Token`。
//      同源的上传请求自动带上；自己再设一遍反而容易和核心的取值时机不一致。
export const UPLOAD_TYPE = "ticketing_system_message";

export default class TicketingSystemAttachmentUploader {
  @tracked items = [];
  @tracked limitError = null;

  // 生成 key 用。不用文件名：同名文件选两次会被当成同一个条目。
  _seq = 0;

  constructor(service) {
    this.service = service;
  }

  // 每次都问服务要，而不是构造时快照一份。
  //
  // `capabilities.limits` 会在 `/meta` 返回后更新，快照会让「管理员刚把上限从
  // 0 改成 5」这件事在页面刷新前一直不生效 —— 而这类「改了设置没反应」的报障
  // 最难查，因为它看起来像缓存问题。
  get max() {
    return this.service?.maxAttachments ?? 0;
  }

  get enabled() {
    return this.max > 0;
  }

  // 给 `<input type="file" accept="…">` 用。只是让系统选择框默认过滤到论坛
  // 允许的类型，不是校验：用户仍可以在对话框里切到「所有文件」，真正的拒绝在
  // 服务端的 Attachments.validate! 里。`null` 表示论坛没有限制。
  get accept() {
    const extensions = this.service?.allowedUploadExtensions ?? [];
    if (extensions.length === 0) {
      return null;
    }
    return extensions.map((extension) => `.${extension}`).join(",");
  }

  get slotsLeft() {
    return Math.max(0, this.max - this.items.length);
  }

  get hasItems() {
    return this.items.length > 0;
  }

  get uploading() {
    return this.items.some((item) => item.uploading);
  }

  // 只有上传成功的条目才进 payload。失败的条目留在列表里让用户看见、移除或重试，
  // 但不能把它们的（并不存在的）id 发出去 —— 服务端会因此报「未知附件」，
  // 而用户看到的是一句和界面上的文件列表对不上的错误。
  get uploadIds() {
    return this.items.filter((item) => item.id).map((item) => String(item.id));
  }

  clear() {
    this.items = [];
    this.limitError = null;
  }

  async addFiles(fileList) {
    const files = Array.from(fileList ?? []).filter(Boolean);
    if (files.length === 0) {
      return;
    }

    this.limitError = null;

    const accepted = files.slice(0, this.slotsLeft);
    if (accepted.length < files.length) {
      // 一次选十个、上限五个：传前五个并说清楚为什么剩下的没进来。
      // 静默截断比直接拒绝更糟 —— 用户以为十个都传上去了。
      this.limitError = i18n("ticketing_system.attachments.limit", {
        max: this.max,
      });
    }
    if (accepted.length === 0) {
      return;
    }

    // 并发。串行在这里没有任何好处：文件之间互不依赖，而用户盯着的只是
    // 「全部传完」这一个时刻。
    await Promise.all(accepted.map((file) => this.#upload(file)));
  }

  remove(key) {
    this.items = this.items.filter((item) => item.key !== key);
  }

  async #upload(file) {
    const key = `attachment-${(this._seq += 1)}`;

    this.items = [
      ...this.items,
      {
        key,
        filename: file.name,
        size: null,
        uploading: true,
        error: null,
        id: null,
        url: null,
      },
    ];

    try {
      const form = new FormData();
      // `upload_type` 是必填参数（`type` 已被核心废弃，会在日志里告警）。
      // 核心把它 `parameterize(separator: "_")` 后截断到 50 字符再存。
      form.append("upload_type", UPLOAD_TYPE);
      form.append("file", file);

      const upload = await ajax("/uploads.json", {
        type: "POST",
        data: form,
        processData: false,
        contentType: false,
      });

      this.#patch(key, {
        uploading: false,
        id: upload?.id ?? null,
        url: upload?.url ?? null,
        // 服务端会纠正文件名（去掉不安全字符），以它为准。
        filename: upload?.original_filename || file.name,
        size: upload?.human_filesize ?? null,
      });
    } catch (rawError) {
      // 限流（`max_uploads_per_minute`）、扩展名不在论坛白名单、文件过大……
      // 服务端给了具体原因就用它；否则回退到**带文件名**的通用文案 ——
      // 一次选五个文件时，「哪一个失败了」是用户唯一需要的信息。
      this.#patch(key, {
        uploading: false,
        error:
          serverErrorMessage(rawError) ??
          i18n("ticketing_system.attachments.failed", { filename: file.name }),
      });
    }
  }

  #patch(key, changes) {
    this.items = this.items.map((item) =>
      item.key === key ? { ...item, ...changes } : item,
    );
  }
}
