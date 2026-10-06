# Ticketing System（Discourse 工单系统插件）

一个自包含的 Discourse 工单（work order）插件：部门、优先级、指派、内部备注、员工收件箱，外加一个统计面板。

不依赖任何其他插件，不改动现有的主题与帖子，不往 Discourse 的 `Topic`/`Post` 表里写任何东西——工单是四张独立的表。

---

## 安装

**仓库名是 `Ticketing-System`，插件目录必须是 `ticketing-system`。这一步不能省。**

```sh
cd /var/discourse/plugins
git clone https://github.com/CloudRail-BBS/Ticketing-System.git ticketing-system
```

在 `containers/app.yml` 里：

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/CloudRail-BBS/Ticketing-System.git ticketing-system
```

然后 `./launcher rebuild app`。

### 为什么必须显式指定目录名

Discourse 核心的样式表路由把名字约束成小写：

```ruby
# config/routes.rb
get "stylesheets/:name" => "stylesheets#show",
    constraints: { name: /[-a-z0-9_]+/, format: "css" }, format: true
```

而它拼出的 `<link>` 用的是**插件目录名**。目录叫 `Ticketing-System` 时，请求是 `/stylesheets/Ticketing-System_<digest>.css`，上面那条约束永远匹配不上，请求 404，控制器根本不会进入。

此时**其它一切都看起来正常**：编译成功、`stylesheet_cache` 表里有那条记录、`<link>` 也照常输出、别的插件样式都正常。唯一的症状是页面完全没有样式，外加控制台里一条关于 MIME type `text/html` 的报错。查起来非常费时间，所以请照抄上面那行 `git clone`。

（`git clone <url>` 不带目标目录时，目录名由仓库名推导，也就是 `Ticketing-System`。）

---

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Discourse | `3.2.0` 及以上（见 `plugin.rb` 的 `# required_version:`） |
| 数据库 | PostgreSQL（用到了 `DISTINCT ON` 与 `PERCENTILE_CONT`） |
| Ruby | 随 Discourse 一起提供，无额外 gem 依赖 |
| 前端 | 无构建步骤、无 npm 依赖；资源交给 Discourse 自己的流水线 |

安装后到 **管理 → 设置 → Plugins** 找到 `ticketing_system enabled`，默认已开启。若页面没出现，见下面的「排查」。

---

## 功能

**用户侧**

- `/tickets` — 我的工单列表，带未读数徽标、状态/优先级/部门筛选、四种排序
- `/tickets/new` — 新建工单，选部门、填标题与正文
- `/tickets/:id` — 工单详情：完整对话流、时间线、操作栏
- 侧边栏「Community」区块与顶部导航栏都有入口（可用设置关掉）
- 工单被回复、被指派、状态变更时会收到 Discourse 原生通知，出现在通知面板里

**员工侧**

- 收件箱作用域：`mine` / `all` / `unassigned` / `assigned_to_me` / `active`
- 改状态、改优先级、指派（支持 `me` / 用户名 / 用户 id / `none`）
- 内部备注——仅员工可见，不通知用户，不进对话流给用户看
- 时间线：谁在什么时候做了什么，逐条记录

**管理侧**

- `/tickets/admin` — 统计总览：总量、状态/优先级分布、部门分布、首次响应时长（均值与中位数）、准时/超时计数、近 30 天活动
- `/tickets/admin` 的「部门」页签 — 部门的增删改：名称、slug、描述、排序、启用开关、所属员工组、SLA 小时数、默认优先级

---

## 工单流程

```
open ──▶ in_progress ──▶ pending ──▶ resolved ──▶ closed
  ▲           │              │           │           │
  └───────────┴──────────────┴───────────┴───────────┘
                    用户或员工可重开
```

| 状态 | 含义 |
| --- | --- |
| `open` | 新工单，还没有员工回复 |
| `in_progress` | 员工已接手 |
| `pending` | 等用户补充信息，球在用户那边 |
| `resolved` | 已解决，等用户确认 |
| `closed` | 已关闭，用户不能直接回复（员工可以回复以重开） |

优先级：`low` / `normal` / `high` / `urgent`。

`open`、`in_progress`、`pending` 合称**活跃状态**，未读徽标、员工收件箱默认范围和「超时」判定都基于这三个。

> `lib/ticketing_system/constants.rb` 里的整数是**存储契约**——它们会被写进数据库。加成员请追加新数字，永远不要重排或重编号。

---

## 设置

