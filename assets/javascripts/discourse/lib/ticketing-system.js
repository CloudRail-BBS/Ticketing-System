// 前端共享工具。放在 lib/ 下：Discourse 的解析器认得
// `discourse/plugins/<dir>/discourse/lib/*`（plugins/chat 与 plugins/boards 都
// 大量使用该目录），因此这里既能被 `services/` 引用，也能被相对路径引用。
import getURL from "discourse/lib/get-url";

// 引擎把 JSON API 挂在 /tickets/api 下（config/routes.rb 里的 `scope "/api"`）。
export const API_ROOT = "/tickets/api";

// 拼 API 路径。**不要**自己拼字符串：路径写错的表现是一个 404 页面，
// 而不是一个报错。
export function api(...segments) {
  return [API_ROOT, ...segments].join("/");
}

// 页面路径必须过 getURL()。
//
// 论坛可以装在子目录下（Discourse 的 baseUri，例如 /forum）。此时裸写的
// "/tickets" 会指向站点根，用户点进去是 404——而 `<a href>` 是浏览器直接解析的，
// 不会像 `ajax()` 那样自动加前缀（`discourse/lib/ajax` 内部会调用 getURL）。
export function pagePath(path = "") {
  return getURL(`/tickets${path}`);
}

export function ticketPath(id) {
  return pagePath(`/${id}`);
}

export function userPath(username) {
  return getURL(`/u/${encodeURIComponent(username)}`);
}

// 只保留有值的查询参数。
//
// 后端把空串与缺失一视同仁，但把 `status=` 发出去会让日志和浏览器历史里出现
// 一堆无意义的 `?status=&priority=`，也让「有没有筛选」这件事在前端变得难判断。
export function compact(params) {
  const out = {};
  Object.entries(params || {}).forEach(([key, value]) => {
    if (value === null || value === undefined || value === "" || value === false) {
      return;
    }
    out[key] = value;
  });
  return out;
}

// 把一次失败的请求还原成一句可以展示的话。
//
// 后端的每一个错误都经由 BaseController 的 `rescue_from` 出来，形状统一为
// `{ errors: ["…"] }`（`render_json_error`）。那句话已经由服务端翻译过，
// 直接展示比前端再猜一次更准确。取不到时返回 null，由调用方回退到自己的文案。
export function serverErrorMessage(error) {
  const payload =
    error?.responseJSON ??
    error?.jqXHR?.responseJSON ??
    error?.responseJson ??
    null;

  const first = payload?.errors?.[0];
  if (typeof first === "string" && first.trim().length > 0) {
    return first.trim();
  }
  return null;
}

// 时间戳的展示。刻意不用核心的格式化辅助函数：那是 `discourse/lib/formatter`
// 里的内部实现，导入路径会随重构移动，而一个无法解析的 `discourse/...` 导入
// 会把**整个**插件 bundle 替换成一行 `throw`（见 README 的说明）。
export function formatTimestamp(value) {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "—";
  }
  return date.toLocaleString();
}

// 秒 → 人话。用于统计页的首次响应耗时。
export function formatDuration(seconds, translate) {
  if (seconds === null || seconds === undefined || Number.isNaN(Number(seconds))) {
    return "—";
  }

  const total = Math.max(0, Math.round(Number(seconds)));
  if (total < 60) {
    return translate("ticketing_system.admin.overview.duration_seconds", {
      value: total,
    });
  }
  if (total < 3600) {
    return translate("ticketing_system.admin.overview.duration_minutes", {
      value: Math.round(total / 60),
    });
  }
  if (total < 86400) {
    return translate("ticketing_system.admin.overview.duration_hours", {
      value: Math.round(total / 3600),
    });
  }
  return translate("ticketing_system.admin.overview.duration_days", {
    value: Math.round(total / 86400),
  });
}

// 百分比条宽度。0 与 undefined 都要收敛成 0，否则 `style="width: NaN%"`
// 会被浏览器整条忽略，进度条静默地停在零宽。
export function barWidth(part, total) {
  const whole = Number(total) || 0;
  if (whole <= 0) {
    return "width: 0%";
  }
  const ratio = Math.min(1, Math.max(0, (Number(part) || 0) / whole));
  return `width: ${(ratio * 100).toFixed(1)}%`;
}

// 状态 → CSS 后缀。模板里只做 `{{this.statusClass}}` 一次判断，
// 避免在 .gjs 里引入 (eq a b) 之类的辅助函数（未导入的辅助函数是编译期错误，
// 同样会把整个 bundle 干掉）。
export function statusClass(status) {
  switch (status) {
    case "open":
      return "is-open";
    case "in_progress":
      return "is-progress";
    case "pending":
      return "is-pending";
    case "resolved":
      return "is-resolved";
    case "closed":
      return "is-closed";
    default:
      return "is-unknown";
  }
}

export function priorityClass(priority) {
  switch (priority) {
    case "urgent":
      return "is-urgent";
    case "high":
      return "is-high";
    case "low":
      return "is-low";
    default:
      return "is-normal";
  }
}

// SLA 状态 → CSS 后缀。后端返回的四个值见 Ticket#sla_state。
export function slaClass(state) {
  switch (state) {
    case "met":
      return "is-met";
    case "due_soon":
      return "is-due-soon";
    case "breached":
      return "is-breached";
    default:
      return "is-on-track";
  }
}