全部 21 项都在 **管理 → 设置 → Plugins** 分类下（`config/settings.yml` 的顶层键是 `plugins:`）。

### 开关与入口

| 设置 | 默认 | 说明 |
| --- | --- | --- |
| `ticketing_system_enabled` | `true` | 插件总开关 |
| `ticketing_system_staff_groups` | `staff` | 谁算员工。管理员始终算员工，所以留空也有可用的员工权限 |
| `ticketing_system_show_nav_link` | `true` | 侧边栏与顶部导航栏的入口 |
| `ticketing_system_unread_badge` | `true` | 侧边栏入口上的未读数徽标 |

### 用户能做什么

| 设置 | 默认 |
| --- | --- |
| `ticketing_system_allow_requester_priority` | `true` |
| `ticketing_system_allow_requester_close` | `true` |
| `ticketing_system_allow_requester_reopen` | `true` |
| `ticketing_system_allow_internal_notes` | `true` |
| `ticketing_system_default_priority` | `normal` |

### 长度与限额

| 设置 | 默认 | 范围 |
| --- | --- | --- |
| `ticketing_system_title_min_length` | `4` | 1–50 |
| `ticketing_system_title_max_length` | `120` | 10–255 |
| `ticketing_system_body_max_length` | `20000` | 1000–100000 |
| `ticketing_system_max_open_per_user` | `10` | 1–200 |
| `ticketing_system_create_per_hour` | `5` | 1–100（每人每小时，0 关闭） |
| `ticketing_system_reply_per_hour` | `30` | 1–500（每人每小时，0 关闭） |
| `ticketing_system_list_page_size` | `20` | 5–100 |

### SLA 与通知

| 设置 | 默认 |
| --- | --- |
| `ticketing_system_first_response_hours` | `24` |
| `ticketing_system_resolution_hours` | `72` |
| `ticketing_system_notify_staff` | `true` |
| `ticketing_system_notify_requester` | `true` |
| `ticketing_system_notify_assignee` | `true` |

SLA 截止时间是**读取时**由 `created_at` 推导出来的，不是定时任务写进库的。插件刻意不带任何后台任务，所以没有可漂移的状态，也没有需要运维的调度器。

部门可以在自己的记录上覆盖 SLA 小时数与默认优先级；为空时回落到上面两个全局设置。

---

## 权限

| 动作 | 谁可以 |
| --- | --- |
| 看自己的工单 | 登录用户 |
| 看全部工单、员工收件箱作用域 | 员工 |
| 回复工单 | 工单发起人、员工 |
| 写内部备注 | 员工 |
| 改状态 | 员工；发起人受 `allow_requester_close` / `allow_requester_reopen` 约束 |
| 改优先级 | 员工；发起人受 `allow_requester_priority` 约束 |
| 指派 | 员工 |
| 改部门 | 员工（发起人仅在工单仍未分配时） |
| 部门的增 / 改 / 删 | **仅管理员** |

前端渲染哪些按钮和权限判断共用 `lib/ticketing_system/permissions.rb`，但**服务端会重新判断一遍**。界面是便利，不是管控。

---

## HTTP API

全部挂在 `/tickets/api` 下（`config/routes.rb` 的 `scope "/api"`），返回 JSON，走 Discourse 自己的 `check_xhr` 与 CSRF 校验。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/tickets/api/meta` | 部门列表、状态与优先级词表（已翻译）、可用作用域、当前用户能力、未读数 |
| `GET` | `/tickets/api/stats` | 统计面板的数据，仅员工 |
| `GET` | `/tickets/api/tickets` | 列表。参数：`scope` `status` `priority` `department` `assignee` `search` `sort` `page` |
| `POST` | `/tickets/api/tickets` | 新建工单 |
| `GET` | `/tickets/api/tickets/:id` | 详情（含对话流与时间线） |
| `POST` | `/tickets/api/tickets/:id/messages` | 回复或写内部备注 |
| `POST` | `/tickets/api/tickets/:id/actions` | 状态变更，用 `operation` 区分 |
| `GET` | `/tickets/api/departments` | 部门列表 |
| `POST` | `/tickets/api/departments` | 新建部门（管理员） |
| `PUT` | `/tickets/api/departments/:id` | 修改部门（管理员） |
| `DELETE` | `/tickets/api/departments/:id` | 删除部门（管理员，有工单时拒绝） |

`POST /tickets/api/tickets/:id/actions` 的 `operation` 取 `status` / `priority` / `assign` / `department`：

```jsonc
{ "operation": "status",     "status": "resolved" }
{ "operation": "priority",   "priority": "urgent" }
{ "operation": "assign",     "assignee": "me" }        // 也接受用户名、用户 id、null、"none"
{ "operation": "department", "department_id": 3 }
```

判别字段是 `operation` 而**不是** `action`——Rails 在 params 里为路由保留了 `action` 和 `controller`，读它拿到的是控制器方法名，不是调用方的意图。

页面外壳（`/tickets`、`/tickets/new`、`/tickets/:id`、`/tickets/admin`）是服务端渲染的，放在 `<noscript>` 里，只为了让直接访问、刷新和爬虫拿到真实 HTML 而不是 404。带 JS 的访客看不到它。

---

## 通知

插件注册了自己的通知类型：

```ruby
Notification.types[:ticketing_system] = 5000
```

**5000 是存储契约，一旦产生过通知就不要再改。** 不复用 `Notification.types[:custom]`（14）是因为那个类型是所有插件共用的，谁最后注册渲染器谁赢，彼此的通知会串台。

会发通知的事件：

| 事件 | 收件人 | 开关 |
| --- | --- | --- |
| `new_ticket` | 部门员工组（或全局员工组）+ 指派者 | `notify_staff` |
| `requester_reply` | 同上 | `notify_staff` |
| `staff_reply` | 发起人 | `notify_requester` |
| `assigned` | 被指派者（自己指派给自己不发） | `notify_assignee` |
| `status_changed` | 发起人，且仅当改为 `resolved` / `closed` | `notify_requester` |

内部备注**不产生任何通知**：用户看不见它，通知了就是 bug；而员工刚写完的备注再通知全体员工，会让共享收件箱的徽标失去意义。

通知里 `topic_id` 是空的，这是刻意的。核心的三处相关逻辑都容忍这一点（`belongs_to_required_by_default = false`、`scope :visible` 的 `LEFT JOIN` 放行空 topic、`NotificationEmailer` 用 `respond_to?` 兜底所以不会尝试发信），`lib/ticketing_system/notifier.rb` 里有逐条说明。

---

## 目录结构

```
plugin.rb                          元数据、require_relative 清单、资源注册、通知类型
config/
  routes.rb                        JSON API + 页面外壳 + engine 挂载
  settings.yml                     21 项设置
  locales/{client,server}.{en,zh_CN}.yml
db/migrate/                        4 张表：departments / tickets / messages / events
lib/ticketing_system/              **不自动加载，必须 require_relative**
  constants.rb                     状态、优先级、事件种类、作用域、排序
  errors.rb                        领域异常，各自带 HTTP 状态码
  permissions.rb                   唯一的权限判断来源，服务端与前端共用
  engine.rb                        Rails::Engine
  ticket_query.rb                  列表的筛选/排序/分页
  ticket_creator.rb                新建工单
  message_creator.rb               回复与内部备注
  ticket_updater.rb                状态/优先级/指派/部门变更
  statistics.rb                    统计面板的查询
  notifier.rb                      Discourse 通知
  rate_limiter.rb                  包装核心的 RateLimiter
  serialization.rb                 AMS 基类
  ticket_serialization.rb          工单的状态/优先级标签
app/                               **由 Zeitwerk 自动加载，禁止 require_relative**
  models/ticketing_system/         4 个模型
  controllers/ticketing_system/    8 个控制器
  serializers/ticketing_system/    5 个序列化器
  views/ticketing_system/pages/    无 JS 时的服务端外壳
assets/
  javascripts/discourse/
    ticketing-system-route-map.js  Ember 路由表（必须导出「函数」）
    routes/                        index / new / show / admin
    templates/                     对应的 .gjs 路由模板
    components/                    9 个组件（列表、详情、编辑器、管理面板…）
    services/                      把 currentUser 上的能力包成 service
    initializers/                  导航入口 + 通知渲染器注册
    lib/                           API 路径、格式化、通知渲染器工厂
  stylesheets/                     用户侧 + 管理侧
scripts/                           提交前跑的闸门，见下
```

### `lib/` 与 `app/` 的区别不是风格问题

- `lib/` **不**在 Zeitwerk 的管辖范围内，所以 `plugin.rb` 必须逐条 `require_relative`。
- `app/` **在** Zeitwerk 的管辖范围内，所以**绝对不要** `require_relative` 它下面的任何文件。

原因是时序：插件激活发生在 `config/application.rb` 的**函数体里**，早于 `Rails.application.initialize!` 建立自动加载器。此时去加载一个继承自 `ApplicationController` / `ApplicationSerializer` / `ActiveRecord::Base` 的文件，会抛 `NameError: uninitialized constant`，被 `Plugin.initialization_guard` 捕获，打印 "You are unable to start Discourse due to errors in the plugin at …" 然后 `exit 1`。同一个 `exit 1` 还会让紧随其后的 `rake db:migrate` 步骤失败——一个事件，两个症状。

---

## 管理页为什么在 `/tickets/admin` 而不是 `/admin/plugins`

Discourse 的惯例是把插件管理界面挂在 `/admin/plugins` 下。这个插件没有这么做，是有意的：

1. `/admin/plugins` 下的页面属于**管理后台 bundle**，而管理后台只在 `/admin` 路由下加载。这个插件的用户侧页面在 `/tickets`，两个 bundle 之间共享样式和组件需要额外的注册，收益不抵复杂度。
2. 挂到 `/admin/plugins/<name>` 需要提供 `templates/admin/plugins/show/*.gjs` 去覆盖核心的 admin 插件展示模板，而这条路径是否会被核心解析**无法在没有真实实例的情况下确证**。Ember 路由表里用对象形式挂到已有节点时，如果目标节点不在路由树中，路由会被**静默丢弃**——没有日志、没有报错，只有 404。
3. 这个插件的管理页是插件自己前端路由表上的一条普通路由，用的是已经端到端验证过的**函数形式** `export default function () { this.route(...) }`。

代价是：`/admin/plugins` 里那个「设置」链接指向的是 Discourse 标准的插件设置页，而不是这个统计面板。统计面板的入口在侧边栏的工单链接旁边（员工可见）。

顺带一提，`config/routes.rb` 里 `get "/admin"` **必须**写在 `get "/:id"` 前面：Ember 路由没有正则约束，`show` 的 `:id` 会把字面量 `"admin"` 吞掉，Rails 侧同理。漏掉这一行时，应用内导航到 `/tickets/admin` 正常，直接刷新 404——最难查的一种分裂。

---

## 未实现

以下功能**刻意没有做**，写在这里以免被当成 bug：

**附件 / 上传。** 一条消息目前只能是纯文本。没有 `ticketing_system_max_attachments` 或 `ticketing_system_allowed_upload_extensions` 这类设置，因为**设置先于功能上线**会在管理后台留下两个改了也没用的开关——而一个把扩展名列表收窄的管理员会以为自己已经限制了可发布的内容。

真要做的时候有两件事必须注意：关联要走核心的 `UploadReference`，载荷要用 `UploadSerializer` 生成而不是手搓哈希——`UploadSerializer#url` 是 `secure_uploads` 重写到 `/secure-uploads/…` 的地方，手搓的哈希返回的是原始存储路径，在开了 secure uploads 的论坛上浏览器取不到。

**逐个员工的已读追踪。** 未读计数是**每张工单两个计数器**（`staff_unread_count` / `requester_unread_count`），不是每个员工一份。所以员工 A 打开工单会把员工 B 的徽标也清掉。做对需要一张 `(ticket_id, user_id)` 的关联表，代价是每张工单每个员工一行——对一个共享收件箱来说，团队级的「有人看过了」通常正是想要的语义，所以这一版按这个语义实现。

**邮件通知。** 通知只出现在站内通知面板里。核心的 `NotificationEmailer` 对未知通知类型是 `respond_to?` 兜底、静默跳过，所以插件通知**不会**触发邮件，也不会报错。要发信得注册 `email_notification_filters` 并自己写模板。

**后台任务。** 没有 Sidekiq 任务。SLA 截止时间在读取时推导，所以没有需要调度、需要监控、会漂移的东西。

**归档 / 自动关闭。** `resolved` 不会自动变成 `closed`。

**工单合并、标签、自定义字段、SLA 升级策略。** 都不在 v1 范围内。

---

## 开发

插件本身没有构建步骤，也不需要 `npm install`。但有一道**提交前必须跑**的闸门：

```sh
sh scripts/selftest.sh
```

四个阶段，任一失败立即停止：

| 阶段 | 内容 |
| --- | --- |
| 1/4 | `scripts/check-templates.py` — `.gjs` 模板的作用域，以及剥掉模板后的 JS 语法 |
| 2/4 | `scripts/validate.py` — 12 项跨文件静态一致性检查 |
| 3/4 | `scripts/check-ruby.rb` — 37 个 `.rb` 的语法、`.erb` 的可编译性，以及 Ruby 解析器的警告 |
| 4/4 | `scripts/selftest.py` — 变异自测：向代码注入 12 处缺陷，确认前三个校验器确实报错，然后恢复文件 |

也可以用 `npm run lint`（等价）、`npm run validate`、`npm run templates`、`npm run ruby`、`npm run mutation` 单独跑某一项。

没有 Ruby 的机器上阶段 3 会跳过并打印一行说明；其余三个阶段照跑。

### 为什么需要这套东西

这个插件里几乎每一种错误的**表现都是沉默的**：

| 错误 | 症状 |
| --- | --- |
| 少一个 i18n 键 | 界面上出现 `[en.ticketing_system.foo]` |
| 少一个 `site_setting` | 第一次真正读它时才抛 `NoMethodError` |
| API 路径拼错 | 一个 404 页面，不是一个异常 |
| 状态枚举加了成员忘了文案 | 下拉框里多一个原始键名 |
| 某个语种少一个键 | 只有那个语种的用户看得见 |
| `errors.add` 的键没有条目 | 报错信息变成 `translation missing: …` |
| `.gjs` 里用了未 import 的辅助函数 | **整个插件 bundle** 被换成一行 `throw new Error("… not in scope …")`，所有组件失效 |
| 哈希里同一个键写了两遍 | 前者被静默覆盖（真实案例：`status: 400, status: "bogus"` 让 HTTP 状态码变成了 `"bogus"`，500 而不是 400） |

没有一条会写日志，没有一条会让测试变红。所以这些检查必须在这里、在提交之前跑一遍。

`scripts/validate.py` 的 12 项检查：YAML 可解析与客户端 `js:` 包装、两个语种的键集对齐（含叶子类型）、前端 `i18n()` 调用、服务端 `I18n.t` / `Errors::*` / `errors.add`、`Errors::*` 类名、`Errors::*` 插值参数与文案占位符、`site_settings` 与文案双向、`site_settings` 与 Ruby 用法双向、状态/优先级枚举与文案、`plugin.rb` 元数据、前端 API 路径与 `config/routes.rb`、前端相对导入可达性。

### 几条容易踩的约定

- **前端不要 import 核心 UI 组件，也不要用模板辅助函数。** `.gjs` 里 import 一个不存在的模块、或者用没导入的 `(eq a b)` / `{{not x}}`，Discourse 的 js_compiler 会把整个插件 bundle 替换成一行 `throw`。这个插件用内联 SVG 图标集和原生 `<select>` / `<button>`，所有比较与取反都在 JS getter 里算好。
- **`plugin.rb` 里不要出现剥离后为纯 `#` 的行。** `Plugin::Metadata#parse_line` 对这样的行算出 `attribute = nil` 然后调 `nil.strip`，抛 `NoMethodError` 中止整个启动，回溯指向核心且不报插件名。空行是安全的，所以段落之间用空行，不要用 `#` 分隔线。
- **Ember 路由表必须导出「函数」**（`export default function () { this.route(...) }`）。对象形式 `{ resource: "x", map() {} }` 是「挂到已有节点」，插件自有顶层路由名不在树中，会被静默丢弃。
- **`register_asset` 不要带 `:admin`。** `:admin` 会把样式放进只在 `/admin` 路由加载的 bundle，而这个插件的管理页在 `/tickets/admin`。
- **客户端 locale 文件必须在 `js:` 下。** 服务端 `I18n.t` 和客户端 `i18n()` 是两个 I18n 实例，同一个键两边都要写一遍。

### 排查

**插件页面 404 / 没有样式。** 先确认目录名是 `ticketing-system`（全小写），再确认 `plugin.rb` 的 `# name:` 与 `PLUGIN_NAME` 和目录名三者一致。

**设置改了没反应。** 默认值只在没有任何存储值的时候生效。一旦在管理后台点过开关，存下来的值就赢了，改 `settings.yml` 里的 `default` 不再有任何作用。到 `/admin/site_settings/category/plugins` 看实际值。

**界面全是方括号键名，但错误提示是正常中文。** 说明 `client.*.yml` 少了 `js:` 那一层——服务端查询照常工作，客户端查询全部落空。

**整个插件都失效，控制台有一行 `throw new Error(... not in scope ...)`。** 某个 `.gjs` 用了未 import 的名字。跑 `sh scripts/py.sh scripts/check-templates.py --verbose` 定位。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
